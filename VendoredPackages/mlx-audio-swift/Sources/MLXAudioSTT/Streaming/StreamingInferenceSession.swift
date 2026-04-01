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
            guard isActive else { return }
            totalSamplesFed += samples.count

            _ = vadSegmenter.feedSamples(samples)
            if let newMelFrames = melProcessor.process(samples: samples) {
                accumulateChunkMel(newMelFrames)
                processAccumulatedChunks()
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

        case .normal:
            let confirmedRaw = tokenizer.decode(tokens: result.confirmedTokens)
            let provisionalRaw = tokenizer.decode(tokens: result.provisionalTokens)
            let parsedConfirmed = TextMergeUtilities.parseASROutput(confirmedRaw)
            let parsedProvisional = TextMergeUtilities.parseASROutput(provisionalRaw)
            let currentChunkIndex = processor.chunkIndex

            shared.withLock { state in
                state.committedTokenIds = result.confirmedTokens
                state.chunkCount = currentChunkIndex
                if state.detectedLanguage.isEmpty && parsedConfirmed.language != "unknown" {
                    state.detectedLanguage = parsedConfirmed.language
                }
                state.mergedCommittedText = parsedConfirmed.text
            }

            continuation?.yield(.displayUpdate(
                confirmedText: parsedConfirmed.text,
                provisionalText: parsedProvisional.text
            ))

        case .recoveryReset, .periodicReset:
            let confirmedRaw = tokenizer.decode(tokens: result.confirmedTokens)
            let parsedConfirmed = TextMergeUtilities.parseASROutput(confirmedRaw)
            let currentChunkIndex = processor.chunkIndex

            shared.withLock { state in
                state.committedTokenIds = result.confirmedTokens
                state.chunkCount = currentChunkIndex
                state.mergedCommittedText = parsedConfirmed.text
            }

            continuation?.yield(.displayUpdate(
                confirmedText: parsedConfirmed.text,
                provisionalText: ""
            ))
        }

        let decodeTime = Date().timeIntervalSince(startTime)
        continuation?.yield(.stats(StreamingStats(
            encodedWindowCount: processor.encodedWindowCount,
            totalAudioSeconds: Double(totalSamplesFed) / 16000.0,
            tokensPerSecond: decodeTime > 0 ? Double(result.newlyEmittedTokens.count) / decodeTime : 0,
            realTimeFactor: 0,
            peakMemoryGB: Double(Memory.peakMemory) / 1e9
        )))
    }

    // MARK: - Decoder Helpers

    static func resolveEffectiveLanguage(configLanguage: String, detectedLanguage: String) -> String {
        let configLang = configLanguage.trimmingCharacters(in: .whitespaces).lowercased()
        if !configLang.isEmpty && configLang != "auto" {
            return configLanguage
        }
        return detectedLanguage.isEmpty ? configLanguage : detectedLanguage
    }

    private var effectiveLanguage: String {
        let detected = shared.withLock { $0.detectedLanguage }
        return StreamingInferenceSession.resolveEffectiveLanguage(
            configLanguage: config.language,
            detectedLanguage: detected
        )
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

        let finalText = shared.withLock { $0.mergedCommittedText }
        Self.logger.info("finishStop: text=\(finalText.count)ch tokens=\(self.shared.withLock { $0.committedTokenIds.count })")

        continuation?.yield(.ended(fullText: finalText))
        continuation?.finish()

        sessionLock.withLock { _ in
            self.continuation = nil
            stopTask = nil
            melProcessor.reset()
            vadSegmenter.reset()
            chunkProcessor = nil
            chunkMelBuffer = nil
            chunkMelFrameCount = 0
        }

        shared.withLock {
            $0.committedTokenIds = []
            $0.chunkCount = 0
            $0.mergedCommittedText = ""
        }
        Memory.clearCache()
    }

    // MARK: - Cancel

    public func cancel() {
        sessionLock.withLock { _ in
            isActive = false
            stopTask?.cancel()
            stopTask = nil
            continuation?.finish()
            continuation = nil
            melProcessor.reset()
            vadSegmenter.reset()
            chunkProcessor = nil
            chunkMelBuffer = nil
            chunkMelFrameCount = 0
        }
        shared.withLock {
            $0.committedTokenIds = []
            $0.chunkCount = 0
            $0.mergedCommittedText = ""
        }
        Memory.clearCache()
    }
}
