// CorrectCommand.swift
// OpenSuperMLX

import Foundation

import ArgumentParser

struct CorrectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "correct",
        abstract: "Apply post-transcription correction to text"
    )

    @OptionGroup var globalOptions: GlobalOptions

    @Argument(help: "Text to correct")
    var text: String

    @Option(name: .long, help: "Read text from file instead")
    var file: String?

    @Option(name: .long, help: "LLM provider (bedrock or openai)")
    var provider: String?

    @Option(name: .long, help: "Custom correction prompt")
    var prompt: String?

    // MARK: - Execution

    func run() throws {
        let cmd = self
        runAsync {
            let service = LLMCorrectionService.shared
            let result = await cmd.executeCorrection(service: service)

            switch result {
            case .success(let data):
                CLIOutput.printSuccess(command: "correct", data: data, json: cmd.globalOptions.json)
            case .failure(let error):
                CLIOutput.printError(command: "correct", error: error, json: cmd.globalOptions.json)
                throw ExitCode(1)
            }
        }
    }

    @MainActor
    func executeCorrection(
        service: LLMCorrectionService
    ) async -> Result<CorrectResult, CLIError> {
        let inputText: String

        if let filePath = file {
            let url = URL(fileURLWithPath: filePath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                return .failure(.audioFileNotFound)
            }
            do {
                inputText = try String(contentsOf: url, encoding: .utf8)
            } catch {
                return .failure(.audioFileNotFound)
            }
        } else {
            inputText = text
        }

        if let providerName = provider {
            AppPreferences.shared.llmProvider = providerName
        }

        if let customPrompt = prompt {
            AppPreferences.shared.useCustomCorrectionPrompt = true
            AppPreferences.shared.customCorrectionPrompt = customPrompt
        }

        let corrected = await service.correctTranscription(inputText, forceEnabled: true)

        return .success(CorrectResult(
            originalText: inputText,
            correctedText: corrected,
            provider: AppPreferences.shared.llmProvider
        ))
    }
}

// MARK: - Result Type

struct CorrectResult: Encodable {
    let originalText: String
    let correctedText: String
    let provider: String

    enum CodingKeys: String, CodingKey {
        case originalText = "original_text"
        case correctedText = "corrected_text"
        case provider
    }
}
