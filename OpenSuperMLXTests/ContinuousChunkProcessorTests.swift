// ContinuousChunkProcessorTests.swift
// OpenSuperMLXTests

import XCTest

import MLX
import Tokenizers
@testable import MLXAudioSTT

final class ContinuousChunkProcessorTests: XCTestCase {

    // MARK: - Embedding Prefix Match

    func testEmbeddingPrefixMatchIdenticalArrays() {
        let arr = MLXArray.ones([1, 10, 4])
        eval(arr)
        let match = ContinuousChunkProcessor.findEmbeddingPrefixMatch(current: arr, previous: arr)
        XCTAssertEqual(match, 10)
    }

    func testEmbeddingPrefixMatchNoPrevious() {
        let arr = MLXArray.ones([1, 10, 4])
        let match = ContinuousChunkProcessor.findEmbeddingPrefixMatch(current: arr, previous: nil)
        XCTAssertEqual(match, 0)
    }

    func testEmbeddingPrefixMatchPartialMatch() {
        let data1 = [Float](repeating: 1.0, count: 10 * 4)
        var data2 = [Float](repeating: 1.0, count: 10 * 4)
        for j in 0..<4 {
            data2[5 * 4 + j] = 99.0
        }
        let arr1 = MLXArray(data1).reshaped(1, 10, 4)
        let arr2 = MLXArray(data2).reshaped(1, 10, 4)
        eval(arr1, arr2)

        let match = ContinuousChunkProcessor.findEmbeddingPrefixMatch(current: arr1, previous: arr2)
        XCTAssertEqual(match, 5)
    }

    func testEmbeddingPrefixMatchDifferentLengths() {
        let short = MLXArray.ones([1, 5, 4])
        let long = MLXArray.ones([1, 10, 4])
        eval(short, long)

        let match = ContinuousChunkProcessor.findEmbeddingPrefixMatch(current: long, previous: short)
        XCTAssertEqual(match, 5)
    }

    // MARK: - Prefix Token Range

    func testPrefixTokenRangeNormal() {
        let range = ContinuousChunkProcessor.computePrefixTokenRange(
            totalTokens: 200, maxPrefix: 150, rollback: 5
        )
        XCTAssertEqual(range, 45..<195)
    }

    func testPrefixTokenRangeFewTokens() {
        let range = ContinuousChunkProcessor.computePrefixTokenRange(
            totalTokens: 10, maxPrefix: 150, rollback: 5
        )
        XCTAssertEqual(range, 0..<5)
    }

    func testPrefixTokenRangeEmpty() {
        let range = ContinuousChunkProcessor.computePrefixTokenRange(
            totalTokens: 0, maxPrefix: 150, rollback: 5
        )
        XCTAssertTrue(range.isEmpty)
    }

    // MARK: - Window Count

    func testCompleteWindowCount() {
        XCTAssertEqual(
            ContinuousChunkProcessor.computeCompleteWindowCount(totalMelFrames: 800, windowSize: 800), 1
        )
        XCTAssertEqual(
            ContinuousChunkProcessor.computeCompleteWindowCount(totalMelFrames: 799, windowSize: 800), 0
        )
        XCTAssertEqual(
            ContinuousChunkProcessor.computeCompleteWindowCount(totalMelFrames: 1600, windowSize: 800), 2
        )
        XCTAssertEqual(
            ContinuousChunkProcessor.computeCompleteWindowCount(totalMelFrames: 0, windowSize: 800), 0
        )
        XCTAssertEqual(
            ContinuousChunkProcessor.computeCompleteWindowCount(totalMelFrames: 100, windowSize: 0), 0
        )
    }

    // MARK: - Filter Text Tokens

    func testFilterTextTokensNoMarker() {
        let tokens = [100, 200, 300]
        XCTAssertEqual(ContinuousChunkProcessor.filterTextTokens(tokens), [100, 200, 300])
    }

    func testFilterTextTokensMarkerAtStart() {
        let tokens = [151704, 100, 200]
        XCTAssertEqual(ContinuousChunkProcessor.filterTextTokens(tokens), [100, 200])
    }

    func testFilterTextTokensMarkerInMiddle() {
        let tokens = [50, 60, 151704, 100, 200]
        XCTAssertEqual(ContinuousChunkProcessor.filterTextTokens(tokens), [100, 200])
    }

    func testFilterTextTokensMarkerAtEnd() {
        let tokens = [100, 200, 151704]
        XCTAssertEqual(ContinuousChunkProcessor.filterTextTokens(tokens), [])
    }

    func testFilterTextTokensMultipleMarkers() {
        let tokens = [151704, 100, 151704, 200]
        XCTAssertEqual(ContinuousChunkProcessor.filterTextTokens(tokens), [100, 151704, 200])
    }

    func testFilterTextTokensEmpty() {
        XCTAssertEqual(ContinuousChunkProcessor.filterTextTokens([]), [])
    }

    // MARK: - StreamingConfig Defaults

    func testStreamingConfigPastTextConditioningDefaultOn() {
        let config = StreamingConfig()
        XCTAssertTrue(config.pastTextConditioning,
                      "pastTextConditioning should default to true (matching C --stream behavior)")
    }

    func testStreamingConfigDefaultValues() {
        let config = StreamingConfig()
        XCTAssertEqual(config.maxEncoderWindows, 4)
        XCTAssertEqual(config.encoderWindowSizeMelFrames, 800)
        XCTAssertEqual(config.resetIntervalChunks, 45)
        XCTAssertEqual(config.resetCarryTokens, 24)
        XCTAssertEqual(config.rollbackTokens, 5)
        XCTAssertEqual(config.coldStartChunks, 2)
        XCTAssertEqual(config.maxNewTokensPerChunk, 32)
    }
}

// MARK: - Final Decode

final class ContinuousChunkProcessorFinalizationTests: XCTestCase {
    func testFinalDecodeRevisesTailWithoutDuplicatingIt() {
        for newTokens in [Array(6...10), [6, 7, 80, 90, 100, 110]] {
            assertFinalDecode(
                acceptedTokens: Array(1...10),
                newTokens: newTokens,
                expectedTokens: Array(1...5) + newTokens,
                expectedDelta: newTokens
            )
        }
    }

    func testEOSOnlyFinalDecodePreservesAcceptedTail() {
        for newTokens in [[], [151704]] {
            assertFinalDecode(
                acceptedTokens: Array(1...10),
                newTokens: newTokens,
                expectedTokens: Array(1...10),
                expectedDelta: Array(6...10)
            )
        }
    }

    func testShorterFinalRevisionReplacesEntireProvisionalTail() {
        assertFinalDecode(
            acceptedTokens: Array(1...10),
            newTokens: [60, 70],
            expectedTokens: [1, 2, 3, 4, 5, 60, 70],
            expectedDelta: [60, 70]
        )
    }

    func testRejectedFinalDecodeCommitsPreviouslyAcceptedTail() {
        for rejectedTokens in [
            Array(repeating: 42, count: 20),
            [21, 22, 21, 22, 21, 22, 21, 22],
        ] {
            assertFinalDecode(
                acceptedTokens: Array(1...10),
                newTokens: rejectedTokens,
                expectedTokens: Array(1...10),
                expectedDelta: Array(6...10),
                expectedGuardAction: .recoveryReset
            )
        }
    }

    func testEOSOnlyFinalDecodePreservesShortAndColdStartCandidates() {
        for count in 0...5 {
            let acceptedTokens = Array(0..<count)
            for coldStartChunks in [0, 2] {
                assertFinalDecode(
                    acceptedTokens: acceptedTokens,
                    newTokens: [],
                    expectedTokens: acceptedTokens,
                    expectedDelta: acceptedTokens,
                    coldStartChunks: coldStartChunks
                )
            }
        }
    }

    func testShortCandidateCanStillBeRevisedAtStop() {
        assertFinalDecode(
            acceptedTokens: [1, 2, 3],
            newTokens: [60],
            expectedTokens: [60],
            expectedDelta: [60]
        )
    }

    func testFinalDecodeWithoutConditioningPreservesFallbackAndAllowsRevision() {
        for newTokens in [[], [60, 70]] {
            let expectedTokens = newTokens.isEmpty ? [1, 2, 3] : newTokens
            assertFinalDecode(
                acceptedTokens: [1, 2, 3],
                newTokens: newTokens,
                expectedTokens: expectedTokens,
                expectedDelta: expectedTokens,
                pastTextConditioning: false
            )
        }
    }

    func testEOSOnlyFinalDecodeDoesNotEmitConfirmedTokensAgain() {
        assertFinalDecode(
            acceptedTokens: Array(1...10),
            newTokens: [],
            expectedTokens: Array(1...10),
            expectedDelta: [],
            rollbackTokens: 0
        )
    }

    // MARK: - Helpers

    private func assertFinalDecode(
        acceptedTokens: [Int],
        newTokens: [Int],
        expectedTokens: [Int],
        expectedDelta: [Int],
        expectedGuardAction: GuardAction? = nil,
        rollbackTokens: Int = 5,
        coldStartChunks: Int = 0,
        pastTextConditioning: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var config = StreamingConfig()
        config.rollbackTokens = rollbackTokens
        config.coldStartChunks = coldStartChunks
        config.pastTextConditioning = pastTextConditioning
        var history = acceptedTokens
        var committer = StreamingTextCommitter(
            rollbackTokens: rollbackTokens, coldStartChunks: coldStartChunks
        )
        _ = committer.processChunkTokens(acceptedTokens, isFinal: false)
        var degenerationGuard = StreamingDegenerationGuard(
            maxSingleTokenRun: config.singleTokenRunThreshold,
            blockPatternMaxPeriod: config.blockPatternMaxPeriod,
            blockPatternMinReps: config.blockPatternMinReps,
            stagnationThreshold: config.stagnationChunkThreshold
        )
        let filteredNewTokens = ContinuousChunkProcessor.filterTextTokens(newTokens)
        let guardAction = degenerationGuard.evaluateChunk(
            prefixTokens: history,
            newChunkTokens: filteredNewTokens,
            stableTokenCount: committer.stableTokens.count,
            hitMaxTokens: false,
            isFinal: true
        )
        XCTAssertEqual(
            guardAction, expectedGuardAction ?? .ok(filteredNewTokens: filteredNewTokens),
            file: file, line: line
        )

        let result = ContinuousChunkProcessor.finalizeDecodedTokens(
            history: &history, guardAction: guardAction,
            committer: &committer, config: config
        )

        XCTAssertEqual(result.action, .normal, file: file, line: line)
        XCTAssertEqual(result.confirmedTokens, expectedTokens, file: file, line: line)
        XCTAssertEqual(result.newlyEmittedTokens, expectedDelta, file: file, line: line)
        XCTAssertTrue(result.provisionalTokens.isEmpty, file: file, line: line)
        XCTAssertEqual(history, expectedTokens, file: file, line: line)
        XCTAssertEqual(committer.rawTokens, expectedTokens, file: file, line: line)
        XCTAssertEqual(committer.stableTokens, expectedTokens, file: file, line: line)
        XCTAssertEqual(committer.emittedTokens, expectedTokens, file: file, line: line)
    }
}

// MARK: - Draft Verification Across Chunks

final class ContinuousChunkProcessorDraftTests: XCTestCase {
    func testChunksWithDraftsDecodeLikeAFreshSequentialPass() throws {
        let tokenizer = TinyTokenizer()
        let model = TinyQwen3ASR.make(seed: 5, tiedEmbeddings: false, audioTokenId: TinyTokenizer.audioPadId)
        model.tokenizer = tokenizer
        let config = Self.configWithoutGuards()
        let processor = ContinuousChunkProcessor(model: model, tokenizer: tokenizer, config: config)

        var mel: MLXArray?
        var partlyAcceptedDrafts = 0
        for chunk in 0..<6 {
            let chunkMel = MLXRandom.normal(
                [200, model.config.audioConfig.numMelBins], key: MLXRandom.key(UInt64(chunk))
            )
            mel = mel.map { MLX.concatenated([$0, chunkMel], axis: 0) } ?? chunkMel
            let history = processor.allDecodedTokens
            let expected = try freshSequentialDecode(model: model, config: config, mel: mel!, history: history)
            let draft = history.suffix(min(config.rollbackTokens, history.count))
            let accepted = zip(draft, expected).prefix { $0 == $1 }.count
            if accepted > 0 && accepted < draft.count { partlyAcceptedDrafts += 1 }

            _ = try processor.processChunk(melFrames: chunkMel, language: config.language, isFinal: false)

            XCTAssertEqual(processor.allDecodedTokens, Array(history.dropLast(draft.count)) + expected, "chunk \(chunk)")
        }
        XCTAssertGreaterThan(partlyAcceptedDrafts, 0, "the fixture must reject part of some draft")
    }

    // MARK: - Helpers

    /// The tiny model never emits EOS, so every chunk runs to the token limit, and the guards
    /// would treat its random tokens as degenerate and reset the processor.
    private static func configWithoutGuards() -> StreamingConfig {
        var config = StreamingConfig(language: "English", maxNewTokensPerChunk: 8)
        config.repetitionRecoveryEnabled = false
        config.singleTokenRunThreshold = 1_000
        config.blockPatternMinReps = 1_000
        config.prefixDiversityThreshold = 0
        config.resetIntervalChunks = 1_000
        return config
    }

    /// Conditions the chunk as `ContinuousChunkProcessor` does, but prefills an empty cache and
    /// decodes one token at a time, with no reused KV rows and no draft.
    private func freshSequentialDecode(
        model: Qwen3ASRModel, config: StreamingConfig, mel: MLXArray, history: [Int]
    ) throws -> [Int] {
        let windowSize = config.encoderWindowSizeMelFrames
        let windows = stride(from: 0, to: mel.dim(0), by: windowSize).map {
            mel[$0..<min($0 + windowSize, mel.dim(0))]
        }
        let features = MLX.concatenated(try windows.map { try model.audioTower.encodeSingleWindow($0) }, axis: 0)
        let inputIds = model.buildPrompt(numAudioTokens: features.dim(0), language: config.language)
        let embeds = model.model.embedTokens(inputIds)
        var inputs = model.mergeAudioFeatures(
            inputsEmbeds: embeds, audioFeatures: features.asType(embeds.dtype), inputIds: inputIds
        )
        let prefixRange = ContinuousChunkProcessor.computePrefixTokenRange(
            totalTokens: history.count, maxPrefix: config.maxPrefixTokens, rollback: config.rollbackTokens
        )
        if !prefixRange.isEmpty {
            let prefixIds = MLXArray(history[prefixRange].map { Int32($0) }).expandedDimensions(axis: 0)
            inputs = MLX.concatenated([inputs, model.model.embedTokens(prefixIds)], axis: 1)
        }
        let cache = model.makeCache()
        let logits = model.prefill(inputEmbeddings: inputs, cache: cache)
        return model.greedyDecode(
            logits: logits, cache: cache, maxTokens: config.maxNewTokensPerChunk, isEndToken: { _ in false }
        ).tokens
    }
}

/// Maps the Qwen3-ASR prompt into the tiny model's 97-token vocabulary.
private struct TinyTokenizer: Tokenizer {
    static let audioPadId = 96
    private static let audioPad = "<|audio_pad|>"

    func encode(text: String) -> [Int] {
        var ids: [Int] = []
        var rest = Substring(text)
        while let scalar = rest.unicodeScalars.first {
            if rest.hasPrefix(Self.audioPad) {
                ids.append(Self.audioPadId)
                rest = rest.dropFirst(Self.audioPad.count)
            } else {
                ids.append(Int(scalar.value) % Self.audioPadId)
                rest = rest.dropFirst()
            }
        }
        return ids
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] { encode(text: text) }
    func tokenize(text: String) -> [String] { text.map(String.init) }
    func decode(tokens: [Int], skipSpecialTokens: Bool) -> String { tokens.map(String.init).joined(separator: " ") }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { String(id) }

    var bosToken: String? { nil }
    var bosTokenId: Int? { nil }
    var eosToken: String? { nil }
    var eosTokenId: Int? { nil }
    var unknownToken: String? { nil }
    var unknownTokenId: Int? { nil }

    func applyChatTemplate(messages: [Message]) throws -> [Int] { [] }
    func applyChatTemplate(messages: [Message], tools: [ToolSpec]?) throws -> [Int] { [] }
    func applyChatTemplate(
        messages: [Message], tools: [ToolSpec]?, additionalContext: [String: any Sendable]?
    ) throws -> [Int] { [] }
    func applyChatTemplate(messages: [Message], chatTemplate: ChatTemplateArgument) throws -> [Int] { [] }
    func applyChatTemplate(messages: [Message], chatTemplate: String) throws -> [Int] { [] }
    func applyChatTemplate(
        messages: [Message], chatTemplate: ChatTemplateArgument?, addGenerationPrompt: Bool,
        truncation: Bool, maxLength: Int?, tools: [ToolSpec]?
    ) throws -> [Int] { [] }
    func applyChatTemplate(
        messages: [Message], chatTemplate: ChatTemplateArgument?, addGenerationPrompt: Bool,
        truncation: Bool, maxLength: Int?, tools: [ToolSpec]?, additionalContext: [String: any Sendable]?
    ) throws -> [Int] { [] }
}
