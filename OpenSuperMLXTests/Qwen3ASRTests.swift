// Qwen3ASRTests.swift
// OpenSuperMLXTests

import XCTest

import MLX
import MLXLMCommon
@testable import MLXAudioSTT

final class Qwen3ASRFeatureLengthTests: XCTestCase {
    func testPartialChunkCountsOnlyItsOwnTokens() {
        XCTAssertEqual(tokenCounts(forFrames: [1, 99]), [1, 13])
    }

    func testFullChunksCountThirteenTokensEach() {
        XCTAssertEqual(tokenCounts(forFrames: [100, 800]), [13, 104])
    }

    func testRemainderAddsToFullChunks() {
        XCTAssertEqual(tokenCounts(forFrames: [199, 850]), [26, 111])
    }

    private func tokenCounts(forFrames frames: [Int32]) -> [Int32] {
        getFeatExtractOutputLengths(MLXArray(frames)).asType(.int32).asArray(Int32.self)
    }
}

final class Qwen3ASRPrefillTests: XCTestCase {
    private var model: Qwen3ASRModel!

    override func setUp() {
        super.setUp()
        model = TinyQwen3ASR.make(seed: 7)
    }

    // MARK: - Trailing-Row Logits

    func testPrefillLogitsMatchLastRowOfFullForward() {
        let embeds = TinyQwen3ASR.embeddings(rows: 45)
        let full = model.callAsFunction(
            inputIds: TinyQwen3ASR.placeholderIds(45), inputEmbeddings: embeds, cache: model.makeCache()
        )

        let last = model.prefill(inputEmbeddings: embeds, cache: model.makeCache())

        XCTAssertEqual(last.shape, [1, 1, TinyQwen3ASR.vocabularySize])
        TinyQwen3ASR.assertClose(last, full[0..., 44..., 0...])
    }

    func testPrefillReturnsRequestedTrailingRows() {
        let embeds = TinyQwen3ASR.embeddings(rows: 20)
        let full = model.callAsFunction(
            inputIds: TinyQwen3ASR.placeholderIds(20), inputEmbeddings: embeds, cache: model.makeCache()
        )

        let trailing = model.prefill(inputEmbeddings: embeds, cache: model.makeCache(), logitsRows: 4)

        XCTAssertEqual(trailing.shape, [1, 4, TinyQwen3ASR.vocabularySize])
        TinyQwen3ASR.assertClose(trailing, full[0..., 16..., 0...])
    }

    func testPrefillLeavesCacheReadyForDecoding() {
        let embeds = TinyQwen3ASR.embeddings(rows: 12)
        let fullCache = model.makeCache()
        _ = model.callAsFunction(inputIds: TinyQwen3ASR.placeholderIds(12), inputEmbeddings: embeds, cache: fullCache)
        let prefillCache = model.makeCache()
        _ = model.prefill(inputEmbeddings: embeds, cache: prefillCache)

        let token = MLXArray([Int32(3)]).reshaped(1, 1)
        XCTAssertEqual(prefillCache[0].offset, 12)
        TinyQwen3ASR.assertClose(
            model.callAsFunction(inputIds: token, cache: prefillCache),
            model.callAsFunction(inputIds: token, cache: fullCache)
        )
    }

    // MARK: - Bounded Passes

    func testSplitPrefillMatchesSinglePass() {
        let embeds = TinyQwen3ASR.embeddings(rows: 70)
        let singleCache = model.makeCache()
        let single = model.prefill(inputEmbeddings: embeds, cache: singleCache, logitsRows: 3, maxRowsPerPass: .max)
        let splitCache = model.makeCache()

        let split = model.prefill(inputEmbeddings: embeds, cache: splitCache, logitsRows: 3, maxRowsPerPass: 32)

        TinyQwen3ASR.assertClose(split, single)
        XCTAssertEqual(splitCache[0].offset, 70)
        let token = MLXArray([Int32(5)]).reshaped(1, 1)
        TinyQwen3ASR.assertClose(
            model.callAsFunction(inputIds: token, cache: splitCache),
            model.callAsFunction(inputIds: token, cache: singleCache)
        )
    }

    func testSplitPrefillKeepsRequestedRowsInFinalPass() {
        let embeds = TinyQwen3ASR.embeddings(rows: 67)
        let full = model.callAsFunction(
            inputIds: TinyQwen3ASR.placeholderIds(67), inputEmbeddings: embeds, cache: model.makeCache()
        )

        let trailing = model.prefill(inputEmbeddings: embeds, cache: model.makeCache(), logitsRows: 5, maxRowsPerPass: 32)

        TinyQwen3ASR.assertClose(trailing, full[0..., 62..., 0...])
    }

    func testSplitPrefillAllocatesTheCacheOnceForTheWholePrompt() throws {
        let cache = model.makeCache()

        _ = model.prefill(inputEmbeddings: TinyQwen3ASR.embeddings(rows: 600), cache: cache, maxRowsPerPass: 100)

        let layer = try XCTUnwrap(cache[0] as? KVCacheSimple)
        // Growing by the 256-row step pass after pass would end at 656 rows after three copies.
        XCTAssertEqual(layer.innerState()[0].dim(2), 768)
        XCTAssertEqual(layer.step, 256)
    }
}

// MARK: - Greedy Decode

final class Qwen3ASRGreedyDecodeTests: XCTestCase {
    private let promptRows = 9
    private var model: Qwen3ASRModel!
    private var prompt: MLXArray!
    private var reference: [Int] = []

    override func setUp() {
        super.setUp()
        model = TinyQwen3ASR.make(seed: 11, tiedEmbeddings: false)
        prompt = TinyQwen3ASR.embeddings(rows: promptRows)
        reference = sequentialGreedy(count: 12)
        XCTAssertGreaterThan(Set(reference).count, 3, "the fixture must decode varied tokens")
    }

    func testDecodeWithoutDraftMatchesSequentialGreedy() {
        let (result, cacheOffset) = decode(draft: [], maxTokens: 12)

        XCTAssertEqual(result.tokens, reference)
        XCTAssertEqual(result.decodeSteps, 12)
        XCTAssertEqual(cacheOffset, promptRows + 12)
        XCTAssertNotNil(result.nextLogits)
    }

    func testMatchingDraftPrefixIsAcceptedWithoutDecodeSteps() {
        let draft = Array(reference.prefix(3)) + [wrongToken(for: reference[3])]

        let (result, cacheOffset) = decode(draft: draft, maxTokens: 12)

        XCTAssertEqual(result.tokens, reference)
        XCTAssertEqual(result.acceptedDraftTokens, 3)
        XCTAssertEqual(result.decodeSteps, 9)
        XCTAssertEqual(cacheOffset, promptRows + 12)
    }

    func testFullyMatchingDraftIsAccepted() {
        let (result, cacheOffset) = decode(draft: Array(reference.prefix(5)), maxTokens: 12)

        XCTAssertEqual(result.tokens, reference)
        XCTAssertEqual(result.acceptedDraftTokens, 5)
        XCTAssertEqual(result.decodeSteps, 7)
        XCTAssertEqual(cacheOffset, promptRows + 12)
    }

    func testRejectedDraftFallsBackToModelChoice() {
        let draft = [wrongToken(for: reference[0]), reference[1]]

        let (result, cacheOffset) = decode(draft: draft, maxTokens: 12)

        XCTAssertEqual(result.tokens, reference)
        XCTAssertEqual(result.acceptedDraftTokens, 0)
        XCTAssertEqual(cacheOffset, promptRows + 12)
    }

    func testEndTokenStopsWithoutFeedingIt() throws {
        let end = try XCTUnwrap((1..<reference.count).first { !reference[..<$0].contains(reference[$0]) })

        let (result, cacheOffset) = decode(draft: Array(reference.prefix(1)), maxTokens: 12, endToken: reference[end])

        XCTAssertEqual(result.tokens, Array(reference.prefix(end)))
        XCTAssertEqual(result.endToken, reference[end])
        XCTAssertNil(result.nextLogits)
        XCTAssertEqual(cacheOffset, promptRows + end)
    }

    func testCacheAfterEndTokenContinuesLikeSequentialDecoding() throws {
        let end = try XCTUnwrap((1..<reference.count).first { !reference[..<$0].contains(reference[$0]) })
        let cache = model.makeCache()
        let logits = model.prefill(inputEmbeddings: prompt, cache: cache)
        _ = model.greedyDecode(
            logits: logits, cache: cache, maxTokens: 12, isEndToken: { $0 == self.reference[end] }
        )
        let referenceCache = model.makeCache()
        _ = model.prefill(inputEmbeddings: prompt, cache: referenceCache)
        for token in reference.prefix(end) {
            eval(model.callAsFunction(inputIds: MLXArray([Int32(token)]).reshaped(1, 1), cache: referenceCache))
        }

        let probe = MLXArray([Int32(wrongToken(for: reference[end]))]).reshaped(1, 1)
        TinyQwen3ASR.assertClose(
            model.callAsFunction(inputIds: probe, cache: cache),
            model.callAsFunction(inputIds: probe, cache: referenceCache)
        )
    }

    func testStopCallbackEndsBeforeFeedingTheToken() {
        let (result, cacheOffset) = decode(draft: [], maxTokens: 12, stopAfter: 3)

        XCTAssertEqual(result.tokens, Array(reference.prefix(3)))
        XCTAssertTrue(result.stopped)
        XCTAssertEqual(cacheOffset, promptRows + 2)
    }

    func testStopInsideAcceptedDraftTrimsRemainingDraftRows() {
        let (result, cacheOffset) = decode(draft: Array(reference.prefix(5)), maxTokens: 12, stopAfter: 3)

        XCTAssertEqual(result.tokens, Array(reference.prefix(3)))
        XCTAssertTrue(result.stopped)
        XCTAssertEqual(cacheOffset, promptRows + 2)
    }

    // MARK: - Helpers

    private func sequentialGreedy(count: Int) -> [Int] {
        let cache = model.makeCache()
        var logits = model.callAsFunction(
            inputIds: TinyQwen3ASR.placeholderIds(promptRows), inputEmbeddings: prompt, cache: cache
        )
        var tokens: [Int] = []
        for _ in 0..<count {
            let token = logits[0..., -1, 0...].argMax(axis: -1).item(Int.self)
            tokens.append(token)
            logits = model.callAsFunction(inputIds: MLXArray([Int32(token)]).reshaped(1, 1), cache: cache)
            eval(logits)
        }
        return tokens
    }

    private func decode(
        draft: [Int], maxTokens: Int, endToken: Int? = nil, stopAfter: Int? = nil
    ) -> (Qwen3ASRModel.GreedyDecodeResult, Int) {
        let cache = model.makeCache()
        var embeds: MLXArray = prompt
        if !draft.isEmpty {
            let ids = MLXArray(draft.map { Int32($0) }).reshaped(1, draft.count)
            embeds = MLX.concatenated([prompt, model.model.embedTokens(ids)], axis: 1)
        }
        let logits = model.prefill(inputEmbeddings: embeds, cache: cache, logitsRows: draft.count + 1)
        let result = model.greedyDecode(
            logits: logits, draft: draft, cache: cache, maxTokens: maxTokens,
            isEndToken: { $0 == endToken },
            onToken: { $0.count == stopAfter }
        )
        return (result, cache[0].offset)
    }

    private func wrongToken(for token: Int) -> Int {
        (token + 1) % TinyQwen3ASR.vocabularySize
    }
}

// MARK: - Audio Tower Fallback

final class Qwen3ASRAudioTowerFallbackTests: XCTestCase {
    private var model: Qwen3ASRModel!
    private var mel: MLXArray!

    override func setUp() {
        super.setUp()
        model = TinyQwen3ASR.make(seed: 5)
        mel = MLXRandom.normal([200, model.config.audioConfig.numMelBins], key: MLXRandom.key(3))
    }

    func testFailingCoreMLTowerFallsBackToTheMLXWeights() throws {
        let expected = try model.audioTower.encodeSingleWindow(mel)
        var reportedFailures = 0
        model.audioTower.coreMLTower = FailingCoreMLTower()
        model.audioTower.loadMLXWeights = {}
        model.audioTower.onCoreMLFailure = { _ in reportedFailures += 1 }

        TinyQwen3ASR.assertClose(try model.audioTower.encodeSingleWindow(mel), expected)
        XCTAssertNil(model.audioTower.coreMLTower)
        XCTAssertEqual(reportedFailures, 1)
    }

    func testAudioTowerThrowsWhenNeitherTowerCanRun() {
        model.audioTower.coreMLTower = FailingCoreMLTower()
        model.audioTower.loadMLXWeights = { throw TowerFailure.missingWeights }

        XCTAssertThrowsError(try model.audioTower.encodeSingleWindow(mel)) { error in
            XCTAssertTrue(error is Qwen3ASRAudioTowerUnavailableError, "\(error)")
        }
    }

    func testUnavailableAudioTowerKeepsFailingWithoutReloading() {
        var loadAttempts = 0
        model.audioTower.coreMLTower = FailingCoreMLTower()
        model.audioTower.loadMLXWeights = {
            loadAttempts += 1
            throw TowerFailure.missingWeights
        }
        _ = try? model.audioTower.encodeSingleWindow(mel)

        XCTAssertThrowsError(try model.audioTower(mel.transposed().expandedDimensions(axis: 0)))
        XCTAssertEqual(loadAttempts, 1)
    }
}

private struct FailingCoreMLTower: Qwen3ASRCoreMLEncoding {
    func encode(features: MLXArray, lengths: [Int]) throws -> MLXArray { throw TowerFailure.prediction }
    func encodeWindow(_ melFrames: MLXArray) throws -> MLXArray { throw TowerFailure.prediction }
}

private enum TowerFailure: Error {
    case prediction
    case missingWeights
}

// MARK: - Tiny Random Model

enum TinyQwen3ASR {
    static let vocabularySize = 97
    static let hiddenSize = 32

    static func make(
        seed: UInt64, tiedEmbeddings: Bool = true, audioTokenId: Int = Qwen3ASRConfig().audioTokenId
    ) -> Qwen3ASRModel {
        MLXRandom.seed(seed)
        let text = Qwen3TextConfig(
            vocabSize: vocabularySize, hiddenSize: hiddenSize, intermediateSize: 64, numHiddenLayers: 2,
            numAttentionHeads: 4, numKeyValueHeads: 2, headDim: 8, tieWordEmbeddings: tiedEmbeddings
        )
        let audio = Qwen3AudioEncoderConfig(
            encoderLayers: 1, encoderAttentionHeads: 2, encoderFfnDim: 32, dModel: 16,
            outputDim: hiddenSize, downsampleHiddenSize: 8
        )
        let model = Qwen3ASRModel(Qwen3ASRConfig(audioConfig: audio, textConfig: text, audioTokenId: audioTokenId))
        eval(model.model)
        if let lmHead = model.lmHead { eval(lmHead) }
        return model
    }

    static func embeddings(rows: Int) -> MLXArray {
        MLXRandom.normal([1, rows, hiddenSize])
    }

    static func placeholderIds(_ rows: Int) -> MLXArray {
        MLXArray.zeros([1, rows], dtype: .int32)
    }

    static func assertClose(
        _ actual: MLXArray, _ expected: MLXArray, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual.shape, expected.shape, file: file, line: line)
        XCTAssertLessThan(abs(actual - expected).max().item(Float.self), 1e-4, file: file, line: line)
    }
}
