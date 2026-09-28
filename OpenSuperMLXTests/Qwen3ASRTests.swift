// Qwen3ASRTests.swift
// OpenSuperMLXTests

import XCTest

import MLX
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
