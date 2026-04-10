// StreamSimulateCommand.swift
// OpenSuperMLX

import Foundation

import ArgumentParser

struct StreamSimulateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stream-simulate",
        abstract: "Simulate streaming transcription from an audio file"
    )

    @OptionGroup var globalOptions: GlobalOptions

    @Argument var file: String

    func run() async throws {
    }
}
