// StreamingTextCommitterTests.swift
// OpenSuperMLXTests

import XCTest

@testable import MLXAudioSTT

final class StreamingTextCommitterTests: XCTestCase {

    // MARK: - Basic Commit

    func testBasicCommit() {
        var committer = StreamingTextCommitter(rollbackTokens: 5, coldStartChunks: 0)
        let tokens = Array(0..<10)
        let result = committer.processChunkTokens(tokens, isFinal: false)

        XCTAssertEqual(result.confirmedTokens, Array(0..<5))
        XCTAssertEqual(result.provisionalTokens, Array(5..<10))
        XCTAssertEqual(result.newlyEmittedTokens, Array(0..<5))
    }

    // MARK: - LCP Stabilization

    func testLCPStabilization() {
        var committer = StreamingTextCommitter(rollbackTokens: 2, coldStartChunks: 0)

        let chunk1 = [10, 20, 30, 40, 50]
        _ = committer.processChunkTokens(chunk1, isFinal: false)

        let chunk2 = [10, 20, 30, 40, 50, 60, 70]
        let result = committer.processChunkTokens(chunk2, isFinal: false)

        XCTAssertEqual(result.confirmedTokens, [10, 20, 30, 40, 50])
        XCTAssertTrue(result.newlyEmittedTokens.contains(50))
    }

    // MARK: - Overlap Dedup

    func testOverlapDedup() {
        var committer = StreamingTextCommitter(rollbackTokens: 0, coldStartChunks: 0, minOverlapMatch: 2)

        let chunk1 = [1, 2, 3]
        let result1 = committer.processChunkTokens(chunk1, isFinal: false)
        XCTAssertEqual(result1.newlyEmittedTokens, [1, 2, 3])

        let chunk2 = [2, 3, 4, 5]
        let result2 = committer.processChunkTokens(chunk2, isFinal: false)
        XCTAssertEqual(result2.newlyEmittedTokens, [4, 5])
    }

    // MARK: - Cold Start

    func testColdStart() {
        var committer = StreamingTextCommitter(rollbackTokens: 2, coldStartChunks: 2)

        let result1 = committer.processChunkTokens([1, 2, 3, 4, 5], isFinal: false)
        XCTAssertTrue(result1.newlyEmittedTokens.isEmpty)

        let result2 = committer.processChunkTokens([1, 2, 3, 4, 5, 6], isFinal: false)
        XCTAssertTrue(result2.newlyEmittedTokens.isEmpty)

        let result3 = committer.processChunkTokens([1, 2, 3, 4, 5, 6, 7], isFinal: false)
        XCTAssertFalse(result3.newlyEmittedTokens.isEmpty)
    }

    // MARK: - Final Flush

    func testFinalFlush() {
        var committer = StreamingTextCommitter(rollbackTokens: 5, coldStartChunks: 0)
        let tokens = Array(0..<10)
        let result = committer.processChunkTokens(tokens, isFinal: true)

        XCTAssertEqual(result.confirmedTokens, Array(0..<10))
        XCTAssertTrue(result.provisionalTokens.isEmpty)
        XCTAssertEqual(result.newlyEmittedTokens, Array(0..<10))
    }

    // MARK: - Short Output

    func testShortOutput() {
        var committer = StreamingTextCommitter(rollbackTokens: 5, coldStartChunks: 0)
        let result = committer.processChunkTokens([1, 2, 3], isFinal: false)

        XCTAssertTrue(result.confirmedTokens.isEmpty)
        XCTAssertEqual(result.provisionalTokens, [1, 2, 3])
        XCTAssertTrue(result.newlyEmittedTokens.isEmpty)
    }

    // MARK: - Empty Chunk

    func testEmptyChunk() {
        var committer = StreamingTextCommitter(rollbackTokens: 5, coldStartChunks: 0)
        let result = committer.processChunkTokens([], isFinal: false)

        XCTAssertTrue(result.confirmedTokens.isEmpty)
        XCTAssertTrue(result.provisionalTokens.isEmpty)
        XCTAssertTrue(result.newlyEmittedTokens.isEmpty)
    }
}
