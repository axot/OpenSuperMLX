// TranscribeCommand.swift
// OpenSuperMLX

import AVFoundation
import Foundation

import ArgumentParser

struct TranscribeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcribe",
        abstract: "Transcribe an audio file"
    )

    @OptionGroup var globalOptions: GlobalOptions

    @Argument(help: "Path to audio file")
    var file: String

    @Option(name: .long, help: "Language code (default: auto)")
    var language: String = "auto"

    @Option(name: .long, help: "Model repository ID")
    var model: String?

    @Flag(name: .long, help: "Skip LLM correction")
    var noCorrection = false

    @Option(name: .long, help: "Inference temperature")
    var temperature: Double?

    // MARK: - Execution

    func run() async throws {
        let service = await TranscriptionService.shared
        let result = await executeTranscription(service: service)

        switch result {
        case .success(let data):
            CLIOutput.printSuccess(command: "transcribe", data: data, json: globalOptions.json)
        case .failure(let error):
            CLIOutput.printError(command: "transcribe", error: error, json: globalOptions.json)
            throw ExitCode(1)
        }
    }

    @MainActor
    func executeTranscription(
        service: TranscriptionService
    ) async -> Result<TranscribeResult, CLIError> {
        let url = URL(fileURLWithPath: file)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .failure(.audioFileNotFound)
        }

        if let model = model {
            AppPreferences.shared.selectedMLXModel = model
        }

        let settings = Settings(
            selectedLanguage: language,
            temperature: temperature ?? AppPreferences.shared.temperature,
            useAsianAutocorrect: AppPreferences.shared.useAsianAutocorrect,
            useStreamingTranscription: false
        )

        CLIOutput.printProgress("Loading model...", quiet: globalOptions.quiet)

        var waitCount = 0
        while service.isLoading && waitCount < 120 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            waitCount += 1
        }

        if service.loadError != nil {
            return .failure(.modelLoadFailed)
        }

        CLIOutput.printProgress(
            "Transcribing \(url.lastPathComponent)...", quiet: globalOptions.quiet
        )
        let startTime = CFAbsoluteTimeGetCurrent()

        do {
            let text = try await service.transcribeAudio(
                url: url,
                settings: settings,
                applyCorrection: !noCorrection
            )
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime

            let audioDuration = await loadAudioDuration(url: url)

            let data = TranscribeResult(
                text: text,
                language: language,
                model: AppPreferences.shared.selectedMLXModel,
                audioDurationS: audioDuration,
                processingTimeS: elapsed,
                correctionsApplied: Self.buildCorrectionsList(
                    noCorrection: noCorrection,
                    llmEnabled: AppPreferences.shared.llmCorrectionEnabled
                )
            )
            return .success(data)
        } catch {
            return .failure(.transcriptionFailed)
        }
    }

    // MARK: - Helpers

    private func loadAudioDuration(url: URL) async -> Double {
        await (try? Task.detached(priority: .utility) {
            let asset = AVAsset(url: url)
            let duration = try await asset.load(.duration)
            return CMTimeGetSeconds(duration)
        }.value) ?? 0.0
    }

    static func buildCorrectionsList(noCorrection: Bool, llmEnabled: Bool) -> [String] {
        var corrections: [String] = ["itn", "autocorrect"]
        if !noCorrection && llmEnabled {
            corrections.append("llm")
        }
        return corrections
    }
}

// MARK: - Result Type

struct TranscribeResult: Encodable {
    let text: String
    let language: String
    let model: String
    let audioDurationS: Double
    let processingTimeS: Double
    let correctionsApplied: [String]

    enum CodingKeys: String, CodingKey {
        case text, language, model
        case audioDurationS = "audio_duration_s"
        case processingTimeS = "processing_time_s"
        case correctionsApplied = "corrections_applied"
    }
}
