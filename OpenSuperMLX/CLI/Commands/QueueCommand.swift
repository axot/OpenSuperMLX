// QueueCommand.swift
// OpenSuperMLX

import Foundation

import ArgumentParser

struct QueueCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "queue",
        abstract: "Manage the transcription queue",
        subcommands: [
            QueueAddCommand.self,
            QueueStatusCommand.self,
            QueueProcessCommand.self,
        ]
    )

    @OptionGroup var globalOptions: GlobalOptions
}

// MARK: - Result Types

struct QueueAddResult: Encodable {
    let files: [String]
    let message: String
}

struct QueueStatusResult: Encodable {
    let pending: Int
    let completed: Int
    let failed: Int
    let isProcessing: Bool

    enum CodingKeys: String, CodingKey {
        case pending, completed, failed
        case isProcessing = "is_processing"
    }
}

struct QueueProcessResult: Encodable {
    let message: String
}

// MARK: - Add Subcommand

struct QueueAddCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add files to the transcription queue"
    )

    @OptionGroup var globalOptions: GlobalOptions

    @Argument var files: [String]

    func run() throws {
        let files = self.files
        let json = globalOptions.json
        runAsync {
            let result = QueueAddCommand.executeAdd(files: files)

            switch result {
            case .success(let data):
                for file in files {
                    let url = URL(fileURLWithPath: file)
                    await TranscriptionQueue.shared.addFileToQueue(url: url)
                }
                CLIOutput.printSuccess(command: "queue add", data: data, json: json)
            case .failure(let error):
                CLIOutput.printError(command: "queue add", error: error, json: json)
                throw ExitCode(1)
            }
        }
    }

    static func executeAdd(files: [String]) -> Result<QueueAddResult, CLIError> {
        for file in files {
            guard FileManager.default.fileExists(atPath: file) else {
                return .failure(.audioFileNotFound)
            }
        }
        return .success(QueueAddResult(files: files, message: "Added \(files.count) file(s) to queue"))
    }
}

// MARK: - Status Subcommand

struct QueueStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show queue status"
    )

    @OptionGroup var globalOptions: GlobalOptions

    func run() throws {
        let json = globalOptions.json
        runAsync {
            let result = await QueueStatusCommand.executeStatus()

            switch result {
            case .success(let data):
                CLIOutput.printSuccess(command: "queue status", data: data, json: json)
            case .failure(let error):
                CLIOutput.printError(command: "queue status", error: error, json: json)
                throw ExitCode(1)
            }
        }
    }

    @MainActor
    static func executeStatus() async -> Result<QueueStatusResult, CLIError> {
        let store = RecordingStore.shared
        do {
            let all = try await store.fetchRecordings(limit: 10000, offset: 0)
            let pending = all.filter { $0.isPending }.count
            let completed = all.filter { $0.status == .completed }.count
            let failed = all.filter { $0.status == .failed }.count
            let isProcessing = TranscriptionQueue.shared.isProcessing

            return .success(QueueStatusResult(
                pending: pending,
                completed: completed,
                failed: failed,
                isProcessing: isProcessing
            ))
        } catch {
            return .failure(.databaseError)
        }
    }
}

// MARK: - Process Subcommand

struct QueueProcessCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "process",
        abstract: "Process the transcription queue"
    )

    @OptionGroup var globalOptions: GlobalOptions

    func run() throws {
        let json = globalOptions.json
        let quiet = globalOptions.quiet
        runAsync {
            CLIOutput.printProgress("Starting queue processing...", quiet: quiet)
            TranscriptionQueue.shared.startProcessingQueue()
            CLIOutput.printSuccess(
                command: "queue process",
                data: QueueProcessResult(message: "Queue processing started"),
                json: json
            )
        }
    }
}
