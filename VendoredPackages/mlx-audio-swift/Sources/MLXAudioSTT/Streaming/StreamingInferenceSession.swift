//
//  StreamingInferenceSession.swift
//  MLXAudioSTT
//
//  Created by Prince Canuma on 07/02/2026.
//

import Foundation
import MLX
import MLXNN
import MLXLMCommon
import Tokenizers
import os

// MARK: - Shared State

private struct SessionState: Sendable {
    var committedTokenIds: [Int] = []
    var chunkCount: Int = 0
    var mergedCommittedText: String = ""
    var detectedLanguage: String = ""
    var isDecoding: Bool = false
}

/// Orchestrates streaming speech-to-text inference using VAD-segmented audio.
///
/// Audio flows through Silero VAD (36ms frames), accumulates speech samples,
/// and triggers ASR decode on natural pause boundaries. Each speech segment
/// is processed exactly once — no speculative/pending window.
public class StreamingInferenceSession: @unchecked Sendable {
    private static let eosTokenIds = [151645, 151643]
    private static let logger = Logger(subsystem: "MLXAudioSTT", category: "StreamingSession")

    private let model: Qwen3ASRModel
    private let config: StreamingConfig
    private let melProcessor: IncrementalMelSpectrogram
    private let vadSegmenter: VADSegmenter

    private let shared = OSAllocatedUnfairLock(initialState: SessionState())
    private let sessionLock = OSAllocatedUnfairLock(initialState: 0)

    private var isActive: Bool = false
    private var totalSamplesFed: Int = 0

    private let shouldAbort = OSAllocatedUnfairLock(initialState: false)

    private var continuation: AsyncStream<TranscriptionEvent>.Continuation?
    private var stopTask: Task<Void, Never>?

    // MARK: - KV Cache State

    private var decoderCache: [KVCache]?

    public let events: AsyncStream<TranscriptionEvent>

    public init(model: Qwen3ASRModel, config: StreamingConfig = StreamingConfig()) {
        self.model = model
        self.config = config
        self.melProcessor = IncrementalMelSpectrogram(
            sampleRate: model.sampleRate,
            nFft: 400,
            hopLength: 160,
            nMels: model.config.audioConfig.numMelBins
        )
        self.vadSegmenter = VADSegmenter()

        var continuation: AsyncStream<TranscriptionEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.continuation = continuation
        self.isActive = true
        self.shouldAbort.withLock { $0 = false }
    }

    /// Whether VAD loaded successfully.
    public var isVADAvailable: Bool { vadSegmenter.isAvailable }

    /// Current VAD speech detection state for UI.
    public var isSpeechActive: Bool { vadSegmenter.isSpeechActive }

    // MARK: - Audio Input

    public func feedAudio(samples: [Float]) {
        sessionLock.withLock { _ in
            guard isActive else { return }
            totalSamplesFed += samples.count

            let segments = vadSegmenter.feedSamples(samples)
            for segment in segments {
                processCompletedSegment(segment)
            }
        }
    }

    // MARK: - Segment Processing

    private func processCompletedSegment(_ segment: SpeechSegment) {
        guard let tokenizer = model.tokenizer else { return }

        let startTime = Date()

        melProcessor.reset()

        var melFrames: MLXArray?
        if let frames = melProcessor.process(samples: segment.samples) {
            melFrames = frames
        }
        if let flushedFrames = melProcessor.flush() {
            if let existing = melFrames {
                melFrames = MLX.concatenated([existing, flushedFrames], axis: 0)
            } else {
                melFrames = flushedFrames
            }
        }

        guard let mel = melFrames else {
            Self.logger.warning("no mel frames from segment of \(segment.samples.count) samples")
            return
        }

        let audioFeatures = model.audioTower.encodeSingleWindow(mel)
        eval(audioFeatures)
        Memory.clearCache()

        let (logits, _) = forwardAudioFeatures(audioFeatures)
        let recentContext = shared.withLock { $0.committedTokenIds }
        let tokens = generateTokens(
            initialLogits: logits,
            tokenizer: tokenizer,
            maxTokens: config.maxNewTokensPerChunk,
            recentContext: recentContext
        )
        if tokens.count <= 10 {
            Self.logger.info("tokenIds=\(tokens, privacy: .public)")
        }
        let lang = effectiveLanguage
        let parsed = TextMergeUtilities.parseASROutput(tokenizer.decode(tokens: tokens))
        let segmentText = parsed.text

        let displayText = shared.withLock { state -> String in
            state.committedTokenIds += tokens
            state.chunkCount += 1

            if state.detectedLanguage.isEmpty && parsed.language != "unknown" {
                state.detectedLanguage = parsed.language
            }

            let beforeMerge = state.mergedCommittedText
            state.mergedCommittedText = TextMergeUtilities.mergeChunkText(
                accumulated: state.mergedCommittedText,
                newChunk: segmentText,
                language: lang
            )
            let afterMerge = state.mergedCommittedText
            if !segmentText.isEmpty {
                Self.logger.info("merge: before(last20)='\(beforeMerge.suffix(20), privacy: .public)' + chunk='\(segmentText.prefix(30), privacy: .public)' → after(last30)='\(afterMerge.suffix(30), privacy: .public)'")
            }
            return state.mergedCommittedText
        }

        let decodeTime = Date().timeIntervalSince(startTime)
        let totalTokens = shared.withLock { $0.committedTokenIds.count }
        Self.logger.info("segment: duration=\(String(format: "%.1f", segment.durationSeconds), privacy: .public)s samples=\(segment.samples.count, privacy: .public) tokens=\(tokens.count) total=\(totalTokens) time=\(String(format: "%.2f", decodeTime), privacy: .public)s text='\(segmentText.prefix(40), privacy: .public)'")

        continuation?.yield(.displayUpdate(confirmedText: displayText, provisionalText: ""))

        continuation?.yield(.stats(StreamingStats(
            encodedWindowCount: shared.withLock { $0.chunkCount },
            totalAudioSeconds: Double(totalSamplesFed) / 16000.0,
            tokensPerSecond: decodeTime > 0 ? Double(tokens.count) / decodeTime : 0,
            realTimeFactor: 0,
            peakMemoryGB: Double(Memory.peakMemory) / 1e9
        )))

        Memory.clearCache()
    }

    // MARK: - Decoder Helpers

    private var effectiveLanguage: String {
        let detected = shared.withLock { $0.detectedLanguage }
        return detected.isEmpty ? config.language : detected
    }

    private func forwardAudioFeatures(_ audioFeatures: MLXArray) -> (logits: MLXArray, inputIds: MLXArray) {
        let lang = effectiveLanguage
        let inputIds: MLXArray
        if decoderCache == nil {
            decoderCache = model.makeCache(maxKVSize: config.maxKVSize)
            inputIds = model.buildPrompt(
                numAudioTokens: audioFeatures.dim(0),
                language: lang,
                prefix: ""
            )
        } else {
            inputIds = model.buildFollowUpPrompt(
                numAudioTokens: audioFeatures.dim(0),
                language: lang
            )
        }
        let embeds = model.model.embedTokens(inputIds)
        let inputsEmbeds = model.mergeAudioFeatures(
            inputsEmbeds: embeds,
            audioFeatures: audioFeatures.asType(embeds.dtype),
            inputIds: inputIds
        )
        let logits = model.callAsFunction(
            inputIds: inputIds,
            inputEmbeddings: inputsEmbeds,
            cache: decoderCache
        )
        eval(logits)
        return (logits, inputIds)
    }

    // MARK: - Token Generation

    private func generateTokens(
        initialLogits: MLXArray,
        tokenizer: any Tokenizer,
        maxTokens: Int,
        recentContext: [Int],
        emitUpdates: ((_ newTokens: [Int]) -> Void)? = nil
    ) -> [Int] {
        var logits = initialLogits
        var newTokenIds: [Int] = []
        var recentTokenIds = Array(recentContext.suffix(config.repetitionContextSize))

        for _ in 0..<maxTokens {
            if shouldAbort.withLock({ $0 }) {
                Self.logger.warning("generateTokens aborted after \(newTokenIds.count) tokens")
                return newTokenIds
            }

            var lastLogits = logits[0..., -1, 0...]
            if config.temperature > 0 {
                lastLogits = lastLogits / config.temperature
            }

            if config.repetitionPenalty > 1.0 && !recentTokenIds.isEmpty {
                let indices = MLXArray(recentTokenIds.map { UInt32($0) })
                var selected = lastLogits[0..., indices]
                selected = MLX.where(selected .< 0, selected * config.repetitionPenalty, selected / config.repetitionPenalty)
                lastLogits[0..., indices] = selected
            }

            let nextToken = lastLogits.argMax(axis: -1).item(Int.self)
            if Self.eosTokenIds.contains(nextToken) { break }
            newTokenIds.append(nextToken)

            recentTokenIds.append(nextToken)
            if recentTokenIds.count > config.repetitionContextSize {
                recentTokenIds.removeFirst()
            }

            if RepetitionDetector.detectTokenRepetition(newTokenIds) {
                let removeCount = min(newTokenIds.count, 20)
                Self.logger.warning("RepetitionDetector: removing last \(removeCount) of \(newTokenIds.count) tokens")
                newTokenIds.removeLast(removeCount)
                break
            }

            emitUpdates?(newTokenIds)

            let nextTokenArray = MLXArray([Int32(nextToken)]).expandedDimensions(axis: 0)
            logits = model.callAsFunction(inputIds: nextTokenArray, cache: decoderCache)
            eval(logits)
        }

        return newTokenIds
    }

    // MARK: - Stop

    public func stop() {
        sessionLock.withLock { _ in
            guard isActive else { return }
            isActive = false

            stopTask?.cancel()
            stopTask = Task.detached { [self] in
                await finishStop()
            }
        }
    }

    private func finishStop() async {
        if Task.isCancelled { return }

        sessionLock.withLock { _ in
            if let remaining = vadSegmenter.flush(force: true) {
                processCompletedSegment(remaining)
            }
        }

        if Task.isCancelled { return }

        let finalText = shared.withLock { $0.mergedCommittedText }
        Self.logger.info("finishStop: text=\(finalText.count)ch tokens=\(self.shared.withLock { $0.committedTokenIds.count })")

        continuation?.yield(.ended(fullText: finalText))
        continuation?.finish()

        sessionLock.withLock { _ in
            self.continuation = nil
            stopTask = nil
            melProcessor.reset()
            vadSegmenter.reset()
        }

        shared.withLock {
            $0.committedTokenIds = []
            $0.chunkCount = 0
            $0.mergedCommittedText = ""
        }
        decoderCache = nil
        Memory.clearCache()
    }

    // MARK: - Cancel

    public func cancel() {
        shouldAbort.withLock { $0 = true }
        sessionLock.withLock { _ in
            isActive = false
            stopTask?.cancel()
            stopTask = nil
            continuation?.finish()
            continuation = nil
            melProcessor.reset()
            vadSegmenter.reset()
            decoderCache = nil
        }
        shared.withLock {
            $0.committedTokenIds = []
            $0.chunkCount = 0
            $0.mergedCommittedText = ""
        }
        Memory.clearCache()
    }
}
