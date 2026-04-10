// QueueCommand.swift
// OpenSuperMLX

import Foundation

import ArgumentParser

struct QueueCommand: AsyncParsableCommand {
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

// MARK: - Subcommands

struct QueueAddCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add a file to the transcription queue"
    )

    @OptionGroup var globalOptions: GlobalOptions

    @Argument var file: String

    func run() async throws {
    }
}

struct QueueStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show queue status"
    )

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
    }
}

struct QueueProcessCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "process",
        abstract: "Process the transcription queue"
    )

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
    }
}
