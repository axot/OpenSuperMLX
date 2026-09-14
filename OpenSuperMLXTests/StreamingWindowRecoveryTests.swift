// StreamingWindowRecoveryTests.swift
// OpenSuperMLXTests

import XCTest

@testable import MLXAudioSTT

final class StreamingWindowRecoveryTests: XCTestCase {
    func testResetKeepsFrozenPrefixAsRenderingBoundary() {
        var recovery = StreamingWindowRecovery(windowFrames: 800, maximumWindows: 4)
        recovery.reset(confirmedPrefix: "accepted ABCD")
        XCTAssertEqual(recovery.activeCheckpoint?.frame, 0)
        XCTAssertEqual(recovery.render("ABCD"), "accepted ABCDABCD")
        XCTAssertEqual(recovery.render(" word"), "accepted ABCD word")
        recovery.reset(confirmedPrefix: "after gap", frame: 1000)
        XCTAssertEqual(recovery.begin(endFrame: 1200, availableStartFrame: 1000)?.frame, 1000)
        XCTAssertEqual(recovery.render(" more"), "after gap more")
    }

    func testRecoveryFreezesPreviousWindowIncludingItsPendingTail() {
        var recovery = StreamingWindowRecovery(windowFrames: 800, maximumWindows: 4)
        recovery.record(endFrame: 2400, confirmed: "甲乙", pending: "丙丁戊")
        let checkpoint = recovery.begin(endFrame: 2800, availableStartFrame: 0)
        XCTAssertEqual(checkpoint?.frame, 2400)
        XCTAssertEqual(checkpoint?.text, "甲乙丙丁戊")
        XCTAssertEqual(recovery.render("己庚辛壬"), "甲乙丙丁戊己庚辛壬")
    }

    func testExactWindowEndSelectsStartOfLastNonemptyWindow() {
        var recovery = StreamingWindowRecovery(windowFrames: 800, maximumWindows: 4)
        recovery.record(endFrame: 800, confirmed: "old", pending: "")
        recovery.record(endFrame: 1600, confirmed: "new", pending: "")
        XCTAssertEqual(recovery.begin(endFrame: 1600, availableStartFrame: 0)?.frame, 800)
    }

    func testNoCheckpointNeverGuessesAnAudioOrTextBoundary() {
        var recovery = StreamingWindowRecovery(windowFrames: 800, maximumWindows: 4)
        recovery.record(endFrame: 2400, confirmed: "old", pending: "tail")
        XCTAssertNil(recovery.begin(endFrame: 2800, availableStartFrame: 2500))
        recovery.reset()
        XCTAssertEqual(recovery.begin(endFrame: 400, availableStartFrame: 0)?.frame, 0)
    }

    func testGenuineRepeatedSpeechIsPreservedAtNonoverlappingAudioBoundary() {
        var recovery = StreamingWindowRecovery(windowFrames: 800, maximumWindows: 4)
        recovery.record(endFrame: 800, confirmed: "ABCDE", pending: "")
        _ = recovery.begin(endFrame: 1000, availableStartFrame: 0)
        XCTAssertEqual(recovery.render("BCDEF"), "ABCDEBCDEF")
        XCTAssertEqual(recovery.render("DEF"), "ABCDEDEF")
    }

    func testCheckpointStateStaysBoundedAndLaterRecoveryReplacesSuffix() {
        var recovery = StreamingWindowRecovery(windowFrames: 800, maximumWindows: 4)
        for index in 1...20 {
            recovery.record(endFrame: index * 800, confirmed: "\(index)", pending: "tail")
        }
        XCTAssertLessThanOrEqual(recovery.checkpointCount, 5)
        XCTAssertEqual(recovery.begin(endFrame: 16200, availableStartFrame: 12800)?.text, "20tail")
        recovery.record(endFrame: 16800, confirmed: "20tailcorrect", pending: "pending")
        XCTAssertEqual(recovery.begin(endFrame: 17000, availableStartFrame: 16000)?.text, "20tailcorrectpending")
        XCTAssertEqual(recovery.render(""), "20tailcorrectpending")
    }

    func testNondividingChunkDurationUsesTheMatchingEarlierTextCheckpoint() {
        var recovery = StreamingWindowRecovery(windowFrames: 800, maximumWindows: 4)
        recovery.record(endFrame: 600, confirmed: "six", pending: "tail")
        recovery.record(endFrame: 900, confirmed: "nine", pending: "")
        XCTAssertEqual(recovery.begin(endFrame: 1200, availableStartFrame: 0)?.frame, 600)
        XCTAssertEqual(recovery.activeCheckpoint?.text, "sixtail")
        recovery.reset(confirmedPrefix: "prior segment")
        XCTAssertEqual(recovery.begin(endFrame: 200, availableStartFrame: 0)?.text, "prior segment")
    }

    func testReplacementKeepsCompleteUnicodeTextAndWhitespace() {
        var recovery = StreamingWindowRecovery(windowFrames: 800, maximumWindows: 4)
        recovery.record(endFrame: 800, confirmed: "あ", pending: "")
        _ = recovery.begin(endFrame: 1000, availableStartFrame: 0)
        XCTAssertEqual(recovery.render("あい "), "ああい ")
    }
}
