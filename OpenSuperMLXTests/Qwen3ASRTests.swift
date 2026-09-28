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
}

// MARK: - Tiny Random Model

enum TinyQwen3ASR {
    static let vocabularySize = 97
    static let hiddenSize = 32

    static func make(seed: UInt64) -> Qwen3ASRModel {
        MLXRandom.seed(seed)
        let text = Qwen3TextConfig(
            vocabSize: vocabularySize, hiddenSize: hiddenSize, intermediateSize: 64, numHiddenLayers: 2,
            numAttentionHeads: 4, numKeyValueHeads: 2, headDim: 8
        )
        let audio = Qwen3AudioEncoderConfig(
            encoderLayers: 1, encoderAttentionHeads: 2, encoderFfnDim: 32, dModel: 16,
            outputDim: hiddenSize, downsampleHiddenSize: 8
        )
        let model = Qwen3ASRModel(Qwen3ASRConfig(audioConfig: audio, textConfig: text))
        eval(model.model)
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
