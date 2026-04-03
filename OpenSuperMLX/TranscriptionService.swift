import AVFoundation
import Foundation
import os.log

import MLXAudioSTT

private let logger = Logger(subsystem: "OpenSuperMLX", category: "TranscriptionService")

// MARK: - Dual-Track Types

enum SegmentSource: Equatable {
    case microphone
    case systemAudio
}

struct TranscriptionSegment {
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let source: SegmentSource
}

// MARK: -

@MainActor
class TranscriptionService: ObservableObject {
    static let shared = TranscriptionService()
    
    @Published private(set) var isTranscribing = false
    @Published private(set) var transcribedText = ""
    @Published private(set) var currentSegment = ""
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: Error?
    @Published private(set) var progress: Float = 0.0
    
    private var currentEngine: TranscriptionEngine?

    var streamingModel: Qwen3ASRModel? {
        (currentEngine as? MLXEngine)?.qwen3Model
    }
    private var totalDuration: Float = 0.0
    private var transcriptionTask: Task<String, Error>?
    private var isCancelled = false
    
    init() {
        if !ProcessInfo.processInfo.arguments.contains("--skip-model-load") {
            loadEngine()
        }
    }
    
    init(engine: TranscriptionEngine?) {
        self.currentEngine = engine
        self.isLoading = false
    }
    
    // MARK: - Dual-Track Transcription

    func mergeTranscripts(micSegments: [TranscriptionSegment], systemSegments: [TranscriptionSegment]) -> String {
        let allSegments = (micSegments + systemSegments).sorted { $0.startTime < $1.startTime }
        return allSegments.map(\.text).joined(separator: "\n")
    }

    func processSystemAudioTrack(_ url: URL) async throws -> [TranscriptionSegment] {
        guard let engine = currentEngine else {
            throw TranscriptionError.contextInitializationFailed
        }

        let settings = Settings()
        let result = try await Task.detached(priority: .userInitiated) {
            try await engine.transcribeAudio(url: url, settings: settings)
        }.value

        guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }

        let duration: Float = await (try? Task.detached(priority: .userInitiated) {
            let asset = AVAsset(url: url)
            let d = try await asset.load(.duration)
            return Float(CMTimeGetSeconds(d))
        }.value) ?? 0.0

        return [TranscriptionSegment(
            text: result,
            startTime: 0,
            endTime: TimeInterval(duration),
            source: .systemAudio
        )]
    }

    @discardableResult
    func handleDualTrackCompletion(
        systemAudioURL: URL?,
        outputType: OutputType,
        micTranscription: String,
        recordingId: UUID
    ) async -> String? {
        guard let systemAudioURL else {
            logger.info("No system audio track, using mic transcription only")
            return nil
        }

        do {
            var audioToTranscribe = systemAudioURL

            if outputType == .speakers || outputType == .unknown {
                let micTrackURL = RecordingStore.shared.recordings
                    .first(where: { $0.id == recordingId })?.url

                if let micTrackURL {
                    audioToTranscribe = try await AECService.shared.processRecording(
                        micTrackURL: micTrackURL,
                        systemAudioTrackURL: systemAudioURL
                    )
                }
            }

            let systemSegments = try await processSystemAudioTrack(audioToTranscribe)

            guard !systemSegments.isEmpty else {
                logger.info("System audio track was silent, using mic transcription only")
                return nil
            }

            let micSegments = [TranscriptionSegment(
                text: micTranscription,
                startTime: 0,
                endTime: 0,
                source: .microphone
            )]

            let mergedText = mergeTranscripts(micSegments: micSegments, systemSegments: systemSegments)

            await RecordingStore.shared.updateRecordingProgressOnlySync(
                recordingId,
                transcription: mergedText,
                progress: 1.0,
                status: .completed
            )
            return mergedText
        } catch {
            logger.error("Dual-track processing failed: \(error, privacy: .public)")
            return nil
        }
    }

    // MARK: - Cancellation

    func cancelTranscription() {
        isCancelled = true
        currentEngine?.cancelTranscription()
        transcriptionTask?.cancel()
        transcriptionTask = nil
        
        isTranscribing = false
        currentSegment = ""
        progress = 0.0
    }
    
    private func loadEngine() {
        logger.info("Loading MLX engine")
        if AppPreferences.shared.debugMode {
            logger.debug("[DEBUG] Engine load requested: model=\(AppPreferences.shared.selectedMLXModel, privacy: .public), language=\(AppPreferences.shared.mlxLanguage, privacy: .public), streaming=\(AppPreferences.shared.useStreamingTranscription, privacy: .public)")
        }
        
        isLoading = true
        loadError = nil
        
        Task.detached(priority: .userInitiated) {
            let engine = await MLXEngine()
            
            do {
                try await engine.initialize()
                await MainActor.run {
                    self.currentEngine = engine
                    logger.info("MLX engine loaded successfully")
                    StreamingAudioService.shared.warmUp()
                }
            } catch {
                await MainActor.run {
                    self.loadError = error
                    logger.error("Failed to load MLX engine: \(error, privacy: .public)")
                }
            }
            
            await MainActor.run {
                self.isLoading = false
            }
        }
    }
    
    func reloadEngine() {
        guard !isTranscribing else {
            logger.warning("Cannot reload engine while transcribing")
            return
        }
        loadEngine()
    }
    
    func reloadModel(with path: String) {
        reloadEngine()
    }
    
    func transcribeAudio(url: URL, settings: Settings, applyCorrection: Bool = true, forceLLM: Bool = false) async throws -> String {
        logger.info("Starting transcription for: \(url.lastPathComponent, privacy: .public)")
        if AppPreferences.shared.debugMode {
            logger.debug("[DEBUG] Transcription settings: language=\(settings.selectedLanguage, privacy: .public), temperature=\(settings.temperature, privacy: .public), applyCorrection=\(applyCorrection, privacy: .public), forceLLM=\(forceLLM, privacy: .public)")
        }
        
        self.progress = 0.0
        self.isTranscribing = true
        self.transcribedText = ""
        self.currentSegment = ""
        self.isCancelled = false
        
        defer {
            self.isTranscribing = false
            self.currentSegment = ""
            if !self.isCancelled {
                self.progress = 1.0
            }
            self.transcriptionTask = nil
            logger.info("Transcription state cleaned up")
        }
        
        let durationInSeconds: Float = await (try? Task.detached(priority: .userInitiated) {
            let asset = AVAsset(url: url)
            let duration = try await asset.load(.duration)
            return Float(CMTimeGetSeconds(duration))
        }.value) ?? 0.0
        
        self.totalDuration = durationInSeconds
        logger.info("Audio duration: \(durationInSeconds, privacy: .public)s")
        if AppPreferences.shared.debugMode {
            logger.debug("[DEBUG] Engine state: engineLoaded=\(self.currentEngine != nil, privacy: .public), isTranscribing=\(self.isTranscribing, privacy: .public), totalDuration=\(durationInSeconds, privacy: .public)s")
        }
        
        guard let engine = currentEngine else {
            throw TranscriptionError.contextInitializationFailed
        }
        
        if let mlxEngine = engine as? MLXEngine {
            mlxEngine.onProgressUpdate = { [weak self] (newProgress: Float) in
                Task { @MainActor in
                    guard let self = self, !self.isCancelled else { return }
                    self.progress = newProgress
                }
            }
        }
        
        logger.info("Starting MLX generate...")
        
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            try Task.checkCancellation()
            
            let cancelled = await MainActor.run {
                guard let self = self else { return true }
                return self.isCancelled
            }
            
            guard !cancelled else {
                throw CancellationError()
            }
            
            let result = try await engine.transcribeAudio(url: url, settings: settings)
            
            try Task.checkCancellation()
            let correctedResult: String
            if applyCorrection {
                correctedResult = await LLMCorrectionService.shared.correctTranscription(result, forceEnabled: forceLLM)
            } else {
                correctedResult = result
            }
            try Task.checkCancellation()
            
            await MainActor.run {
                guard let self = self, !self.isCancelled else { return }
                self.transcribedText = correctedResult
                self.progress = 1.0
                logger.info("Transcription completed: \(correctedResult.prefix(50), privacy: .public)...")
            }
            
            return correctedResult
        }
        
        self.transcriptionTask = task
        
        do {
            return try await task.value
        } catch is CancellationError {
            self.isCancelled = true
            throw TranscriptionError.cancelled
        }
    }
}

enum TranscriptionError: LocalizedError {
    case contextInitializationFailed
    case audioConversionFailed
    case processingFailed
    case cancelled

    var errorDescription: String? {
        switch self {
        case .contextInitializationFailed:
            return "Failed to initialize transcription context."
        case .audioConversionFailed:
            return "Failed to convert audio to the required format."
        case .processingFailed:
            return "An error occurred during transcription processing."
        case .cancelled:
            return "Transcription was cancelled."
        }
    }
}
