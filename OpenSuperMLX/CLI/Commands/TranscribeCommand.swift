// TranscribeCommand.swift
// OpenSuperMLX

import Foundation

import ArgumentParser

struct TranscribeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcribe",
        abstract: "Transcribe an audio file"
    )

    @OptionGroup var globalOptions: GlobalOptions

    @Argument var file: String

    func run() async throws {
    }
}
