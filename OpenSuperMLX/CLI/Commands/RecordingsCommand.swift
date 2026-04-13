// RecordingsCommand.swift
// OpenSuperMLX

import Foundation

import ArgumentParser

struct RecordingsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recordings",
        abstract: "Manage recordings",
        subcommands: [
            RecordingsListCommand.self,
            RecordingsSearchCommand.self,
            RecordingsShowCommand.self,
            RecordingsDeleteCommand.self,
            RecordingsRegenerateCommand.self,
        ]
    )

    @OptionGroup var globalOptions: GlobalOptions
}

// MARK: - Result Types

struct RecordingEntry: Encodable {
    let id: String
    let timestamp: String
    let fileName: String
    let transcription: String
    let duration: TimeInterval
    let status: String
    let progress: Float

    enum CodingKeys: String, CodingKey {
        case id, timestamp
        case fileName = "file_name"
        case transcription, duration, status, progress
    }
}

struct RecordingsDeleteResult: Encodable {
    let message: String
}

struct RecordingsRegenerateResult: Encodable {
    let id: String
    let message: String
}

// MARK: - Helpers

private let iso8601Formatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private func toEntry(_ r: Recording) -> RecordingEntry {
    RecordingEntry(
        id: r.id.uuidString,
        timestamp: iso8601Formatter.string(from: r.timestamp),
        fileName: r.fileName,
        transcription: r.transcription,
        duration: r.duration,
        status: r.status.rawValue,
        progress: r.progress
    )
}

// MARK: - List Subcommand

struct RecordingsListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all recordings"
    )

    @OptionGroup var globalOptions: GlobalOptions

    @Option(name: .long, help: "Maximum number of recordings to return")
    var limit: Int = 20

    @Option(name: .long, help: "Number of recordings to skip")
    var offset: Int = 0

    func run() throws {
        let limit = self.limit
        let offset = self.offset
        let json = globalOptions.json
        runAsync {
            let result = await RecordingsListCommand.executeList(store: RecordingStore.shared, limit: limit, offset: offset)

            switch result {
            case .success(let entries):
                CLIOutput.printSuccess(command: "recordings list", data: entries, json: json)
            case .failure(let error):
                CLIOutput.printError(command: "recordings list", error: error, json: json)
                throw ExitCode(1)
            }
        }
    }

    @MainActor
    static func executeList(store: RecordingStore, limit: Int, offset: Int) async -> Result<[RecordingEntry], CLIError> {
        do {
            let recordings = try await store.fetchRecordings(limit: limit, offset: offset)
            return .success(recordings.map(toEntry))
        } catch {
            return .failure(.databaseError)
        }
    }
}

// MARK: - Search Subcommand

struct RecordingsSearchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search recordings"
    )

    @OptionGroup var globalOptions: GlobalOptions

    @Argument var query: String

    @Option(name: .long, help: "Maximum number of results")
    var limit: Int = 100

    @Option(name: .long, help: "Number of results to skip")
    var offset: Int = 0

    func run() throws {
        let query = self.query
        let limit = self.limit
        let offset = self.offset
        let json = globalOptions.json
        runAsync {
            let result = await RecordingsSearchCommand.executeSearch(store: RecordingStore.shared, query: query, limit: limit, offset: offset)

            switch result {
            case .success(let entries):
                CLIOutput.printSuccess(command: "recordings search", data: entries, json: json)
            case .failure(let error):
                CLIOutput.printError(command: "recordings search", error: error, json: json)
                throw ExitCode(1)
            }
        }
    }

    @MainActor
    static func executeSearch(store: RecordingStore, query: String, limit: Int = 100, offset: Int = 0) async -> Result<[RecordingEntry], CLIError> {
        let recordings = await store.searchRecordingsAsync(query: query, limit: limit, offset: offset)
        return .success(recordings.map(toEntry))
    }
}

// MARK: - Show Subcommand

struct RecordingsShowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show recording details"
    )

    @OptionGroup var globalOptions: GlobalOptions

    @Argument var id: String

    func run() throws {
        let id = self.id
        let json = globalOptions.json
        runAsync {
            let result = await RecordingsShowCommand.executeShow(store: RecordingStore.shared, id: id)

            switch result {
            case .success(let entry):
                CLIOutput.printSuccess(command: "recordings show", data: entry, json: json)
            case .failure(let error):
                CLIOutput.printError(command: "recordings show", error: error, json: json)
                throw ExitCode(1)
            }
        }
    }

    @MainActor
    static func executeShow(store: RecordingStore, id: String) async -> Result<RecordingEntry, CLIError> {
        guard let uuid = UUID(uuidString: id) else {
            return .failure(.databaseError)
        }
        do {
            let recordings = try await store.fetchRecordings(limit: 1000, offset: 0)
            guard let recording = recordings.first(where: { $0.id == uuid }) else {
                return .failure(.databaseError)
            }
            return .success(toEntry(recording))
        } catch {
            return .failure(.databaseError)
        }
    }
}

// MARK: - Delete Subcommand

struct RecordingsDeleteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a recording"
    )

    @OptionGroup var globalOptions: GlobalOptions

    @Argument var id: String

    @Flag(name: .long, help: "Delete all recordings")
    var all = false

    func run() throws {
        let id = self.id
        let all = self.all
        let json = globalOptions.json
        runAsync {
            let result = await RecordingsDeleteCommand.executeDelete(store: RecordingStore.shared, id: id, all: all)

            switch result {
            case .success(let data):
                CLIOutput.printSuccess(command: "recordings delete", data: data, json: json)
            case .failure(let error):
                CLIOutput.printError(command: "recordings delete", error: error, json: json)
                throw ExitCode(1)
            }
        }
    }

    @MainActor
    static func executeDelete(store: RecordingStore, id: String, all: Bool) async -> Result<RecordingsDeleteResult, CLIError> {
        if all {
            store.deleteAllRecordings()
            return .success(RecordingsDeleteResult(message: "Deleted all recordings"))
        }

        guard let uuid = UUID(uuidString: id) else {
            return .failure(.databaseError)
        }

        do {
            let recordings = try await store.fetchRecordings(limit: 1000, offset: 0)
            guard let recording = recordings.first(where: { $0.id == uuid }) else {
                return .failure(.databaseError)
            }
            store.deleteRecording(recording)
            return .success(RecordingsDeleteResult(message: "Deleted recording \(id)"))
        } catch {
            return .failure(.databaseError)
        }
    }
}

// MARK: - Regenerate Subcommand

struct RecordingsRegenerateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "regenerate",
        abstract: "Regenerate transcription for a recording"
    )

    @OptionGroup var globalOptions: GlobalOptions

    @Argument var id: String

    func run() throws {
        let id = self.id
        let json = globalOptions.json
        runAsync {
            let result = await RecordingsRegenerateCommand.executeRegenerate(store: RecordingStore.shared, id: id)

            switch result {
            case .success(let data):
                CLIOutput.printSuccess(command: "recordings regenerate", data: data, json: json)
            case .failure(let error):
                CLIOutput.printError(command: "recordings regenerate", error: error, json: json)
                throw ExitCode(1)
            }
        }
    }

    @MainActor
    static func executeRegenerate(store: RecordingStore, id: String) async -> Result<RecordingsRegenerateResult, CLIError> {
        guard let uuid = UUID(uuidString: id) else {
            return .failure(.databaseError)
        }

        do {
            let recordings = try await store.fetchRecordings(limit: 1000, offset: 0)
            guard let recording = recordings.first(where: { $0.id == uuid }) else {
                return .failure(.databaseError)
            }

            let audioExists = FileManager.default.fileExists(atPath: recording.url.path)
            let sourceExists = recording.sourceFileURL.map { FileManager.default.fileExists(atPath: $0) } ?? false

            guard audioExists || sourceExists else {
                return .failure(.audioFileMissing)
            }

            await TranscriptionQueue.shared.requeueRecording(recording)
            return .success(RecordingsRegenerateResult(id: id, message: "Queued for regeneration"))
        } catch {
            return .failure(.databaseError)
        }
    }
}
