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
    var rawDecodedTokenIds: [Int] = []
    var isDecoding: Bool = false
}

/// Orchestrates streaming speech-to-text inference using prefix-rollback.
///
/// Each decode pass re-decodes the full encoder output, keeping a prefix of
/// previously decoded tokens as context and rolling back only the trailing
/// `unfixedTokenNum` tokens. This eliminates overlap/dedup logic entirely.
public class StreamingInferenceSession: @unchecked Sendable {
    private static let eosTokenIds = [151645, 151643]
    private static let repetitionThreshold = 8

    private let model: Qwen3ASRModel
    private let config: StreamingConfig
    private let melProcessor: IncrementalMelSpectrogram
    private let encoder: StreamingEncoder

    private let shared = OSAllocatedUnfairLock(initialState: SessionState())
    private let sessionLock = OSAllocatedUnfairLock(initialState: 0)

    private var isActive: Bool = false
    private var totalSamplesFed: Int = 0
    private var lastDecodeTime: Date?
    private var hasNewEncoderContent: Bool = false

    private var continuation: AsyncStream<TranscriptionEvent>.Continuation?
    private var decodeTask: Task<Void, Never>?
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
        // CRITICAL: overlapFrames: 0 — no overlap for full-session decode
        self.encoder = StreamingEncoder(
            encoder: model.audioTower,
            maxCachedWindows: config.maxCachedWindows,
            overlapFrames: 0
        )

        var continuation: AsyncStream<TranscriptionEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.continuation = continuation
        self.isActive = true
    }

    // MARK: - Audio Input

    public func feedAudio(samples: [Float]) {
        sessionLock.withLock { _ in
            guard isActive else { return }

            totalSamplesFed += samples.count

            guard let melFrames = melProcessor.process(samples: samples) else { return }

            let newWindows = encoder.feed(melFrames: melFrames)
            if newWindows > 0 || encoder.hasPendingFrames {
                hasNewEncoderContent = true
            }

            let now = Date()
            let shouldDecode: Bool
            if let lastDecode = lastDecodeTime {
                shouldDecode = now.timeIntervalSince(lastDecode) >= config.decodeIntervalSeconds
            } else {
                shouldDecode = hasNewEncoderContent
            }

            if shouldDecode && hasNewEncoderContent {
                let canDecode = shared.withLock { state in
                    guard !state.isDecoding else { return false }
                    state.isDecoding = true
                    return true
                }

                if canDecode {
                    hasNewEncoderContent = false
                    lastDecodeTime = now
                    launchDecodePassLocked()
                }
            }
        }
    }

    // MARK: - Decode Pass

    private func launchDecodePassLocked() {
        let startWindow = config.decodeWindowCount > 0
            ? max(0, encoder.cachedWindowCount - config.decodeWindowCount)
            : nil
        guard let audioFeatures = encoder.getFullEncoderOutput(fromWindow: startWindow) else {
            shared.withLock { $0.isDecoding = false }
            return
        }

        let snapshot = shared.withLock { $0.rawDecodedTokenIds }
        let boxedFeatures = UncheckedSendableBox(audioFeatures)
        let boxedModel = UncheckedSendableBox(self.model)
        let config = self.config
        let continuation = self.continuation
        let sharedState = self.shared
        let totalSamples = totalSamplesFed
        let encodedWindowCount = encoder.encodedWindowCount

        decodeTask = Task.detached {
            defer { sharedState.withLock { $0.isDecoding = false } }
            Self.runDecodePass(
                audioFeatures: boxedFeatures.value,
                model: boxedModel.value,
                config: config,
                rawDecodedTokenIds: snapshot,
                continuation: continuation,
                sharedState: sharedState,
                totalSamples: totalSamples,
                encodedWindowCount: encodedWindowCount
            )
        }
    }

    private static func runDecodePass(
        audioFeatures: MLXArray,
        model: Qwen3ASRModel,
        config: StreamingConfig,
        rawDecodedTokenIds: [Int],
        continuation: AsyncStream<TranscriptionEvent>.Continuation?,
        sharedState: OSAllocatedUnfairLock<SessionState>,
        totalSamples: Int,
        encodedWindowCount: Int
    ) {
        if Task.isCancelled { return }
        guard let tokenizer = model.tokenizer else { return }

        let numAudioTokens = audioFeatures.dim(0)
        guard numAudioTokens > 0 else { return }

        let startTime = Date()

        // 1. Prefix rollback
        let endIdx = computePrefixEndIndex(
            tokenCount: rawDecodedTokenIds.count,
            unfixedTokenNum: config.unfixedTokenNum
        )
        let (prefixIds, prefixText) = Self.safeDecodePrefix(
            ids: Array(rawDecodedTokenIds.prefix(endIdx)),
            tokenizer: tokenizer
        )

        // 2. Build prompt with full audio + prefix
        let inputIds = model.buildPrompt(
            numAudioTokens: numAudioTokens,
            language: config.language,
            prefix: prefixText
        )

        // 3. Prefill
        let embeds = model.model.embedTokens(inputIds)
        let inputsEmbeds = model.mergeAudioFeatures(
            inputsEmbeds: embeds,
            audioFeatures: audioFeatures.asType(embeds.dtype),
            inputIds: inputIds
        )

        let cache = model.makeCache()
        var logits = model.callAsFunction(
            inputIds: inputIds,
            inputEmbeddings: inputsEmbeds,
            cache: cache
        )
        eval(logits)

        if Task.isCancelled { return }

        // 4. Autoregressive generation
        var newTokenIds: [Int] = []
        var recentTokenIds: [Int] = Array(prefixIds.suffix(config.repetitionContextSize))
        for _ in 0..<config.maxTokensPerPass {
            if Task.isCancelled { return }

            var lastLogits = logits[0..., -1, 0...]
            if config.temperature > 0 {
                lastLogits = lastLogits / config.temperature
            }

            // Repetition penalty (B): suppress recently-seen tokens in logits
            if config.repetitionPenalty > 1.0 && !recentTokenIds.isEmpty {
                let indices = MLXArray(recentTokenIds.map { UInt32($0) })
                var selected = lastLogits[0..., indices]
                selected = MLX.where(selected .< 0, selected * config.repetitionPenalty, selected / config.repetitionPenalty)
                lastLogits[0..., indices] = selected
            }

            let nextToken = lastLogits.argMax(axis: -1).item(Int.self)
            if eosTokenIds.contains(nextToken) { break }
            newTokenIds.append(nextToken)

            recentTokenIds.append(nextToken)
            if recentTokenIds.count > config.repetitionContextSize {
                recentTokenIds.removeFirst()
            }

            // Repetition guard safety net (C): stop if last N tokens are identical
            if newTokenIds.count >= repetitionThreshold &&
               newTokenIds.suffix(repetitionThreshold).allSatisfy({ $0 == nextToken }) {
                newTokenIds.removeLast(repetitionThreshold)
                break
            }

            let provText = tokenizer.decode(tokens: newTokenIds)
            continuation?.yield(.displayUpdate(
                confirmedText: prefixText,
                provisionalText: provText
            ))

            let nextTokenArray = MLXArray([Int32(nextToken)]).expandedDimensions(axis: 0)
            logits = model.callAsFunction(inputIds: nextTokenArray, cache: cache)
            eval(logits)
        }

        if Task.isCancelled { return }
        Memory.clearCache()

        // 5. Update shared state
        let finalIds = prefixIds + newTokenIds
        sharedState.withLock { state in
            state.rawDecodedTokenIds = finalIds
        }

        let provisionalText = tokenizer.decode(tokens: newTokenIds)
        continuation?.yield(.displayUpdate(
            confirmedText: prefixText,
            provisionalText: provisionalText
        ))

        let decodeTime = Date().timeIntervalSince(startTime)
        let tps = decodeTime > 0 ? Double(finalIds.count) / decodeTime : 0
        continuation?.yield(.stats(StreamingStats(
            encodedWindowCount: encodedWindowCount,
            totalAudioSeconds: Double(totalSamples) / 16000.0,
            tokensPerSecond: tps,
            realTimeFactor: 0,
            peakMemoryGB: Double(Memory.peakMemory) / 1e9
        )))
    }

    // MARK: - Prefix Rollback

    /// Compute the end index of the prefix to keep fixed across decode passes.
    /// Tokens beyond this index are "unfixed" and will be re-decoded.
    public static func computePrefixEndIndex(tokenCount: Int, unfixedTokenNum: Int) -> Int {
        return max(0, tokenCount - unfixedTokenNum)
    }

    private static let unicodeReplacementCharacter: Character = "\u{FFFD}"

    /// Decode a prefix token array, backing off one token at a time if the result
    /// contains U+FFFD replacement characters. This handles byte-level BPE tokenizers
    /// where cutting at a token boundary may split a multi-byte UTF-8 character (e.g.
    /// Japanese kanji), which would permanently corrupt the re-encoded prompt.
    static func safeDecodePrefix(ids: [Int], decode: ([Int]) -> String) -> (ids: [Int], text: String) {
        var safeIds = ids
        while !safeIds.isEmpty {
            let text = decode(safeIds)
            if !text.contains(unicodeReplacementCharacter) {
                return (safeIds, text)
            }
            safeIds = Array(safeIds.dropLast())
        }
        return ([], "")
    }

    static func safeDecodePrefix(ids: [Int], tokenizer: any Tokenizer) -> (ids: [Int], text: String) {
        safeDecodePrefix(ids: ids) { tokenizer.decode(tokens: $0) }
    }

    // MARK: - Stop

    public func stop() {
        sessionLock.withLock { _ in
            guard isActive else { return }
            isActive = false

            let inFlightDecode = decodeTask
            decodeTask = nil

            stopTask?.cancel()
            stopTask = Task.detached { [self] in
                await finishStop(waitingFor: inFlightDecode)
            }
        }
    }

    private func finishStop(waitingFor inFlightDecode: Task<Void, Never>?) async {
        if let inFlightDecode {
            _ = await inFlightDecode.value
        }

        if Task.isCancelled { return }

        // Flush remaining audio
        let (boxedFeatures, continuation) = sessionLock.withLock {
            _ -> (UncheckedSendableBox<MLXArray>?, AsyncStream<TranscriptionEvent>.Continuation?) in
            if let melFrames = melProcessor.flush() {
                _ = encoder.feed(melFrames: melFrames)
            }
            _ = encoder.flushPartial()
            let startWindow = config.decodeWindowCount > 0
                ? max(0, encoder.cachedWindowCount - config.decodeWindowCount)
                : nil
            let features = encoder.getFullEncoderOutput(fromWindow: startWindow)
            let boxed = features.map { UncheckedSendableBox($0) }
            return (boxed, self.continuation)
        }
        let audioFeatures = boxedFeatures?.value

        if Task.isCancelled { return }

        let finalText: String
        if let audioFeatures, audioFeatures.dim(0) > 0, let tokenizer = model.tokenizer {
            // Run one final prefix-rollback decode pass
            let snapshot = shared.withLock { $0.rawDecodedTokenIds }

            let prefixEndIdx = Self.computePrefixEndIndex(
                tokenCount: snapshot.count,
                unfixedTokenNum: config.unfixedTokenNum
            )
            let (prefixIds, prefixText) = Self.safeDecodePrefix(
                ids: Array(snapshot.prefix(prefixEndIdx)),
                tokenizer: tokenizer
            )

            let numAudioTokens = audioFeatures.dim(0)
            let inputIds = model.buildPrompt(
                numAudioTokens: numAudioTokens,
                language: config.language,
                prefix: prefixText
            )

            let embeds = model.model.embedTokens(inputIds)
            let inputsEmbeds = model.mergeAudioFeatures(
                inputsEmbeds: embeds,
                audioFeatures: audioFeatures.asType(embeds.dtype),
                inputIds: inputIds
            )

            let cache = model.makeCache()
            var logits = model.callAsFunction(
                inputIds: inputIds,
                inputEmbeddings: inputsEmbeds,
                cache: cache
            )
            eval(logits)

            if Task.isCancelled { return }

            var newTokenIds: [Int] = []
            var recentTokenIds: [Int] = Array(prefixIds.suffix(config.repetitionContextSize))
            for _ in 0..<config.maxTokensPerPass {
                if Task.isCancelled { return }

                var lastLogits = logits[0..., -1, 0...]
                if config.temperature > 0 {
                    lastLogits = lastLogits / config.temperature
                }

                // Repetition penalty (B)
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

                // Repetition guard safety net (C)
                if newTokenIds.count >= Self.repetitionThreshold &&
                   newTokenIds.suffix(Self.repetitionThreshold).allSatisfy({ $0 == nextToken }) {
                    newTokenIds.removeLast(Self.repetitionThreshold)
                    break
                }

                let nextTokenArray = MLXArray([Int32(nextToken)]).expandedDimensions(axis: 0)
                logits = model.callAsFunction(inputIds: nextTokenArray, cache: cache)
                eval(logits)
            }

            let finalIds = prefixIds + newTokenIds
            shared.withLock { state in
                state.rawDecodedTokenIds = finalIds
            }
            finalText = tokenizer.decode(tokens: finalIds)

            Memory.clearCache()
        } else {
            // No audio features — use whatever we accumulated
            finalText = shared.withLock { state in
                guard let tokenizer = model.tokenizer, !state.rawDecodedTokenIds.isEmpty else { return "" }
                return tokenizer.decode(tokens: state.rawDecodedTokenIds)
            }
        }

        if Task.isCancelled { return }

        continuation?.yield(.ended(fullText: finalText))
        continuation?.finish()

        sessionLock.withLock { _ in
            self.continuation = nil
            stopTask = nil
            encoder.reset()
            melProcessor.reset()
        }

        Memory.clearCache()
    }

    // MARK: - Cancel

    public func cancel() {
        sessionLock.withLock { _ in
            isActive = false
            decodeTask?.cancel()
            decodeTask = nil
            stopTask?.cancel()
            stopTask = nil
            continuation?.finish()
            continuation = nil
            encoder.reset()
            melProcessor.reset()
        }
    }

}
