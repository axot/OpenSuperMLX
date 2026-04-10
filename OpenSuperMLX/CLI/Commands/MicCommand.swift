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

// MARK: - Result Types

struct MicDeviceEntry: Encodable {
    let id: String
    let name: String
    let isDefault: Bool
    let isBuiltIn: Bool

    enum CodingKeys: String, CodingKey {
        case id, name
        case isDefault = "is_default"
        case isBuiltIn = "is_built_in"
    }
}

struct MicSelectResult: Encodable {
    let id: String
    let name: String
    let message: String
}

// MARK: - List Subcommand

struct MicListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List available microphones"
    )

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let result = Self.executeList()

        switch result {
        case .success(let entries):
            CLIOutput.printSuccess(command: "mic list", data: entries, json: globalOptions.json)
        case .failure(let error):
            CLIOutput.printError(command: "mic list", error: error, json: globalOptions.json)
            throw ExitCode(1)
        }
    }

    static func executeList() -> Result<[MicDeviceEntry], CLIError> {
        let service = MicrophoneService.shared
        let defaultDevice = service.getDefaultMicrophone()

        let entries = service.availableMicrophones.map { device in
            MicDeviceEntry(
                id: device.id,
                name: device.name,
                isDefault: device.id == defaultDevice?.id,
                isBuiltIn: device.isBuiltIn
            )
        }
        return .success(entries)
    }
}

// MARK: - Select Subcommand

struct MicSelectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "select",
        abstract: "Select a microphone"
    )

    @OptionGroup var globalOptions: GlobalOptions

    @Argument var device: String

    func run() async throws {
        let result = Self.executeSelect(deviceIdentifier: device)

        switch result {
        case .success(let data):
            CLIOutput.printSuccess(command: "mic select", data: data, json: globalOptions.json)
        case .failure(let error):
            CLIOutput.printError(command: "mic select", error: error, json: globalOptions.json)
            throw ExitCode(1)
        }
    }

    static func executeSelect(deviceIdentifier: String) -> Result<MicSelectResult, CLIError> {
        let service = MicrophoneService.shared
        let match = service.availableMicrophones.first { device in
            device.id == deviceIdentifier || device.name == deviceIdentifier
        }

        guard let device = match else {
            return .failure(.audioFileNotFound)
        }

        service.selectMicrophone(device)
        return .success(MicSelectResult(
            id: device.id,
            name: device.name,
            message: "Selected microphone: \(device.name)"
        ))
    }
}
