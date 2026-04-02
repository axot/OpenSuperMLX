//
//  CLITranscribe.swift
//  OpenSuperMLX
//

import Foundation
import MLXAudioSTT
import MLXAudioCore
import MLX
import HuggingFace
import os.log

enum CLITranscribe {

    static func run(audioPath: String, language: String) async -> Never {
        let logger = Logger(subsystem: "OpenSuperMLX", category: "CLI")

        let url = URL(fileURLWithPath: audioPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            fputs("Error: file not found: \(audioPath)\n", stderr)
            exit(1)
        }

        fputs("Loading model...\n", stderr)
        let modelId = AppPreferences.shared.selectedMLXModel
        let cache = HubCache(cacheDirectory: MLXModelManager.modelsDirectory)

        let model: Qwen3ASRModel
        do {
            model = try await Qwen3ASRModel.fromPretrained(modelId, cache: cache)
        } catch {
            fputs("Error loading model: \(error)\n", stderr)
            exit(1)
        }
        fputs("Model loaded: \(modelId)\n", stderr)

        fputs("Loading audio: \(url.lastPathComponent)\n", stderr)
        let samples: [Float]
        let totalSamples: Int
        do {
            let (_, audio) = try loadAudioArray(from: url, sampleRate: 16000)
            totalSamples = audio.dim(0)
            samples = audio.asArray(Float.self)
        } catch {
            fputs("Error loading audio: \(error)\n", stderr)
            exit(1)
        }

        let durationSec = Float(totalSamples) / 16000.0
        fputs("Audio: \(totalSamples) samples, \(String(format: "%.1f", durationSec))s\n", stderr)

        let config = StreamingConfig(
            language: language
        )
        let session = StreamingInferenceSession(model: model, config: config)

        let eventTask = Task {
            var lastConfirmed = ""
            var lastProvisional = ""
            for await event in session.events {
                switch event {
                case .displayUpdate(let confirmed, let provisional):
                    lastConfirmed = confirmed
                    lastProvisional = provisional
                    let display = confirmed + provisional
                    fputs("\r\u{1B}[2K[\(display.count)ch] \(display.suffix(80))", stderr)
                case .ended(let fullText):
                    fputs("\n", stderr)
                    print(RepetitionCleaner.clean(fullText))
                case .stats(let stats):
                    logger.info("CLI stats: \(stats.tokensPerSecond, format: .fixed(precision: 1), privacy: .public) tok/s")
                default:
                    break
                }
            }
            if !lastConfirmed.isEmpty || !lastProvisional.isEmpty {
                fputs("\n", stderr)
                let finalText = lastConfirmed + lastProvisional
                if !finalText.isEmpty {
                    print(finalText)
                }
            }
        }

        let chunkSize = 3200  // 0.2s chunks to simulate streaming
        var offset = 0
        while offset < samples.count {
            let end = min(offset + chunkSize, samples.count)
            let chunk = Array(samples[offset..<end])
            session.feedAudio(samples: chunk)
            offset = end

            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms between chunks
        }

        fputs("\nFinalizing...\n", stderr)
        session.stop()
        _ = await eventTask.value

        exit(0)
    }
}
