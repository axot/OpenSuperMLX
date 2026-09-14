// StreamingAudioTimelineTests.swift
// OpenSuperMLXTests

import XCTest

@testable import MLXAudioSTT

final class StreamingAudioTimelineTests: XCTestCase {
    func testContinuousInputKeepsRecordingSamplePositions() {
        var timeline = StreamingAudioTimeline()
        timeline.append(sampleCount: 192_000, skippedSamples: 0)
        XCTAssertEqual(timeline.sourceRange(for: 128_000..<160_000), 128_000..<160_000)
    }

    func testBackpressureOffsetsApplyToTheFollowingAudio() {
        var timeline = StreamingAudioTimeline()
        timeline.append(sampleCount: 128_000, skippedSamples: 0)
        timeline.append(sampleCount: 64_000, skippedSamples: 32_000)
        XCTAssertEqual(timeline.sourceRange(for: 128_000..<160_000), 160_000..<192_000)
        XCTAssertEqual(timeline.sourceRange(for: 96_000..<160_000), 96_000..<192_000)
    }

    func testRangeEndingAtDropDoesNotIncludeTheFollowingDrop() {
        var timeline = StreamingAudioTimeline()
        timeline.append(sampleCount: 128_000, skippedSamples: 0)
        timeline.append(sampleCount: 64_000, skippedSamples: 32_000)
        XCTAssertEqual(timeline.sourceRange(for: 96_000..<128_000), 96_000..<128_000)
    }

    func testMultipleDropsAccumulateAndFlushCannotExceedRecordedAudio() {
        var timeline = StreamingAudioTimeline()
        timeline.append(sampleCount: 32_000, skippedSamples: 16_000)
        timeline.append(sampleCount: 32_000, skippedSamples: 48_000)
        XCTAssertEqual(timeline.sourceRange(for: 32_000..<64_160), 96_000..<128_000)
        XCTAssertEqual(timeline.sourceRange(for: 64_000..<64_160), 128_000..<128_000)
    }

    func testPruningRetainsTheOffsetAtBothSidesOfTheOldestBoundary() {
        var timeline = StreamingAudioTimeline()
        for _ in 0..<100 {
            timeline.append(sampleCount: 1600, skippedSamples: 160)
        }
        let before = timeline.sourceRange(for: 156_800..<158_400)
        let after = timeline.sourceRange(for: 158_400..<160_000)
        timeline.discardOffsets(before: 158_400)
        XCTAssertEqual(timeline.sourceRange(for: 156_800..<158_400), before)
        XCTAssertEqual(timeline.sourceRange(for: 158_400..<160_000), after)
        XCTAssertLessThanOrEqual(timeline.offsetCount, 2)
    }

    func testEmptyInputHasAnEmptyRange() {
        let timeline = StreamingAudioTimeline()
        XCTAssertEqual(timeline.sourceRange(for: 0..<160), 0..<0)
    }

    func testSyntheticTailIsExcludedFromSourceFilePositions() {
        var timeline = StreamingAudioTimeline(sourceSampleLimit: 160_000)
        timeline.append(sampleCount: 170_560, skippedSamples: 0)
        XCTAssertEqual(timeline.sourceRange(for: 128_000..<170_560), 128_000..<160_000)
        XCTAssertEqual(timeline.sourceRange(for: 160_000..<170_560), 160_000..<160_000)
    }
}
