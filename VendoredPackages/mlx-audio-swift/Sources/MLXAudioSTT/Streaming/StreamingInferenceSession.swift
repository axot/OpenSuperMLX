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
}

// MARK: - StreamingInferenceSession

public class StreamingInferenceSession: @unchecked Sendable {
    private static let logger = Logger(subsystem: "MLXAudioSTT", category: "StreamingSession")

    private let model: Qwen3ASRModel
    private let config: StreamingConfig
    private let melProcessor: IncrementalMelSpectrogram
    private let vadSegmenter: VADSegmenter

    private let shared = OSAllocatedUnfairLock(initialState: SessionState())
    private let sessionLock = OSAllocatedUnfairLock(initialState: 0)

    private var isActive: Bool = false
    private var totalSamplesFed: Int = 0
    private var emptyRecoveryResets: Int = 0
    private var lastDecodeSampleCount: Int = 0
    private var hasProducedFirstToken: Bool = false
    private var lastFullResetSampleCount: Int = 0
    private var postResetSilenceWarned: Bool = false

    private var chunkProcessor: ContinuousChunkProcessor?
    private var chunkMelBuffer: MLXArray?
    private var chunkMelFrameCount: Int = 0

    private var continuation: AsyncStream<TranscriptionEvent>.Continuation?
    private var stopTask: Task<Void, Never>?

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

        Memory.cacheLimit = 64 * 1024 * 1024

        var continuation: AsyncStream<TranscriptionEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.continuation = continuation
        self.isActive = true
    }

    public var isVADAvailable: Bool { vadSegmenter.isAvailable }

    public var isSpeechActive: Bool { vadSegmenter.isSpeechActive }

    // 16000 Hz / 160 hop = 100 mel frames per second
    private var chunkSizeMelFrames: Int {
        Int(config.chunkDurationSeconds * 100)
    }

    // MARK: - Audio Input

    public func feedAudio(samples: [Float]) {
        sessionLock.withLock { _ in
            guard isActive else {
                Self.logger.warning("feedAudio: isActive=false, dropping \(samples.count) samples")
                return
            }
            totalSamplesFed += samples.count

            _ = vadSegmenter.feedSamples(samples)
            if let newMelFrames = melProcessor.process(samples: samples) {
                accumulateChunkMel(newMelFrames)
                let chunksBefore = chunkProcessor?.chunkIndex ?? 0
                let feedStart = ContinuousClock.now
                processAccumulatedChunks()
                let feedMs = feedStart.duration(to: .now).milliseconds
                let chunksAfter = chunkProcessor?.chunkIndex ?? 0
                let chunksProcessed = chunksAfter - chunksBefore
                if chunksProcessed > 0 {
                    Self.logger.info("feedAudio: processed \(chunksProcessed, privacy: .public) chunk(s) in \(feedMs, privacy: .public)ms totalSamples=\(self.totalSamplesFed, privacy: .public) melBuf=\(self.chunkMelFrameCount, privacy: .public)")
                }
            }
        }
    }

    // MARK: - Chunk Processing

    private func accumulateChunkMel(_ newFrames: MLXArray) {
        if let existing = chunkMelBuffer {
            chunkMelBuffer = MLX.concatenated([existing, newFrames], axis: 0)
        } else {
            chunkMelBuffer = newFrames
        }
        chunkMelFrameCount = chunkMelBuffer!.dim(0)
    }

    private func processAccumulatedChunks() {
        let chunkSize = chunkSizeMelFrames
        guard chunkSize > 0 else { return }

        while chunkMelFrameCount >= chunkSize {
            let chunkMel = chunkMelBuffer![0..<chunkSize]
            if chunkMelFrameCount > chunkSize {
                chunkMelBuffer = chunkMelBuffer![chunkSize..<chunkMelFrameCount]
            } else {
                chunkMelBuffer = nil
            }
            chunkMelFrameCount = chunkMelBuffer?.dim(0) ?? 0
            processChunk(melFrames: chunkMel, isFinal: false)
        }
    }

    private func processChunk(melFrames: MLXArray, isFinal: Bool) {
        guard let tokenizer = model.tokenizer else { return }

        if chunkProcessor == nil {
            chunkProcessor = ContinuousChunkProcessor(
                model: model, tokenizer: tokenizer, config: config
            )
        }
        guard let processor = chunkProcessor else { return }

        let startTime = Date()
        let lang = effectiveLanguage
        let result = processor.processChunk(melFrames: melFrames, language: lang, isFinal: isFinal)

        switch result.action {
        case .coldStart:
            return

        case .normal, .recoveryReset, .periodicReset:
            if !result.newlyEmittedTokens.isEmpty {
                lastDecodeSampleCount = totalSamplesFed
                emptyRecoveryResets = 0
                hasProducedFirstToken = true
                postResetSilenceWarned = false
            }

            let postResetSilenceThreshold = 16000 * 30 // 30 seconds at 16kHz
            if !hasProducedFirstToken
                && !postResetSilenceWarned
                && lastFullResetSampleCount > 0
                && totalSamplesFed - lastFullResetSampleCount > postResetSilenceThreshold {
                Self.logger.error("Post-reset silence: no tokens produced \(String(format: "%.0f", Double(self.totalSamplesFed - self.lastFullResetSampleCount) / 16000.0), privacy: .public)s after full stream reset")
                postResetSilenceWarned = true
            }

            if result.action == .recoveryReset && result.newlyEmittedTokens.isEmpty {
                emptyRecoveryResets += 1
                if emptyRecoveryResets >= 2 {
                    Self.logger.warning("Escalation: \(self.emptyRecoveryResets, privacy: .public) consecutive empty recovery resets — full stream reset")
                    performFullStreamReset()
                    return
                }
            }

            let noDecodeThreshold = 16000 * 20 // 20 seconds at 16kHz
            if hasProducedFirstToken
                && totalSamplesFed - lastDecodeSampleCount > noDecodeThreshold {
                Self.logger.warning("No-decode watchdog: \(String(format: "%.1f", Double(self.totalSamplesFed - self.lastDecodeSampleCount) / 16000.0), privacy: .public)s without decode output — full stream reset")
                performFullStreamReset()
                return
            }
            let confirmedRaw = tokenizer.decode(tokens: result.confirmedTokens)
            let parsedConfirmed = TextMergeUtilities.parseASROutput(confirmedRaw)
            let currentChunkIndex = processor.chunkIndex

            let provisionalText: String
            if result.action == .normal && !result.provisionalTokens.isEmpty {
                let provisionalRaw = tokenizer.decode(tokens: result.provisionalTokens)
                provisionalText = TextMergeUtilities.parseASROutput(provisionalRaw).text
            } else {
                provisionalText = ""
            }

            let newlyEmittedText: String
            if !result.newlyEmittedTokens.isEmpty {
                let raw = tokenizer.decode(tokens: result.newlyEmittedTokens)
                newlyEmittedText = TextMergeUtilities.parseASROutput(raw).text
            } else {
                newlyEmittedText = ""
            }

            let displayConfirmed: String = shared.withLock { state in
                state.committedTokenIds = result.confirmedTokens
                state.chunkCount = currentChunkIndex
                if result.action == .normal
                    && state.detectedLanguage.isEmpty
                    && parsedConfirmed.language != "unknown"
                {
                    state.detectedLanguage = parsedConfirmed.language
                }

                switch result.action {
                case .periodicReset, .recoveryReset, .normal, .coldStart:
                    if !newlyEmittedText.isEmpty {
                        state.mergedCommittedText = TextMergeUtilities.mergeWithOverlapRemoval(
                            prefix: state.mergedCommittedText, newText: newlyEmittedText)
                    } else if state.mergedCommittedText.isEmpty {
                        state.mergedCommittedText = parsedConfirmed.text
                    }
                }
                return state.mergedCommittedText
            }

            continuation?.yield(.displayUpdate(
                confirmedText: displayConfirmed,
                provisionalText: provisionalText
            ))
        }

        let decodeTime = Date().timeIntervalSince(startTime)
        let chunkTimeMs = Int(decodeTime * 1000)
        Self.logger.info("chunk action=\(String(describing: result.action), privacy: .public) newTokens=\(result.newlyEmittedTokens.count, privacy: .public) emptyResets=\(self.emptyRecoveryResets, privacy: .public) chunkTime=\(chunkTimeMs, privacy: .public)ms")
        continuation?.yield(.stats(StreamingStats(
            encodedWindowCount: processor.encodedWindowCount,
            totalAudioSeconds: Double(totalSamplesFed) / 16000.0,
            tokensPerSecond: decodeTime > 0 ? Double(result.newlyEmittedTokens.count) / decodeTime : 0,
            realTimeFactor: 0,
            peakMemoryGB: Double(Memory.peakMemory) / 1e9,
            chunkElapsedSeconds: decodeTime
        )))
    }

    // MARK: - Decoder Helpers

    static func resolveEffectiveLanguage(configLanguage: String, detectedLanguage: String) -> String {
        let configLang = configLanguage.trimmingCharacters(in: .whitespaces).lowercased()
        if !configLang.isEmpty && configLang != "auto" {
            return configLanguage
        }
        return configLanguage
    }

    private var effectiveLanguage: String {
        let detected = shared.withLock { $0.detectedLanguage }
        return StreamingInferenceSession.resolveEffectiveLanguage(
            configLanguage: config.language,
            detectedLanguage: detected
        )
    }

    // MARK: - Internal Reset

    private func performFullStreamReset() {
        resetProcessingState()
        emptyRecoveryResets = 0
        lastDecodeSampleCount = totalSamplesFed
        lastFullResetSampleCount = totalSamplesFed
        hasProducedFirstToken = false
        postResetSilenceWarned = false
        shared.withLock {
            $0.committedTokenIds = []
            $0.chunkCount = 0
        }
        Memory.clearCache()
    }

    private func resetProcessingState() {
        melProcessor.reset()
        vadSegmenter.reset()
        chunkProcessor = nil
        chunkMelBuffer = nil
        chunkMelFrameCount = 0
    }

    private func resetSharedState() {
        shared.withLock {
            $0.committedTokenIds = []
            $0.chunkCount = 0
            $0.mergedCommittedText = ""
        }
        Memory.clearCache()
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
            if let flushedMel = melProcessor.flush() {
                accumulateChunkMel(flushedMel)
            }
            if let remainingMel = chunkMelBuffer {
                processChunk(melFrames: remainingMel, isFinal: true)
                chunkMelBuffer = nil
                chunkMelFrameCount = 0
            }
        }

        if Task.isCancelled { return }

        let (finalText, tokenCount) = shared.withLock { ($0.mergedCommittedText, $0.committedTokenIds.count) }
        Self.logger.info("finishStop: text=\(finalText.count)ch tokens=\(tokenCount)")

        continuation?.yield(.ended(fullText: finalText))
        continuation?.finish()

        sessionLock.withLock { _ in
            self.continuation = nil
            stopTask = nil
            resetProcessingState()
        }

        resetSharedState()
    }

    // MARK: - Cancel

    public func cancel() {
        sessionLock.withLock { _ in
            isActive = false
            stopTask?.cancel()
            stopTask = nil
            continuation?.finish()
            continuation = nil
            resetProcessingState()
        }
        resetSharedState()
    }
}
