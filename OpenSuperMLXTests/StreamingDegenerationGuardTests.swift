// StreamingDegenerationGuardTests.swift
// OpenSuperMLXTests

import XCTest

@testable import MLXAudioSTT

final class StreamingDegenerationGuardTests: XCTestCase {

    // MARK: - Layer 1: Single-token run suppression (scoped to new chunk)

    func testSingleTokenRunSuppression() {
        var guard_ = StreamingDegenerationGuard()
        let newChunk = Array(repeating: 1, count: 15)

        let action = guard_.evaluateChunk(
            prefixTokens: [], newChunkTokens: newChunk,
            stableTokenCount: 0, hitMaxTokens: false, isFinal: false
        )

        XCTAssertEqual(action, .ok(filteredNewTokens: Array(repeating: 1, count: 12)))
    }

    func testRunSuppressionWithPrefixTrailingRun() {
        var guard_ = StreamingDegenerationGuard()
        let prefix = Array(repeating: 42, count: 10)
        let newChunk = Array(repeating: 42, count: 5)

        let action = guard_.evaluateChunk(
            prefixTokens: prefix, newChunkTokens: newChunk,
            stableTokenCount: 0, hitMaxTokens: false, isFinal: false
        )

        XCTAssertEqual(action, .ok(filteredNewTokens: Array(repeating: 42, count: 2)))
    }

    // MARK: - Layer 2: Block pattern detection

    func testBlockPatternDetection() {
        var guard_ = StreamingDegenerationGuard()
        let pattern = [1, 2, 3, 1, 2, 3, 1, 2, 3, 1, 2, 3]

        let action = guard_.evaluateChunk(
            prefixTokens: [], newChunkTokens: pattern,
            stableTokenCount: 0, hitMaxTokens: false, isFinal: false
        )

        XCTAssertEqual(action, .recoveryReset)
    }

    func testBlockPatternInPrefixPlusNew() {
        var guard_ = StreamingDegenerationGuard()
        let prefix = [1, 2, 3, 1, 2, 3, 1, 2, 3]
        let newChunk = [1, 2, 3]

        let action = guard_.evaluateChunk(
            prefixTokens: prefix, newChunkTokens: newChunk,
            stableTokenCount: 0, hitMaxTokens: false, isFinal: false
        )

        XCTAssertEqual(action, .recoveryReset)
    }

    // MARK: - Layer 3: Stagnation detection (candidateAdvance)

    func testStagnationDetection() {
        var guard_ = StreamingDegenerationGuard()

        for _ in 0..<3 {
            let action = guard_.evaluateChunk(
                prefixTokens: [1, 2, 3], newChunkTokens: [],
                stableTokenCount: 3, hitMaxTokens: true, isFinal: false
            )
            XCTAssertEqual(action, .ok(filteredNewTokens: []))
        }

        let action = guard_.evaluateChunk(
            prefixTokens: [1, 2, 3], newChunkTokens: [],
            stableTokenCount: 3, hitMaxTokens: true, isFinal: false
        )
        XCTAssertEqual(action, .recoveryReset)
    }

    func testStagnationNotTriggeredOnFinal() {
        var guard_ = StreamingDegenerationGuard()

        for _ in 0..<4 {
            let action = guard_.evaluateChunk(
                prefixTokens: [1, 2, 3], newChunkTokens: [],
                stableTokenCount: 3, hitMaxTokens: true, isFinal: true
            )
            XCTAssertEqual(action, .ok(filteredNewTokens: []))
        }
    }

    // MARK: - No false positive

    func testNoFalsePositive() {
        var guard_ = StreamingDegenerationGuard()
        let newChunk = [1, 2, 3, 4, 5, 6, 7, 8]

        let action = guard_.evaluateChunk(
            prefixTokens: [], newChunkTokens: newChunk,
            stableTokenCount: 0, hitMaxTokens: false, isFinal: false
        )

        XCTAssertEqual(action, .ok(filteredNewTokens: [1, 2, 3, 4, 5, 6, 7, 8]))
    }

    // MARK: - CJK uses same threshold

    func testCJKSingleCharHigherThreshold() {
        var guard_ = StreamingDegenerationGuard()
        let cjkToken = 50_000
        let newChunk = Array(repeating: cjkToken, count: 15)

        let action = guard_.evaluateChunk(
            prefixTokens: [], newChunkTokens: newChunk,
            stableTokenCount: 0, hitMaxTokens: false, isFinal: false
        )

        XCTAssertEqual(action, .ok(filteredNewTokens: Array(repeating: cjkToken, count: 12)))
    }

    // MARK: - Recovery on many dropped tokens

    func testRecoveryOnManyDropped() {
        var guard_ = StreamingDegenerationGuard()
        let newChunk = Array(repeating: 42, count: 20)

        let action = guard_.evaluateChunk(
            prefixTokens: [], newChunkTokens: newChunk,
            stableTokenCount: 0, hitMaxTokens: false, isFinal: false
        )

        XCTAssertEqual(action, .recoveryReset)
    }

    // MARK: - Stagnation counter reset

    func testStagnationResets() {
        var guard_ = StreamingDegenerationGuard()

        for _ in 0..<2 {
            _ = guard_.evaluateChunk(
                prefixTokens: [1], newChunkTokens: [],
                stableTokenCount: 1, hitMaxTokens: true, isFinal: false
            )
        }
        XCTAssertEqual(guard_.stagnantChunkCount, 2)

        guard_.resetStagnation()
        XCTAssertEqual(guard_.stagnantChunkCount, 0)
    }
}
