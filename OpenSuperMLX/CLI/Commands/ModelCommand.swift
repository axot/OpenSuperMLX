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

// MARK: - Result Types

struct ModelEntry: Encodable {
    let id: String
    let name: String
    let repoId: String
    let size: String
    let description: String
    let isCustom: Bool
    let isSelected: Bool

    enum CodingKeys: String, CodingKey {
        case id, name
        case repoId = "repo_id"
        case size, description
        case isCustom = "is_custom"
        case isSelected = "is_selected"
    }
}

struct ModelAddResult: Encodable {
    let id: String
    let repoId: String
    let message: String

    enum CodingKeys: String, CodingKey {
        case id
        case repoId = "repo_id"
        case message
    }
}

struct ModelRemoveResult: Encodable {
    let message: String
}

struct ModelSelectResult: Encodable {
    let id: String
    let name: String
    let message: String
}

struct ModelDownloadResult: Encodable {
    let id: String
    let message: String
}

// MARK: - List Subcommand

struct ModelListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List available models"
    )

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let result = await Self.executeList()

        switch result {
        case .success(let entries):
            CLIOutput.printSuccess(command: "model list", data: entries, json: globalOptions.json)
        case .failure(let error):
            CLIOutput.printError(command: "model list", error: error, json: globalOptions.json)
            throw ExitCode(1)
        }
    }

    @MainActor
    static func executeList() -> Result<[ModelEntry], CLIError> {
        let manager = MLXModelManager.shared
        let selected = AppPreferences.shared.selectedMLXModel

        let entries = manager.availableModels.map { model in
            ModelEntry(
                id: model.id,
                name: model.name,
                repoId: model.repoID,
                size: model.size,
                description: model.description,
                isCustom: model.isCustom,
                isSelected: model.repoID == selected
            )
        }
        return .success(entries)
    }
}

// MARK: - Select Subcommand

struct ModelSelectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "select",
        abstract: "Select the active model"
    )

    @OptionGroup var globalOptions: GlobalOptions

    @Argument var name: String

    func run() async throws {
        let result = await Self.executeSelect(name: name)

        switch result {
        case .success(let data):
            CLIOutput.printSuccess(command: "model select", data: data, json: globalOptions.json)
        case .failure(let error):
            CLIOutput.printError(command: "model select", error: error, json: globalOptions.json)
            throw ExitCode(1)
        }
    }

    @MainActor
    static func executeSelect(name: String) -> Result<ModelSelectResult, CLIError> {
        let manager = MLXModelManager.shared
        let match = manager.availableModels.first { model in
            model.id == name || model.name == name || model.repoID == name
        }

        guard let model = match else {
            return .failure(.modelNotFound)
        }

        AppPreferences.shared.selectedMLXModel = model.repoID
        return .success(ModelSelectResult(
            id: model.id,
            name: model.name,
            message: "Selected model: \(model.name)"
        ))
    }
}

// MARK: - Add Subcommand

struct ModelAddCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add a custom model"
    )

    @OptionGroup var globalOptions: GlobalOptions

    @Argument var repoId: String

    func run() async throws {
        let result = await Self.executeAdd(repoId: repoId)

        switch result {
        case .success(let data):
            CLIOutput.printSuccess(command: "model add", data: data, json: globalOptions.json)
        case .failure(let error):
            CLIOutput.printError(command: "model add", error: error, json: globalOptions.json)
            throw ExitCode(1)
        }
    }

    @MainActor
    static func executeAdd(repoId: String) -> Result<ModelAddResult, CLIError> {
        let manager = MLXModelManager.shared
        let countBefore = manager.customModels.count
        manager.addCustomModel(repoID: repoId)

        guard manager.customModels.count > countBefore else {
            return .failure(.modelNotFound)
        }

        let added = manager.customModels.last!
        return .success(ModelAddResult(
            id: added.id,
            repoId: added.repoID,
            message: "Added custom model: \(added.name)"
        ))
    }
}

// MARK: - Remove Subcommand

struct ModelRemoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove a model"
    )

    @OptionGroup var globalOptions: GlobalOptions

    @Argument var name: String

    func run() async throws {
        let result = await Self.executeRemove(name: name)

        switch result {
        case .success(let data):
            CLIOutput.printSuccess(command: "model remove", data: data, json: globalOptions.json)
        case .failure(let error):
            CLIOutput.printError(command: "model remove", error: error, json: globalOptions.json)
            throw ExitCode(1)
        }
    }

    @MainActor
    static func executeRemove(name: String) -> Result<ModelRemoveResult, CLIError> {
        let manager = MLXModelManager.shared
        let match = manager.customModels.first { model in
            model.id == name || model.name == name || model.repoID == name
        }

        guard let model = match else {
            return .failure(.modelNotFound)
        }

        manager.removeCustomModel(model)
        return .success(ModelRemoveResult(message: "Removed model: \(model.name)"))
    }
}

// MARK: - Download Subcommand

struct ModelDownloadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "download",
        abstract: "Download a model"
    )

    @OptionGroup var globalOptions: GlobalOptions

    @Argument var name: String

    func run() async throws {
        let manager = await MLXModelManager.shared
        let match = await manager.availableModels.first { model in
            model.id == name || model.name == name || model.repoID == name
        }

        guard let model = match else {
            CLIOutput.printError(command: "model download", error: .modelNotFound, json: globalOptions.json)
            throw ExitCode(1)
        }

        CLIOutput.printProgress("Download of \(model.name) would start here (not implemented in CLI harness)", quiet: globalOptions.quiet)
        CLIOutput.printSuccess(
            command: "model download",
            data: ModelDownloadResult(id: model.id, message: "Model download not yet implemented in CLI"),
            json: globalOptions.json
        )
    }
}
