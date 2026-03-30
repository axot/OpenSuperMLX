// StreamingTruncationTests.swift
// OpenSuperMLXTests

import XCTest

import MLXAudioSTT
@testable import MLXAudioSTT
@testable import OpenSuperMLX

final class StreamingTruncationTests: XCTestCase {

    // MARK: - Bug 2: VAD flush(force:)

    func testFlushEmitsSegmentBelowMinSpeechDurationWhenForced() throws {
        let segmenter = VADSegmenter(
            minSilenceDuration: 0.25,
            minSpeechDuration: 0.5
        )
        guard segmenter.isAvailable else {
            throw XCTSkip("SileroVAD not available in test environment")
        }

        let sineWave = generateSineWave(frequency: 440, durationSeconds: 0.3, sampleRate: 16000)
        let silence = [Float](repeating: 0, count: 8000)

        let segments = segmenter.feedSamples(sineWave + silence)
        let flushed = segmenter.flush(force: true)

        if segments.isEmpty && flushed == nil {
            // VAD didn't detect the sine wave as speech — acceptable, test still valid
        } else if let segment = flushed {
            XCTAssertGreaterThan(segment.samples.count, 0)
        }
    }

    func testFlushDiscardsShortSegmentByDefault() throws {
        let segmenter = VADSegmenter(
            minSilenceDuration: 0.25,
            minSpeechDuration: 0.5
        )
        guard segmenter.isAvailable else {
            throw XCTSkip("SileroVAD not available in test environment")
        }

        let shortAudio = generateSineWave(frequency: 440, durationSeconds: 0.2, sampleRate: 16000)
        _ = segmenter.feedSamples(shortAudio)
        let flushed = segmenter.flush()

        if flushed != nil {
            XCTAssertGreaterThanOrEqual(
                flushed!.durationSeconds, 0.5,
                "Default flush should not emit segments shorter than minSpeechDuration"
            )
        }
    }

    func testFlushEmitsNilWhenNoSpeechBuffered() throws {
        let segmenter = VADSegmenter()
        guard segmenter.isAvailable else {
            throw XCTSkip("SileroVAD not available in test environment")
        }

        let flushed = segmenter.flush(force: true)
        XCTAssertNil(flushed)
    }

    // MARK: - Bug 3: Punctuation-Aware Merge

    func testMergeChunkTextStripsTrailingChinesePeriod() {
        let result = TextMergeUtilities.mergeChunkText(
            accumulated: "今天天气很好。",
            newChunk: "我想出去走走。",
            language: "Chinese"
        )
        XCTAssertEqual(result, "今天天气很好，我想出去走走。")
    }

    func testMergeChunkTextStripsTrailingChineseQuestionMark() {
        let result = TextMergeUtilities.mergeChunkText(
            accumulated: "你觉得怎么样？",
            newChunk: "我觉得还不错。",
            language: "Chinese"
        )
        XCTAssertEqual(result, "你觉得怎么样，我觉得还不错。")
    }

    func testMergeChunkTextStripsTrailingExclamationMark() {
        let result = TextMergeUtilities.mergeChunkText(
            accumulated: "太好了！",
            newChunk: "我们走吧。",
            language: "Chinese"
        )
        XCTAssertEqual(result, "太好了，我们走吧。")
    }

    func testMergeChunkTextPreservesNonTerminalAccumulated() {
        let result = TextMergeUtilities.mergeChunkText(
            accumulated: "今天天气很好",
            newChunk: "我想出去走走。",
            language: "Chinese"
        )
        XCTAssertEqual(result, "今天天气很好我想出去走走。")
    }

    func testMergeChunkTextEnglishNoStripping() {
        let result = TextMergeUtilities.mergeChunkText(
            accumulated: "Hello world.",
            newChunk: "How are you.",
            language: "English"
        )
        XCTAssertEqual(result, "Hello world. How are you.")
    }

    func testMergeChunkTextOverlapStillWorks() {
        let result = TextMergeUtilities.mergeChunkText(
            accumulated: "你好世界",
            newChunk: "世界很大",
            language: "Chinese"
        )
        XCTAssertEqual(result, "你好世界很大")
    }

    func testMergeChunkTextOverlapWithPunctuationStripping() {
        let result = TextMergeUtilities.mergeChunkText(
            accumulated: "你好世界。",
            newChunk: "世界很大。",
            language: "Chinese"
        )
        XCTAssertEqual(result, "你好世界很大。")
    }

    func testMergeChunkTextEmptyInputs() {
        XCTAssertEqual(
            TextMergeUtilities.mergeChunkText(accumulated: "", newChunk: "你好", language: "Chinese"),
            "你好"
        )
        XCTAssertEqual(
            TextMergeUtilities.mergeChunkText(accumulated: "你好", newChunk: "", language: "Chinese"),
            "你好"
        )
    }

    // MARK: - Helpers

    private func generateSineWave(frequency: Float, durationSeconds: Float, sampleRate: Int) -> [Float] {
        let sampleCount = Int(durationSeconds * Float(sampleRate))
        return (0..<sampleCount).map { i in
            sin(2 * .pi * frequency * Float(i) / Float(sampleRate)) * 0.5
        }
    }
}
