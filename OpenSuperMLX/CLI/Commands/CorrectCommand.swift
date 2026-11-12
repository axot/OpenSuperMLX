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

    @Option(name: .long, help: "Apply a preset from Settings → Presets by name (case-insensitive)")
    var preset: String?

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
        service: LLMCorrectionService,
        presets: [PromptPreset]? = nil
    ) async -> Result<CorrectResult, CLIError> {
        var selectedPreset: PromptPreset?
        if let preset {
            let available = presets ?? PromptPresetStore.shared.presets
            guard let match = available.first(where: { $0.name.caseInsensitiveCompare(preset) == .orderedSame }) else {
                return .failure(.presetNotFound)
            }
            selectedPreset = match
        }

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

        let startTime = CFAbsoluteTimeGetCurrent()
        let outcome = await service.correct(inputText, forceEnabled: true, preset: selectedPreset)
        let processingTime = CFAbsoluteTimeGetCurrent() - startTime

        if outcome.errorMessage != nil, !outcome.correctedAnything {
            return .failure(.llmCorrectionFailed)
        }

        return .success(CorrectResult(
            originalText: inputText,
            correctedText: outcome.text,
            provider: AppPreferences.shared.llmProvider,
            preset: selectedPreset?.name,
            mode: outcome.mode.rawValue,
            chunkCount: outcome.chunkCount,
            failedChunkCount: outcome.failedChunkCount,
            processingTimeSeconds: processingTime,
            warning: outcome.errorMessage
        ))
    }
}

// MARK: - Result Type

struct CorrectResult: Encodable {
    let originalText: String
    let correctedText: String
    let provider: String
    let preset: String?
    let mode: String
    let chunkCount: Int
    let failedChunkCount: Int
    let processingTimeSeconds: Double
    let warning: String?

    enum CodingKeys: String, CodingKey {
        case originalText = "original_text"
        case correctedText = "corrected_text"
        case provider
        case preset
        case mode
        case chunkCount = "chunk_count"
        case failedChunkCount = "failed_chunk_count"
        case processingTimeSeconds = "processing_time_s"
        case warning
    }
}
