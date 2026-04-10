// ConfigCommand.swift
// OpenSuperMLX

import Foundation

import ArgumentParser

struct ConfigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Manage application configuration",
        subcommands: [
            ConfigListCommand.self,
            ConfigGetCommand.self,
            ConfigSetCommand.self,
        ]
    )

    @OptionGroup var globalOptions: GlobalOptions
}

// MARK: - Subcommands

struct ConfigListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all configuration values"
    )

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
    }
}

struct ConfigGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Get a configuration value"
    )

    @OptionGroup var globalOptions: GlobalOptions

    @Argument var key: String

    func run() async throws {
    }
}

struct ConfigSetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Set a configuration value"
    )

    @OptionGroup var globalOptions: GlobalOptions

    @Argument var key: String
    @Argument var value: String

    func run() async throws {
    }
}
