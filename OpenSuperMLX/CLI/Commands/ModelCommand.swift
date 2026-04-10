// ModelCommand.swift
// OpenSuperMLX

import Foundation

import ArgumentParser

struct ModelCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "model",
        abstract: "Manage transcription models",
        subcommands: [
            ModelListCommand.self,
            ModelSelectCommand.self,
            ModelAddCommand.self,
            ModelRemoveCommand.self,
            ModelDownloadCommand.self,
        ]
    )

    @OptionGroup var globalOptions: GlobalOptions
}

// MARK: - Subcommands

struct ModelListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List available models"
    )

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
    }
}

struct ModelSelectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "select",
        abstract: "Select the active model"
    )

    @OptionGroup var globalOptions: GlobalOptions

    @Argument var name: String

    func run() async throws {
    }
}

struct ModelAddCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add a custom model"
    )

    @OptionGroup var globalOptions: GlobalOptions

    @Argument var repoId: String

    func run() async throws {
    }
}

struct ModelRemoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove a model"
    )

    @OptionGroup var globalOptions: GlobalOptions

    @Argument var name: String

    func run() async throws {
    }
}

struct ModelDownloadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "download",
        abstract: "Download a model"
    )

    @OptionGroup var globalOptions: GlobalOptions

    @Argument var name: String

    func run() async throws {
    }
}
