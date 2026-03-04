import Foundation
import AVFoundation
import MLXAudioSTT
import MLXAudioCore
import MLX
import HuggingFace
import os.log

private let logger = Logger(subsystem: "OpenSuperMLX", category: "MLXEngine")

class MLXEngine: TranscriptionEngine {
    var engineName: String { "MLX" }

    private var model: Qwen3ASRModel?
    private let cancelledLock = OSAllocatedUnfairLock(initialState: false)

    private var isCancelled: Bool {
        get { cancelledLock.withLock { $0 } }
        set { cancelledLock.withLock { $0 = newValue } }
    }

    var onProgressUpdate: ((Float) -> Void)?

    var isModelLoaded: Bool {
        model != nil
    }

    func initialize() async throws {
        let modelId = AppPreferences.shared.selectedMLXModel
        let cache = HubCache(cacheDirectory: MLXModelManager.modelsDirectory)
        logger.info("Initializing MLX model: \(modelId) from \(MLXModelManager.modelsDirectory.path)")
        let model = try await Qwen3ASRModel.fromPretrained(modelId, cache: cache)
        self.model = model
        logger.info("MLX model initialized")
    }

    func transcribeAudio(url: URL, settings: Settings) async throws -> String {
        guard let model = model else {
            throw TranscriptionError.contextInitializationFailed
        }

        isCancelled = false
        onProgressUpdate?(0.02)
        logger.info("Transcribing: \(url.lastPathComponent)")

        guard !isCancelled else {
            throw CancellationError()
        }

        logger.info("Loading audio...")
        let (_, audio) = try loadAudioArray(from: url, sampleRate: 16000)
        let audioDurationSec = Float(audio.shape[0]) / 16000.0
        logger.info("Audio loaded, samples: \(audio.shape[0]), duration: \(audioDurationSec)s")

        onProgressUpdate?(0.10)

        guard !isCancelled else {
            throw CancellationError()
        }

        Memory.cacheLimit = 4 * 1024 * 1024

        let language = mapLanguageCode(settings.selectedLanguage)
        let maxTokens = max(200, Int(audioDurationSec * 50))
        logger.info("Generating with language: \(language), maxTokens: \(maxTokens)")
        let startTime = Date()
        let output = model.generate(audio: audio, maxTokens: maxTokens, language: language)
        let elapsed = Date().timeIntervalSince(startTime)
        logger.info("Generate completed in \(String(format: "%.1f", elapsed))s, tokens: \(output.totalTokens), text length: \(output.text.count)")

        Memory.clearCache()

        guard !isCancelled else {
            throw CancellationError()
        }

        onProgressUpdate?(0.95)

        var processedText = output.text.trimmingCharacters(in: .whitespacesAndNewlines)

        if settings.shouldApplyAsianAutocorrect && !processedText.isEmpty {
            processedText = AutocorrectWrapper.format(processedText)
        }

        onProgressUpdate?(1.0)

        return processedText.isEmpty ? "No speech detected in the audio" : processedText
    }

    func cancelTranscription() {
        isCancelled = true
    }

    func getSupportedLanguages() -> [String] {
        return [
            "en", "zh", "ja", "ko",
            "de", "fr", "es", "it", "pt", "ru",
            "pl", "nl", "tr", "ar",
            "cs", "hu", "fi", "da",
            "el", "hr", "sk", "uk", "ca", "sv"
        ]
    }

    // MARK: - Private

    // MLX-only languages not in LanguageUtil.languageNames
    private static let supplementalLanguageNames: [String: String] = [
        "cs": "Czech",
        "hu": "Hungarian",
        "da": "Danish",
        "el": "Greek",
        "hr": "Croatian",
        "sk": "Slovak",
        "uk": "Ukrainian",
    ]

    private func mapLanguageCode(_ code: String) -> String {
        if code == "auto" {
            return "auto"
        }
        return LanguageUtil.languageNames[code]
            ?? Self.supplementalLanguageNames[code]
            ?? code
    }
}
