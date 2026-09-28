import AVFoundation
import Foundation
import os.log

import HuggingFace
import MLX
import MLXAudioCore
import MLXAudioSTT

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
    var downloadProgressHandler: (@Sendable @MainActor (Progress) -> Void)?

    var qwen3Model: Qwen3ASRModel? { model }

    var isModelLoaded: Bool {
        model != nil
    }

    func initialize() async throws {
        let modelId = MLXModelManager.model.repoID
        let cache = HubCache(cacheDirectory: MLXModelManager.modelsDirectory)
        logger.info("Initializing MLX model: \(modelId, privacy: .public) from \(MLXModelManager.modelsDirectory.path, privacy: .public)")
        let audioTowerURL = await Self.neuralEngineAudioTowerURL(
            enabled: AppPreferences.shared.useNeuralEngineAudioTower,
            resolve: { try await CoreMLAudioTowerAssets.resolve(progressHandler: downloadProgressHandler) },
            onFallback: Self.reportNeuralEngineFallback
        )
        let model: Qwen3ASRModel
        do {
            model = try await Qwen3ASRModel.fromPretrained(
                modelId, cache: cache, audioTowerURL: audioTowerURL, progressHandler: downloadProgressHandler
            )
        } catch let error as Qwen3ASRCoreMLAudioTowerError {
            Self.reportNeuralEngineFallback(error)
            model = try await Qwen3ASRModel.fromPretrained(modelId, cache: cache, progressHandler: downloadProgressHandler)
        }
        model.onCoreMLAudioTowerFallback = Self.reportNeuralEngineFallback
        self.model = model
        logger.info("MLX model initialized, audio encoder: \(model.usesCoreMLAudioTower ? "Neural Engine" : "GPU", privacy: .public)")
        if AppPreferences.shared.debugMode {
            logger.debug("[DEBUG] MLX engine config: modelId=\(modelId, privacy: .public), cacheDir=\(MLXModelManager.modelsDirectory.path, privacy: .public)")
        }
    }

    // MARK: - Neural Engine Audio Tower

    static func neuralEngineAudioTowerURL(
        enabled: Bool,
        resolve: () async throws -> URL,
        onFallback: (Error) -> Void
    ) async -> URL? {
        guard enabled else { return nil }
        do {
            return try await resolve()
        } catch {
            onFallback(error)
            return nil
        }
    }

    private static func reportNeuralEngineFallback(_ error: Error) {
        logger.error("Neural Engine audio encoder unavailable, using the GPU: \(error, privacy: .public)")
        Task { @MainActor in
            ErrorToastManager.shared.show("Neural Engine audio encoder unavailable. Using the GPU instead.")
        }
    }

    func transcribeAudio(url: URL, settings: Settings) async throws -> String {
        guard let model = model else {
            throw TranscriptionError.contextInitializationFailed
        }

        isCancelled = false
        onProgressUpdate?(0.02)
        logger.info("Transcribing: \(url.lastPathComponent, privacy: .public)")

        guard !isCancelled else {
            throw CancellationError()
        }

        logger.info("Loading audio...")
        let (_, audio) = try loadAudioArray(from: url, sampleRate: 16000)
        let audioDurationSec = Float(audio.shape[0]) / 16000.0
        logger.info("Audio loaded, samples: \(audio.shape[0], privacy: .public), duration: \(audioDurationSec, privacy: .public)s")

        onProgressUpdate?(0.10)

        guard !isCancelled else {
            throw CancellationError()
        }

        Memory.cacheLimit = 64 * 1024 * 1024

        let language = mapLanguageCode(settings.selectedLanguage)
        let chunkDuration: Float = 1200.0
        let expectedChunks = max(1, Int(ceil(audioDurationSec / chunkDuration)))
        let maxTokens = expectedChunks * 4096
        if AppPreferences.shared.debugMode {
            logger.debug("[DEBUG] Generation params: language=\(language, privacy: .public), maxTokens=\(maxTokens, privacy: .public), chunks=\(expectedChunks, privacy: .public), chunkDuration=\(chunkDuration, privacy: .public)s, memoryCacheLimit=64MB")
        }
        logger.info("Generating with language: \(language, privacy: .public), maxTokens: \(maxTokens, privacy: .public), chunks: ~\(expectedChunks, privacy: .public), chunkDuration: \(chunkDuration, privacy: .public)s")
        let startTime = Date()
        let output = try model.generate(audio: audio, maxTokens: maxTokens, language: language, chunkDuration: chunkDuration)
        let elapsed = Date().timeIntervalSince(startTime)
        logger.info("Generate completed in \(String(format: "%.1f", elapsed), privacy: .public)s, tokens: \(output.totalTokens, privacy: .public), text length: \(output.text.count, privacy: .public)")
        if AppPreferences.shared.debugMode {
            let tokensPerSec = elapsed > 0 ? Double(output.totalTokens) / elapsed : 0
            logger.debug("[DEBUG] Generate performance: elapsed=\(String(format: "%.2f", elapsed), privacy: .public)s, tokensPerSec=\(String(format: "%.1f", tokensPerSec), privacy: .public), autocorrect=\(settings.shouldApplyAsianAutocorrect, privacy: .public)")
        }

        Memory.clearCache()

        guard !isCancelled else {
            throw CancellationError()
        }

        onProgressUpdate?(0.95)

        var processedText = output.text.trimmingCharacters(in: .whitespacesAndNewlines)

        if settings.shouldApplyChineseITN && !processedText.isEmpty {
            processedText = ITNProcessor.process(processedText)
        }

        if settings.shouldApplyEnglishITN && !processedText.isEmpty {
            processedText = NemoTextProcessing.normalizeSentence(processedText)
        }

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
