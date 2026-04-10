// StreamSimulateCommand.swift
// OpenSuperMLX

import Foundation

import ArgumentParser

struct StreamSimulateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stream-simulate",
        abstract: "Simulate streaming transcription from an audio file"
    )

    @OptionGroup var globalOptions: GlobalOptions

    @Argument(help: "Path to audio file")
    var file: String

    @Option(name: .long, help: "Language code (default: auto)")
    var language: String = "auto"

    @Option(name: .long, help: "Model repository ID")
    var model: String?

    @Option(name: .long, help: "Chunk duration in seconds")
    var chunkDuration: Double = 0.5

    // MARK: - Execution

    func run() throws {
        let cmd = self
        runAsync {
            let service = StreamingAudioService.shared
            let result = await cmd.executeStreamSimulate(service: service)

            switch result {
            case .success(let data):
                CLIOutput.printSuccess(command: "stream-simulate", data: data, json: cmd.globalOptions.json)
            case .failure(let error):
                CLIOutput.printError(command: "stream-simulate", error: error, json: cmd.globalOptions.json)
                throw ExitCode(1)
            }
        }
    }

    @MainActor
    func executeStreamSimulate(
        service: StreamingAudioService
    ) async -> Result<StreamSimulateResult, CLIError> {
        let url = URL(fileURLWithPath: file)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .failure(.audioFileNotFound)
        }

        if let model = model {
            AppPreferences.shared.selectedMLXModel = model
        }

        CLIOutput.printProgress("Loading model...", quiet: globalOptions.quiet)

        let transcriptionService = TranscriptionService.shared
        var waitCount = 0
        while transcriptionService.isLoading && waitCount < 120 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            waitCount += 1
        }

        guard transcriptionService.streamingModel != nil else {
            return .failure(.modelLoadFailed)
        }

        CLIOutput.printProgress(
            "Simulating stream from \(url.lastPathComponent)...", quiet: globalOptions.quiet
        )
        let startTime = CFAbsoluteTimeGetCurrent()
        let settings = Settings()

        do {
            let injectionResult = try await service.injectAudioFromFile(
                url: url,
                language: language,
                temperature: Float(settings.temperature),
                chunkDuration: chunkDuration,
                onEvent: { _ in }
            )
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime

            let data = StreamSimulateResult(
                text: injectionResult.text,
                language: language,
                model: AppPreferences.shared.selectedMLXModel,
                audioDurationS: injectionResult.audioDurationS,
                processingTimeS: elapsed,
                chunksFed: injectionResult.chunksFed,
                chunkDurationS: chunkDuration,
                intermediateUpdates: injectionResult.intermediateUpdates
            )
            return .success(data)
        } catch let error as StreamingAudioError {
            switch error {
            case .modelNotLoaded:
                return .failure(.modelLoadFailed)
            case .streamTimeout:
                return .failure(.streamTimeout)
            case .audioFormatCreationFailed:
                return .failure(.transcriptionFailed)
            }
        } catch {
            return .failure(.transcriptionFailed)
        }
    }
}

// MARK: - Result Type

struct StreamSimulateResult: Encodable {
    let text: String
    let language: String
    let model: String
    let audioDurationS: Double
    let processingTimeS: Double
    let chunksFed: Int
    let chunkDurationS: Double
    let intermediateUpdates: Int

    enum CodingKeys: String, CodingKey {
        case text, language, model
        case audioDurationS = "audio_duration_s"
        case processingTimeS = "processing_time_s"
        case chunksFed = "chunks_fed"
        case chunkDurationS = "chunk_duration_s"
        case intermediateUpdates = "intermediate_updates"
    }
}
