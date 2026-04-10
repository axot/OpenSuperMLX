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

@available(macOS 14.0, *)
struct OpenSuperMLXCLI: AsyncParsableCommand {
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
