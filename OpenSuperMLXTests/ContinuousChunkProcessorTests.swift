// ContinuousChunkProcessorTests.swift
// OpenSuperMLXTests

import XCTest

import MLX
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
