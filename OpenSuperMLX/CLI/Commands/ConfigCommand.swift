// ConfigCommand.swift
// OpenSuperMLX

import Foundation

import ArgumentParser

struct ConfigCommand: ParsableCommand {
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

// MARK: - Config Registry

enum ConfigKeyType: String, Encodable {
    case string = "String"
    case bool = "Bool"
    case double = "Double"
    case optionalString = "String?"
}

struct ConfigKeyInfo {
    let key: String
    let type: ConfigKeyType
    let defaultDescription: String
    let sensitive: Bool

    init(_ key: String, _ type: ConfigKeyType, _ defaultDescription: String, sensitive: Bool = false) {
        self.key = key
        self.type = type
        self.defaultDescription = defaultDescription
        self.sensitive = sensitive
    }
}

enum ConfigRegistry {

    static let allKeys: [ConfigKeyInfo] = [
        ConfigKeyInfo("selectedMLXModel", .string, "mlx-community/Qwen3-ASR-1.7B-8bit"),
        ConfigKeyInfo("mlxLanguage", .string, "auto"),
        ConfigKeyInfo("translateToEnglish", .bool, "false"),
        ConfigKeyInfo("temperature", .double, "0.0"),
        ConfigKeyInfo("useStreamingTranscription", .bool, "true"),
        ConfigKeyInfo("useAsianAutocorrect", .bool, "true"),
        ConfigKeyInfo("debugMode", .bool, "false"),
        ConfigKeyInfo("playSoundOnRecordStart", .bool, "false"),
        ConfigKeyInfo("speakerCaptureEnabled", .bool, "false"),
        ConfigKeyInfo("llmCorrectionEnabled", .bool, "false"),
        ConfigKeyInfo("llmProvider", .string, "bedrock"),
        ConfigKeyInfo("useCustomCorrectionPrompt", .bool, "false"),
        ConfigKeyInfo("customCorrectionPrompt", .optionalString, "null"),
        ConfigKeyInfo("bedrockAuthMode", .string, "profile"),
        ConfigKeyInfo("bedrockProfileName", .string, "default"),
        ConfigKeyInfo("bedrockAccessKey", .string, "", sensitive: true),
        ConfigKeyInfo("bedrockSecretKey", .string, "", sensitive: true),
        ConfigKeyInfo("bedrockRegion", .string, "us-east-1"),
        ConfigKeyInfo("bedrockModelId", .string, "anthropic.claude-3-haiku-20240307-v1:0"),
        ConfigKeyInfo("openAIBaseURL", .string, "https://api.openai.com/v1"),
        ConfigKeyInfo("openAIAPIKey", .string, "", sensitive: true),
        ConfigKeyInfo("openAIModel", .string, "gpt-4o-mini"),
        ConfigKeyInfo("openAICustomHeaders", .string, ""),
    ]

    static func find(_ key: String) -> ConfigKeyInfo? {
        allKeys.first { $0.key == key }
    }

    static func readValue(for info: ConfigKeyInfo) -> String {
        if info.sensitive {
            let raw = AppPreferences.store.string(forKey: info.key) ?? info.defaultDescription
            return raw.isEmpty ? info.defaultDescription : "***"
        }

        switch info.type {
        case .string:
            return AppPreferences.store.string(forKey: info.key) ?? info.defaultDescription
        case .bool:
            if AppPreferences.store.object(forKey: info.key) != nil {
                return AppPreferences.store.bool(forKey: info.key) ? "true" : "false"
            }
            return info.defaultDescription
        case .double:
            if AppPreferences.store.object(forKey: info.key) != nil {
                return String(AppPreferences.store.double(forKey: info.key))
            }
            return info.defaultDescription
        case .optionalString:
            return AppPreferences.store.string(forKey: info.key) ?? "null"
        }
    }

    static func writeValue(for info: ConfigKeyInfo, rawValue: String) -> CLIError? {
        switch info.type {
        case .string:
            AppPreferences.store.set(rawValue, forKey: info.key)
            return nil
        case .bool:
            switch rawValue.lowercased() {
            case "true": AppPreferences.store.set(true, forKey: info.key)
            case "false": AppPreferences.store.set(false, forKey: info.key)
            default: return .invalidConfigValue
            }
            return nil
        case .double:
            guard let doubleVal = Double(rawValue) else {
                return .invalidConfigValue
            }
            AppPreferences.store.set(doubleVal, forKey: info.key)
            return nil
        case .optionalString:
            if rawValue.lowercased() == "null" {
                AppPreferences.store.removeObject(forKey: info.key)
            } else {
                AppPreferences.store.set(rawValue, forKey: info.key)
            }
            return nil
        }
    }
}

// MARK: - List Subcommand

struct ConfigListEntry: Encodable {
    let key: String
    let value: String
    let type: String
    let `default`: String

    enum CodingKeys: String, CodingKey {
        case key, value, type
        case `default` = "default"
    }
}

struct ConfigListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all configuration values"
    )

    @OptionGroup var globalOptions: GlobalOptions

    func run() throws {
        let json = globalOptions.json
        runAsync {
            let result = ConfigListCommand.executeList()

            switch result {
            case .success(let entries):
                CLIOutput.printSuccess(command: "config list", data: entries, json: json)
            case .failure(let error):
                CLIOutput.printError(command: "config list", error: error, json: json)
                throw ExitCode(1)
            }
        }
    }

    static func executeList() -> Result<[ConfigListEntry], CLIError> {
        let entries = ConfigRegistry.allKeys.map { info in
            ConfigListEntry(
                key: info.key,
                value: ConfigRegistry.readValue(for: info),
                type: info.type.rawValue,
                default: info.defaultDescription
            )
        }
        return .success(entries)
    }
}

// MARK: - Get Subcommand

struct ConfigGetEntry: Encodable {
    let key: String
    let value: String
    let type: String
}

struct ConfigGetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Get a configuration value"
    )

    @OptionGroup var globalOptions: GlobalOptions

    @Argument var key: String

    func run() throws {
        let key = self.key
        let json = globalOptions.json
        runAsync {
            let result = ConfigGetCommand.executeGet(key: key)

            switch result {
            case .success(let entry):
                CLIOutput.printSuccess(command: "config get", data: entry, json: json)
            case .failure(let error):
                CLIOutput.printError(command: "config get", error: error, json: json)
                throw ExitCode(1)
            }
        }
    }

    static func executeGet(key: String) -> Result<ConfigGetEntry, CLIError> {
        guard let info = ConfigRegistry.find(key) else {
            return .failure(.invalidConfigKey)
        }

        let entry = ConfigGetEntry(
            key: info.key,
            value: ConfigRegistry.readValue(for: info),
            type: info.type.rawValue
        )
        return .success(entry)
    }
}

// MARK: - Set Subcommand

struct ConfigSetResult: Encodable {
    let key: String
    let value: String
    let type: String
}

struct ConfigSetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Set a configuration value"
    )

    @OptionGroup var globalOptions: GlobalOptions

    @Argument var key: String
    @Argument var value: String

    func run() throws {
        let key = self.key
        let value = self.value
        let json = globalOptions.json
        runAsync {
            let result = ConfigSetCommand.executeSet(key: key, value: value)

            switch result {
            case .success(let data):
                CLIOutput.printSuccess(command: "config set", data: data, json: json)
            case .failure(let error):
                CLIOutput.printError(command: "config set", error: error, json: json)
                throw ExitCode(1)
            }
        }
    }

    static func executeSet(key: String, value: String) -> Result<ConfigSetResult, CLIError> {
        guard let info = ConfigRegistry.find(key) else {
            return .failure(.invalidConfigKey)
        }

        if let error = ConfigRegistry.writeValue(for: info, rawValue: value) {
            return .failure(error)
        }

        return .success(ConfigSetResult(
            key: info.key,
            value: ConfigRegistry.readValue(for: info),
            type: info.type.rawValue
        ))
    }
}
