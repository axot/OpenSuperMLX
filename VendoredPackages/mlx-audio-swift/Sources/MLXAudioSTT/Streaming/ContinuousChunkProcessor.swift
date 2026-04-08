// ContinuousChunkProcessor.swift
// MLXAudioSTT

import Foundation
import MLX
import MLXNN
import MLXLMCommon
import os.log
import Tokenizers

private let cpLogger = Logger(subsystem: "MLXAudioSTT", category: "ChunkProcessor")

// MARK: - ChunkProcessingResult

struct ChunkProcessingResult {
    let confirmedTokens: [Int]
    let provisionalTokens: [Int]
    let newlyEmittedTokens: [Int]
    let action: ChunkAction
}

// MARK: - ChunkAction

enum ChunkAction {
    case normal
    case recoveryReset
    case periodicReset
    case coldStart
}

// MARK: - ContinuousChunkProcessor

class ContinuousChunkProcessor {
    private static let eosTokenIds = [151645, 151643]
    private static let asrTextTokenId = 151704

    private let config: StreamingConfig
    private let model: Qwen3ASRModel
    private let tokenizer: any Tokenizer

    private var encoderCache: EncoderWindowCache
    private var accumulatedMel: MLXArray?
    private(set) var accumulatedMelFrameCount: Int = 0
    private(set) var encodedWindowCount: Int = 0

    private var textCommitter: StreamingTextCommitter
    private var degenerationGuard: StreamingDegenerationGuard
    private var decoderCache: [KVCache]?
    private(set) var chunkIndex: Int = 0

    private var prevPrefillEmbeds: MLXArray?
    private(set) var allDecodedTokens: [Int] = []

    init(model: Qwen3ASRModel, tokenizer: any Tokenizer, config: StreamingConfig) {
        self.model = model
        self.tokenizer = tokenizer
        self.config = config
        self.encoderCache = EncoderWindowCache(
            maxWindows: config.maxEncoderWindows,
            windowSizeMelFrames: config.encoderWindowSizeMelFrames
        )
        self.textCommitter = StreamingTextCommitter(
            rollbackTokens: config.rollbackTokens,
            coldStartChunks: config.coldStartChunks
        )
        self.degenerationGuard = StreamingDegenerationGuard(
            maxSingleTokenRun: config.singleTokenRunThreshold,
            blockPatternMaxPeriod: config.blockPatternMaxPeriod,
            blockPatternMinReps: config.blockPatternMinReps,
            stagnationThreshold: config.stagnationChunkThreshold
        )
    }

    // MARK: - Process Chunk

    func processChunk(melFrames: MLXArray, language: String, isFinal: Bool) -> ChunkProcessingResult {
        defer { chunkIndex += 1 }

        accumulateMel(melFrames)
        encodeCompleteWindows()

        guard let audioFeatures = assembleAudioFeatures() else {
            return ChunkProcessingResult(
                confirmedTokens: [], provisionalTokens: [],
                newlyEmittedTokens: [], action: .coldStart
            )
        }

        let inputIds = model.buildPrompt(
            numAudioTokens: audioFeatures.dim(0),
            language: language,
            context: "",
            prefix: ""
        )
        let embeds = model.model.embedTokens(inputIds)
        var inputsEmbeds = model.mergeAudioFeatures(
            inputsEmbeds: embeds,
            audioFeatures: audioFeatures.asType(embeds.dtype),
            inputIds: inputIds
        )

        let prefixTokenIds = buildPrefixTokenIds()
        if !prefixTokenIds.isEmpty {
            let prefixMLX = MLXArray(prefixTokenIds.map { Int32($0) }).expandedDimensions(axis: 0)
            let prefixEmbeds = model.model.embedTokens(prefixMLX)
            inputsEmbeds = MLX.concatenated([inputsEmbeds, prefixEmbeds], axis: 1)
        }

        eval(inputsEmbeds)

        let logits = prefillWithEmbeddingDiff(inputsEmbeds, inputIds: inputIds)
        let (rawNewTokenIds, hitMaxTokens) = decodeTokens(initialLogits: logits)

        let newTokenIds = Self.filterTextTokens(rawNewTokenIds)

        let prefixTokensFull = allDecodedTokens
        let guardAction = degenerationGuard.evaluateChunk(
            prefixTokens: prefixTokensFull,
            newChunkTokens: newTokenIds,
            stableTokenCount: textCommitter.stableTokens.count,
            hitMaxTokens: hitMaxTokens,
            isFinal: isFinal
        )

        switch guardAction {
        case .recoveryReset:
            let stable = textCommitter.stableTokens
            cpLogger.warning("chunk[\(self.chunkIndex)] RECOVERY RESET stableTokens=\(stable.count)")
            reset(keepEmittedTokens: true)
            return ChunkProcessingResult(
                confirmedTokens: stable, provisionalTokens: [],
                newlyEmittedTokens: [], action: .recoveryReset
            )

        case .ok(let filteredNewTokens):
            if config.pastTextConditioning {
                let rollback = min(config.rollbackTokens, prefixTokensFull.count)
                let stablePrefix = Array(prefixTokensFull.dropLast(rollback))
                allDecodedTokens = stablePrefix + filteredNewTokens
            } else {
                allDecodedTokens = filteredNewTokens
            }

            let commitResult = textCommitter.processChunkTokens(allDecodedTokens, isFinal: isFinal)

            if !isFinal
                && config.pastTextConditioning
                && chunkIndex >= config.coldStartChunks
                && (chunkIndex + 1) % config.resetIntervalChunks == 0
            {
                cpLogger.info("chunk[\(self.chunkIndex)] PERIODIC RESET")
                reset(keepEmittedTokens: true)
                return ChunkProcessingResult(
                    confirmedTokens: commitResult.confirmedTokens,
                    provisionalTokens: [],
                    newlyEmittedTokens: commitResult.newlyEmittedTokens,
                    action: .periodicReset
                )
            }

            return ChunkProcessingResult(
                confirmedTokens: commitResult.confirmedTokens,
                provisionalTokens: commitResult.provisionalTokens,
                newlyEmittedTokens: commitResult.newlyEmittedTokens,
                action: .normal
            )
        }
    }

    // MARK: - Reset

    func reset(keepEmittedTokens: Bool) {
        if keepEmittedTokens {
            textCommitter.reanchor(
                from: textCommitter.emittedTokens,
                keepLast: config.resetCarryTokens
            )
            allDecodedTokens = Array(textCommitter.emittedTokens.suffix(config.resetCarryTokens))
            let langLower = config.language.trimmingCharacters(in: .whitespaces).lowercased()
            if langLower.isEmpty || langLower == "auto" {
                allDecodedTokens.insert(Self.asrTextTokenId, at: 0)
            }

            let windowSize = config.encoderWindowSizeMelFrames
            let fullEnd = encodedWindowCount * windowSize
            if fullEnd > 0 && fullEnd < accumulatedMelFrameCount {
                let tail = accumulatedMel![fullEnd..<accumulatedMelFrameCount]
                eval(tail)
                accumulatedMel = tail
                accumulatedMelFrameCount = tail.dim(0)
            } else if fullEnd >= accumulatedMelFrameCount {
                accumulatedMel = nil
                accumulatedMelFrameCount = 0
            }
        } else {
            textCommitter = StreamingTextCommitter(
                rollbackTokens: config.rollbackTokens,
                coldStartChunks: config.coldStartChunks
            )
            allDecodedTokens = []
            accumulatedMel = nil
            accumulatedMelFrameCount = 0
            chunkIndex = 0
        }

        encoderCache.clear()
        encodedWindowCount = 0
        decoderCache = nil
        prevPrefillEmbeds = nil
        degenerationGuard.resetStagnation()
        Memory.clearCache()
    }

    // MARK: - Mel Accumulation

    private func accumulateMel(_ melFrames: MLXArray) {
        if let existing = accumulatedMel {
            accumulatedMel = MLX.concatenated([existing, melFrames], axis: 0)
        } else {
            accumulatedMel = melFrames
        }
        accumulatedMelFrameCount = accumulatedMel!.dim(0)
    }

    // MARK: - Encoder Window Management

    private func encodeCompleteWindows() {
        let windowSize = config.encoderWindowSizeMelFrames
        let totalComplete = Self.computeCompleteWindowCount(
            totalMelFrames: accumulatedMelFrameCount, windowSize: windowSize
        )

        while encodedWindowCount < totalComplete {
            let windowStart = encodedWindowCount * windowSize
            let windowEnd = windowStart + windowSize
            let windowMel = accumulatedMel![windowStart..<windowEnd]

            let encoderOutput = model.audioTower.encodeSingleWindow(windowMel)
            eval(encoderOutput)

            encoderCache.addWindow(CachedWindow(
                encoderOutput: encoderOutput,
                seqLen: encoderOutput.dim(0),
                startMelFrame: windowStart
            ))
            encodedWindowCount += 1
            Memory.clearCache()
        }
    }

    // MARK: - Audio Feature Assembly

    private func assembleAudioFeatures() -> MLXArray? {
        let windowSize = config.encoderWindowSizeMelFrames
        let tailStart = encodedWindowCount * windowSize

        if tailStart < accumulatedMelFrameCount {
            let tailMel = accumulatedMel![tailStart..<accumulatedMelFrameCount]
            let tailOutput = model.audioTower.encodeSingleWindow(tailMel)
            eval(tailOutput)

            if let cachedOutput = encoderCache.concatenatedOutput() {
                return MLX.concatenated([cachedOutput, tailOutput], axis: 0)
            }
            return tailOutput
        }

        return encoderCache.concatenatedOutput()
    }

    // MARK: - Prefix Token Conditioning

    private func buildPrefixTokenIds() -> [Int] {
        guard config.pastTextConditioning else { return [] }

        let range = Self.computePrefixTokenRange(
            totalTokens: allDecodedTokens.count,
            maxPrefix: config.maxPrefixTokens,
            rollback: config.rollbackTokens
        )
        guard !range.isEmpty else { return [] }

        return Array(allDecodedTokens[range])
    }

    // MARK: - KV Cache Reuse via Embedding Diff

    private func prefillWithEmbeddingDiff(
        _ inputsEmbeds: MLXArray, inputIds: MLXArray
    ) -> MLXArray {
        var matchedRows = Self.findEmbeddingPrefixMatch(
            current: inputsEmbeds, previous: prevPrefillEmbeds
        )

        let seqLen = inputsEmbeds.dim(1)
        matchedRows = min(matchedRows, seqLen - 1)

        let logits: MLXArray

        if matchedRows > 0, let cache = decoderCache {
            let trimAmount = cache[0].offset - matchedRows
            if trimAmount > 0 {
                for c in cache {
                    c.trim(trimAmount)
                }
            }

            let newEmbeds = inputsEmbeds[0..., matchedRows..<seqLen, 0...]
            logits = model.callAsFunction(
                inputIds: inputIds,
                inputEmbeddings: newEmbeds,
                cache: decoderCache
            )
        } else {
            decoderCache = model.makeCache()
            logits = model.callAsFunction(
                inputIds: inputIds,
                inputEmbeddings: inputsEmbeds,
                cache: decoderCache
            )
        }

        eval(logits)
        Memory.clearCache()
        prevPrefillEmbeds = inputsEmbeds
        return logits
    }

    // MARK: - Token Decoding

    private func decodeTokens(initialLogits: MLXArray) -> (tokens: [Int], hitMaxTokens: Bool) {
        var logits = initialLogits
        var newTokenIds: [Int] = []
        let maxTokens = config.maxNewTokensPerChunk

        for _ in 0..<maxTokens {
            let lastLogits = logits[0..., -1, 0...]
            let nextToken = lastLogits.argMax(axis: -1).item(Int.self)

            if Self.eosTokenIds.contains(nextToken) { break }

            newTokenIds.append(nextToken)

            let nextTokenArray = MLXArray([Int32(nextToken)]).expandedDimensions(axis: 0)
            logits = model.callAsFunction(inputIds: nextTokenArray, cache: decoderCache)
            eval(logits)
        }

        Memory.clearCache()
        return (newTokenIds, newTokenIds.count >= maxTokens)
    }

    // MARK: - Static Helpers (Testable)

    static func findEmbeddingPrefixMatch(current: MLXArray, previous: MLXArray?) -> Int {
        guard let previous = previous else { return 0 }

        let currentSeqLen = current.dim(1)
        let previousSeqLen = previous.dim(1)
        let minLen = min(currentSeqLen, previousSeqLen)
        guard minLen > 0 else { return 0 }

        let currentSlice = current[0, 0..<minLen]
        let previousSlice = previous[0, 0..<minLen]

        let rowMatch = (currentSlice .== previousSlice).all(axis: -1)
        eval(rowMatch)

        let matches = rowMatch.asArray(Bool.self)
        for (i, m) in matches.enumerated() {
            if !m { return i }
        }
        return minLen
    }

    static func computePrefixTokenRange(
        totalTokens: Int, maxPrefix: Int, rollback: Int
    ) -> Range<Int> {
        let end = max(0, totalTokens - rollback)
        let start = max(0, end - maxPrefix)
        return start..<end
    }

    static func computeCompleteWindowCount(totalMelFrames: Int, windowSize: Int) -> Int {
        guard windowSize > 0 else { return 0 }
        return totalMelFrames / windowSize
    }

    static func filterTextTokens(_ tokens: [Int]) -> [Int] {
        guard let markerIndex = tokens.firstIndex(of: asrTextTokenId) else {
            return tokens
        }
        return Array(tokens.suffix(from: markerIndex + 1))
    }
}
