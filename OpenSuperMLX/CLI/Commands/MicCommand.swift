// MicCommand.swift
// OpenSuperMLX

import Foundation

import ArgumentParser

struct MicCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mic",
        abstract: "Manage microphone selection",
        subcommands: [
            MicListCommand.self,
            MicSelectCommand.self,
        ]
    )

    @OptionGroup var globalOptions: GlobalOptions
}

// MARK: - Subcommands

struct MicListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List available microphones"
    )

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
    }
}

struct MicSelectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "select",
        abstract: "Select a microphone"
    )

    @OptionGroup var globalOptions: GlobalOptions

    @Argument var device: String

    func run() async throws {
    }
}
