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
