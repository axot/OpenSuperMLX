// CLIRoot.swift
// OpenSuperMLX

import Foundation

import ArgumentParser

struct GlobalOptions: ParsableArguments {
    @Flag(name: .long, help: "Output results as JSON")
    var json = false

    @Flag(name: .long, help: "Suppress progress output on stderr")
    var quiet = false

    @Flag(name: .long, help: "Enable verbose logging on stderr")
    var verbose = false
}

struct OpenSuperMLXCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "OpenSuperMLX",
        abstract: "CLI test harness for OpenSuperMLX",
        subcommands: [
            TranscribeCommand.self,
            StreamSimulateCommand.self,
            CorrectCommand.self,
            ConfigCommand.self,
            RecordingsCommand.self,
            QueueCommand.self,
            MicCommand.self,
            ModelCommand.self,
            BenchmarkCommand.self,
            DiagnoseCommand.self,
        ]
    )
}

// MARK: - Async Bridge

func runAsync(_ block: @escaping @MainActor @Sendable () async throws -> Void) -> Never {
    Task { @MainActor in
        do {
            try await block()
            Foundation.exit(0)
        } catch let error as ExitCode {
            Foundation.exit(error.rawValue)
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }
    RunLoop.main.run()
    fatalError()
}
