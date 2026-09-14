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

    private let decodeTokens: ([Int]) -> String
    private let makeProcessor: (StreamingConfig, Int) -> (any StreamingChunkProcessing)?
    private let config: StreamingConfig
    private let melProcessor: IncrementalMelSpectrogram
    private let vadSegmenter: VADSegmenter?

    private let shared = OSAllocatedUnfairLock(initialState: SessionState())
    private let sessionLock = OSAllocatedUnfairLock(initialState: 0)

    private var isActive: Bool = false
    private var totalSamplesFed: Int = 0
    private var processedMelFrameCount: Int = 0
    private var emptyRecoveryResets: Int = 0
    private var lastDecodeMelFrame: Int = 0
    private var hasProducedFirstToken: Bool = false
    private var lastFullResetMelFrame: Int = 0
    private var postResetSilenceWarned: Bool = false
    private var previousConfirmedText: String = ""
    private var finalizationBaseline: String = ""
    private var windowRecovery: StreamingWindowRecovery
    private var inferenceFailed = false
    private var failedRecoveryMel: MLXArray?

    private var chunkProcessor: (any StreamingChunkProcessing)?
    private var chunkMelBuffer: MLXArray?
    private var chunkMelFrameCount: Int = 0

    private var continuation: AsyncStream<TranscriptionEvent>.Continuation?
    private var stopTask: Task<Void, Never>?

    public let events: AsyncStream<TranscriptionEvent>

    public convenience init(model: Qwen3ASRModel, config: StreamingConfig = StreamingConfig()) {
        self.init(
            config: config, sampleRate: model.sampleRate, melBins: model.config.audioConfig.numMelBins,
            vadSegmenter: VADSegmenter(),
            decodeTokens: { model.tokenizer?.decode(tokens: $0) ?? "" },
            makeProcessor: { config, offset in
                guard let tokenizer = model.tokenizer else { return nil }
                return ContinuousChunkProcessor(
                    model: model, tokenizer: tokenizer, config: config, melFrameOffset: offset
                )
            }
        )
    }

    init(
        config: StreamingConfig, sampleRate: Int, melBins: Int, vadSegmenter: VADSegmenter? = nil,
        decodeTokens: @escaping ([Int]) -> String,
        makeProcessor: @escaping (StreamingConfig, Int) -> (any StreamingChunkProcessing)?
    ) {
        self.decodeTokens = decodeTokens
        self.makeProcessor = makeProcessor
        self.config = config
        self.windowRecovery = StreamingWindowRecovery(
            windowFrames: config.encoderWindowSizeMelFrames, maximumWindows: config.maxEncoderWindows
        )
        self.melProcessor = IncrementalMelSpectrogram(
            sampleRate: sampleRate,
            nFft: 400,
            hopLength: 160,
            nMels: melBins
        )
        self.vadSegmenter = vadSegmenter

        Memory.cacheLimit = 64 * 1024 * 1024

        var continuation: AsyncStream<TranscriptionEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.continuation = continuation
        self.isActive = true
    }

    public var isVADAvailable: Bool { vadSegmenter?.isAvailable ?? false }

    public var isSpeechActive: Bool { vadSegmenter?.isSpeechActive ?? false }

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
            guard !inferenceFailed else { return }

            _ = vadSegmenter?.feedSamples(samples)
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
        processedMelFrameCount += melFrames.dim(0)
        if chunkProcessor == nil {
            chunkProcessor = makeProcessor(config, 0)
        }
        guard var processor = chunkProcessor else { return }

        let startTime = Date()
        let lang = effectiveLanguage
        var replacingTranscript = false
        var result = processor.processChunk(
            melFrames: melFrames, language: lang, isFinal: isFinal, isRecovery: false
        )
        if result.action == .repetitionDetected {
            guard let checkpoint = windowRecovery.begin(
                endFrame: processor.endMelFrame, availableStartFrame: processor.melFrameOffset
            ), let replay = processor.recoveryMel(from: checkpoint.frame) else {
                emitResult(processor.finalizeAccepted(), processor: processor, isFinal: true, startTime: startTime)
                suspendInference(frozenText: shared.withLock { $0.mergedCommittedText })
                return
            }
            Self.logger.warning("Window recovery: inference mel [\(checkpoint.frame, privacy: .public), \(processor.endMelFrame, privacy: .public)); checkpointCharacters=\(checkpoint.text.count, privacy: .public), fresh encoder/prefix/KV")
            var recoveryConfig = config
            recoveryConfig.coldStartChunks = 0
            guard let replacement = makeProcessor(recoveryConfig, checkpoint.frame) else {
                failedRecoveryMel = replay
                suspendInference(frozenText: checkpoint.text)
                return
            }
            let candidate = replacement.processChunk(
                melFrames: replay, language: lang, isFinal: isFinal, isRecovery: true
            )
            guard candidate.action == .normal else {
                failedRecoveryMel = replay
                suspendInference(frozenText: checkpoint.text)
                return
            }
            chunkProcessor = replacement
            processor = replacement
            result = candidate
            replacingTranscript = true
            previousConfirmedText = ""
            finalizationBaseline = ""
            if !replacement.allDecodedTokens.isEmpty {
                lastDecodeMelFrame = processedMelFrameCount
                hasProducedFirstToken = true
            }
            Self.logger.info("Window recovery accepted: tokens=\(replacement.allDecodedTokens.count, privacy: .public)")
        }
        emitResult(
            result, processor: processor, isFinal: isFinal, startTime: startTime,
            replacingTranscript: replacingTranscript
        )
    }

    private func emitResult(
        _ result: ChunkProcessingResult, processor: any StreamingChunkProcessing, isFinal: Bool,
        startTime: Date, replacingTranscript: Bool = false
    ) {
        switch result.action {
        case .coldStart, .repetitionDetected, .recoveryFailed:
            return

        case .normal, .recoveryReset, .periodicReset:
            break
        }

        if !result.newlyEmittedTokens.isEmpty {
            lastDecodeMelFrame = processedMelFrameCount
            emptyRecoveryResets = 0
            hasProducedFirstToken = true
            postResetSilenceWarned = false
        }

        let postResetSilenceThreshold = 100 * 30
        if !hasProducedFirstToken
            && !postResetSilenceWarned
            && lastFullResetMelFrame > 0
            && processedMelFrameCount - lastFullResetMelFrame > postResetSilenceThreshold {
            Self.logger.error("Post-reset silence: no tokens produced \(String(format: "%.0f", Double(self.processedMelFrameCount - self.lastFullResetMelFrame) / 100.0), privacy: .public)s after inference reset")
            postResetSilenceWarned = true
        }

        if result.action == .recoveryReset && result.newlyEmittedTokens.isEmpty {
            emptyRecoveryResets += 1
            if emptyRecoveryResets >= 2 {
                Self.logger.warning("Escalation: \(self.emptyRecoveryResets, privacy: .public) consecutive empty recovery resets — resetting inference context")
                resetInferenceContext()
                return
            }
        }

        let confirmedRaw = decodeTokens(result.confirmedTokens)
        let parsedConfirmed = TextMergeUtilities.parseASROutput(confirmedRaw)
        let preservingRecoveryBoundary = windowRecovery.activeCheckpoint != nil
        let safeConfirmedText = TextMergeUtilities.stripTrailingReplacementCharacters(
            preservingRecoveryBoundary ? confirmedRaw : parsedConfirmed.text
        )
        let currentChunkIndex = processor.chunkIndex
        let allTokens = result.confirmedTokens + result.provisionalTokens
        let fullRaw = result.provisionalTokens.isEmpty ? confirmedRaw : decodeTokens(allTokens)
        let fullText = TextMergeUtilities.stripTrailingReplacementCharacters(
            preservingRecoveryBoundary ? fullRaw : TextMergeUtilities.parseASROutput(fullRaw).text
        )

        var provisionalText: String
        if result.action == .normal && !result.provisionalTokens.isEmpty {
            if fullText.hasPrefix(safeConfirmedText) {
                provisionalText = String(fullText.dropFirst(safeConfirmedText.count))
            } else {
                let provisionalRaw = decodeTokens(result.provisionalTokens)
                provisionalText = TextMergeUtilities.parseASROutput(provisionalRaw).text
            }
        } else {
            provisionalText = ""
        }

        let newlyEmittedText = Self.consumeConfirmedText(
            safeConfirmedText,
            previousText: &previousConfirmedText,
            finalizationBaseline: &finalizationBaseline,
            isFinal: isFinal,
            action: result.action,
            preserveConfirmedPrefix: preservingRecoveryBoundary
        )
        if result.action == .normal && !provisionalText.isEmpty {
            if fullText.hasPrefix(finalizationBaseline) {
                provisionalText = String(fullText.dropFirst(finalizationBaseline.count))
            } else if finalizationBaseline.hasPrefix(fullText) {
                provisionalText = ""
            }
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

            if replacingTranscript, let replacementText = windowRecovery.render(
                safeConfirmedText
            ) {
                state.mergedCommittedText = TextMergeUtilities.stripTrailingReplacementCharacters(replacementText)
            } else if preservingRecoveryBoundary {
                state.mergedCommittedText += newlyEmittedText
            } else if !newlyEmittedText.isEmpty {
                state.mergedCommittedText = TextMergeUtilities.mergeWithOverlapRemoval(
                    prefix: state.mergedCommittedText, newText: newlyEmittedText)
            } else if state.mergedCommittedText.isEmpty {
                state.mergedCommittedText = safeConfirmedText
            }
            return state.mergedCommittedText
        }
        windowRecovery.record(
            endFrame: processor.endMelFrame, confirmed: displayConfirmed,
            pending: provisionalText
        )
        if result.action == .periodicReset && preservingRecoveryBoundary {
            previousConfirmedText = TextMergeUtilities.stripTrailingReplacementCharacters(
                decodeTokens(processor.allDecodedTokens)
            )
            finalizationBaseline = previousConfirmedText
        }

        continuation?.yield(.displayUpdate(
            confirmedText: displayConfirmed,
            provisionalText: provisionalText
        ))

        let decodeTime = Date().timeIntervalSince(startTime)
        let chunkTimeMs = Int(decodeTime * 1000)
        Self.logger.info("chunk action=\(String(describing: result.action), privacy: .public) newTokens=\(result.newlyEmittedTokens.count, privacy: .public) emptyResets=\(self.emptyRecoveryResets, privacy: .public) chunkTime=\(chunkTimeMs, privacy: .public)ms")
        var stats = StreamingStats(
            encodedWindowCount: processor.encodedWindowCount,
            totalAudioSeconds: Double(totalSamplesFed) / 16000.0,
            tokensPerSecond: decodeTime > 0 ? Double(result.newlyEmittedTokens.count) / decodeTime : 0,
            realTimeFactor: 0,
            peakMemoryGB: Double(Memory.peakMemory) / 1e9,
            chunkElapsedSeconds: decodeTime
        )
        stats.isComplete = !inferenceFailed
        continuation?.yield(.stats(stats))
        if hasProducedFirstToken && processedMelFrameCount - lastDecodeMelFrame > 100 * 20 {
            Self.logger.warning("No-decode watchdog: \(String(format: "%.1f", Double(self.processedMelFrameCount - self.lastDecodeMelFrame) / 100.0), privacy: .public)s without decode output — resetting inference context")
            resetInferenceContext()
        }
    }

    private func suspendInference(frozenText: String) {
        inferenceFailed = true
        chunkProcessor = nil
        chunkMelBuffer = nil
        chunkMelFrameCount = 0
        melProcessor.reset()
        vadSegmenter?.reset()
        previousConfirmedText = ""
        finalizationBaseline = ""
        shared.withLock {
            $0.mergedCommittedText = frozenText
            $0.committedTokenIds = []
        }
        continuation?.yield(.displayUpdate(confirmedText: frozenText, provisionalText: ""))
        var stats = StreamingStats(totalAudioSeconds: Double(totalSamplesFed) / 16000)
        stats.isComplete = false
        continuation?.yield(.stats(stats))
        Self.logger.error("Window recovery failed; inference suspended with incomplete transcript. Recording input must be retained for retranscription.")
    }

    // MARK: - Decoder Helpers

    static func consumeConfirmedText(
        _ confirmedText: String,
        previousText: inout String,
        finalizationBaseline: inout String,
        isFinal: Bool,
        action: ChunkAction,
        preserveConfirmedPrefix: Bool = false
    ) -> String {
        let baseline = isFinal || preserveConfirmedPrefix ? finalizationBaseline : previousText
        let newlyEmittedText: String
        if confirmedText.hasPrefix(baseline) {
            newlyEmittedText = String(confirmedText.dropFirst(baseline.count))
        } else if !confirmedText.isEmpty && !baseline.isEmpty {
            let commonPrefixLength = zip(confirmedText, baseline)
                .prefix(while: { $0 == $1 }).count
            Self.logger.warning("Confirmed text prefix changed at offset \(commonPrefixLength, privacy: .public) — emitting from divergence point")
            newlyEmittedText = String(confirmedText.dropFirst(commonPrefixLength))
        } else {
            newlyEmittedText = confirmedText
        }
        previousText = confirmedText
        if !finalizationBaseline.hasPrefix(confirmedText) {
            finalizationBaseline = confirmedText
        }
        if action == .periodicReset || action == .recoveryReset {
            previousText = ""
            finalizationBaseline = ""
        }
        return newlyEmittedText
    }

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

    private func resetInferenceContext() {
        let acceptedText = windowRecovery.acceptedText
        windowRecovery.reset(confirmedPrefix: acceptedText)
        chunkProcessor = nil
        failedRecoveryMel = nil
        emptyRecoveryResets = 0
        lastDecodeMelFrame = processedMelFrameCount
        lastFullResetMelFrame = processedMelFrameCount
        hasProducedFirstToken = false
        postResetSilenceWarned = false
        previousConfirmedText = ""
        finalizationBaseline = ""
        shared.withLock {
            $0.committedTokenIds = []
            $0.chunkCount = 0
            $0.mergedCommittedText = acceptedText
        }
        continuation?.yield(.displayUpdate(confirmedText: acceptedText, provisionalText: ""))
        Memory.clearCache()
    }

    private func resetProcessingState() {
        melProcessor.reset()
        vadSegmenter?.reset()
        chunkProcessor = nil
        chunkMelBuffer = nil
        chunkMelFrameCount = 0
        failedRecoveryMel = nil
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
            guard continuation != nil && !Task.isCancelled else { return }
            if !inferenceFailed {
                if let flushedMel = melProcessor.flush() {
                    accumulateChunkMel(flushedMel)
                }
                if let remainingMel = chunkMelBuffer {
                    processChunk(melFrames: remainingMel, isFinal: true)
                    chunkMelBuffer = nil
                    chunkMelFrameCount = 0
                } else if let processor = chunkProcessor {
                    emitResult(processor.finalizeAccepted(), processor: processor, isFinal: true, startTime: Date())
                }
            }
            let (finalText, tokenCount) = shared.withLock { ($0.mergedCommittedText, $0.committedTokenIds.count) }
            Self.logger.info("finishStop: text=\(finalText.count)ch tokens=\(tokenCount)")

            continuation?.yield(.ended(fullText: finalText))
            continuation?.finish()

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
