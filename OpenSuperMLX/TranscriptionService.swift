import AVFoundation
import Foundation
import os.log

private let logger = Logger(subsystem: "OpenSuperMLX", category: "TranscriptionService")

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
    private var totalDuration: Float = 0.0
    private var transcriptionTask: Task<String, Error>?
    private var isCancelled = false
    
    init() {
        loadEngine()
    }
    
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
        
        isLoading = true
        loadError = nil
        
        Task.detached(priority: .userInitiated) {
            let engine = await MLXEngine()
            
            do {
                try await engine.initialize()
                await MainActor.run {
                    self.currentEngine = engine
                    logger.info("MLX engine loaded successfully")
                }
            } catch {
                await MainActor.run {
                    self.loadError = error
                    logger.error("Failed to load MLX engine: \(error)")
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
    
    func transcribeAudio(url: URL, settings: Settings) async throws -> String {
        logger.info("Starting transcription for: \(url.lastPathComponent)")
        
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
        logger.info("Audio duration: \(durationInSeconds)s")
        
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
            let correctedResult = await BedrockService.shared.correctTranscription(result)
            try Task.checkCancellation()
            
            await MainActor.run {
                guard let self = self, !self.isCancelled else { return }
                self.transcribedText = correctedResult
                self.progress = 1.0
                logger.info("Transcription completed: \(correctedResult.prefix(50))...")
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

enum TranscriptionError: Error {
    case contextInitializationFailed
    case audioConversionFailed
    case processingFailed
    case cancelled
}
