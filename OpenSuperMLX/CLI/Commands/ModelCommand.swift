// ModelCommand.swift
// OpenSuperMLX

import Foundation

import ArgumentParser

struct ModelCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "model",
        abstract: "Show the transcription model",
        subcommands: [ModelListCommand.self]
    )

    @OptionGroup var globalOptions: GlobalOptions
}

// MARK: - Result Types

struct ModelEntry: Encodable {
    let id: String
    let name: String
    let repoId: String
    let size: String
    let description: String

    enum CodingKeys: String, CodingKey {
        case id, name
        case repoId = "repo_id"
        case size, description
    }
}

// MARK: - List Subcommand

struct ModelListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the built-in model"
    )

    @OptionGroup var globalOptions: GlobalOptions

    func run() throws {
        let json = globalOptions.json
        runAsync {
            let result = ModelListCommand.executeList()

            switch result {
            case .success(let entries):
                CLIOutput.printSuccess(command: "model list", data: entries, json: json)
            case .failure(let error):
                CLIOutput.printError(command: "model list", error: error, json: json)
                throw ExitCode(1)
            }
        }
    }

    @MainActor
    static func executeList() -> Result<[ModelEntry], CLIError> {
        let model = MLXModelManager.model
        return .success([
            ModelEntry(
                id: model.id,
                name: model.name,
                repoId: model.repoID,
                size: model.size,
                description: model.description
            )
        ])
    }
}
