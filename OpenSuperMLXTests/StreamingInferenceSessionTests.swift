// StreamingInferenceSessionTests.swift
// OpenSuperMLXTests

import XCTest

@testable import MLXAudioSTT

final class StreamingInferenceSessionTests: XCTestCase {
    func testEOSOnlyFinalFallbackDoesNotRepeatCommittedTextAfterEmptyDecodes() {
        for emptyChunks in 1...4 {
            assertFinalReplay(
                emptyChunks: emptyChunks, finalTokens: [],
                expectedText: "ABCDEFGHIJKLMNO", expectedDelta: ""
            )
        }
    }

    func testRejectedFinalFallbackDoesNotRepeatCommittedTextAfterEmptyDecodes() {
        assertFinalReplay(
            emptyChunks: 2, finalTokens: Array(repeating: 99, count: 20),
            expectedText: "ABCDEFGHIJKLMNO", expectedDelta: "",
            expectedGuardAction: .recoveryReset
        )
    }

    func testFinalRevisionEmitsOnlyTextBeyondCommittedPrefixAfterRollback() {
        assertFinalReplay(
            emptyChunks: 2, finalTokens: Array(70...81),
            expectedText: "ABCDEFGHIJKLMNOPQ", expectedDelta: "PQ"
        )
    }

    func testShorterFinalTailRevisionStillEmitsNewText() {
        assertFinalReplay(
            emptyChunks: 0, finalTokens: [86, 87],
            expectedText: "ABCDEFGHIJKLMNOVW", expectedDelta: "VW"
        )
    }

    func testFinalDeltaHandlesUnicodeAfterConfirmedTextContracts() {
        for (finalText, expectedDelta) in [
            ("甲乙丙丁戊己庚", ""),
            ("甲乙丙丁戊己庚辛壬癸追加", "追加"),
        ] {
            var state = TextEmissionState()
            _ = state.consume("甲乙丙丁戊己庚辛壬癸")
            _ = state.consume("甲乙丙丁戊己庚")
            _ = state.consume("甲乙丙丁戊")

            XCTAssertEqual(state.consume(finalText, isFinal: true), expectedDelta)
            XCTAssertEqual(state.mergedText, "甲乙丙丁戊己庚辛壬癸" + expectedDelta)
        }
    }

    func testResetAllowsRepeatedPrefixInNextSegmentToFinish() {
        for action in [ChunkAction.periodicReset, .recoveryReset] {
            var state = TextEmissionState()
            _ = state.consume("ABCDE")
            _ = state.consume("ABCDE", action: action)
            _ = state.consume("AB")

            XCTAssertEqual(state.consume("ABC", isFinal: true), "C")
            XCTAssertEqual(state.mergedText, "ABCDEABC")
        }
    }

    func testNonfinalDeltaContinuesToUsePreviousChunk() {
        var state = TextEmissionState()
        _ = state.consume("ABCDEFGHIJKLMNO")
        _ = state.consume("ABCDE")

        XCTAssertEqual(state.consume("ABCDEFGHIJ"), "FGHIJ")
    }

    func testDivergentConfirmedRevisionUpdatesFinalBaseline() {
        var state = TextEmissionState()
        _ = state.consume("ABCDEF")
        XCTAssertEqual(state.consume("AX"), "X")

        XCTAssertEqual(state.consume("AXY", isFinal: true), "Y")
        XCTAssertEqual(state.mergedText, "ABCDEFXY")
    }

    // MARK: - Helpers

    private func assertFinalReplay(
        emptyChunks: Int,
        finalTokens: [Int],
        expectedText: String,
        expectedDelta: String,
        expectedGuardAction: GuardAction? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let config = StreamingConfig()
        var history: [Int] = []
        var committer = StreamingTextCommitter()
        var degenerationGuard = StreamingDegenerationGuard(
            blockPatternMaxPeriod: config.blockPatternMaxPeriod
        )
        var state = TextEmissionState()
        let chunks = [Array(65...84), Array(80...84), Array(80...84)]
            + Array(repeating: [Int](), count: emptyChunks)
        for tokens in chunks {
            let action = degenerationGuard.evaluateChunk(
                prefixTokens: history, newChunkTokens: tokens,
                stableTokenCount: committer.stableTokens.count,
                hitMaxTokens: false, isFinal: false
            )
            guard case .ok(let newTokens) = action else {
                return XCTFail("Unexpected nonfinal rejection", file: file, line: line)
            }
            history = Array(history.dropLast(min(config.rollbackTokens, history.count))) + newTokens
            let result = committer.processChunkTokens(history, isFinal: false)
            _ = state.consume(decode(result.confirmedTokens))
        }
        XCTAssertEqual(state.mergedText, "ABCDEFGHIJKLMNO", file: file, line: line)

        let action = degenerationGuard.evaluateChunk(
            prefixTokens: history, newChunkTokens: finalTokens,
            stableTokenCount: committer.stableTokens.count,
            hitMaxTokens: false, isFinal: true
        )
        XCTAssertEqual(
            action, expectedGuardAction ?? .ok(filteredNewTokens: finalTokens),
            file: file, line: line
        )
        let result = ContinuousChunkProcessor.finalizeDecodedTokens(
            history: &history, guardAction: action,
            committer: &committer, config: config
        )
        let delta = state.consume(decode(result.confirmedTokens), isFinal: true, action: result.action)

        XCTAssertEqual(delta, expectedDelta, file: file, line: line)
        XCTAssertEqual(state.mergedText, expectedText, file: file, line: line)
    }

    private func decode(_ tokens: [Int]) -> String {
        String(tokens.map { Character(UnicodeScalar($0)!) })
    }

    private struct TextEmissionState {
        var previousText = ""
        var finalizationBaseline = ""
        var mergedText = ""

        mutating func consume(
            _ confirmedText: String,
            isFinal: Bool = false,
            action: ChunkAction = .normal
        ) -> String {
            let delta = StreamingInferenceSession.consumeConfirmedText(
                confirmedText,
                previousText: &previousText,
                finalizationBaseline: &finalizationBaseline,
                isFinal: isFinal,
                action: action
            )
            mergedText = TextMergeUtilities.mergeWithOverlapRemoval(
                prefix: mergedText, newText: delta
            )
            return delta
        }
    }
}
