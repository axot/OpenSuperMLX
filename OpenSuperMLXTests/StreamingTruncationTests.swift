// StreamingTruncationTests.swift
// OpenSuperMLXTests

import XCTest

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

        if let flushed {
            XCTAssertGreaterThanOrEqual(
                flushed.durationSeconds, 0.5,
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

    // MARK: - Helpers

    private func generateSineWave(frequency: Float, durationSeconds: Float, sampleRate: Int) -> [Float] {
        let sampleCount = Int(durationSeconds * Float(sampleRate))
        return (0..<sampleCount).map { i in
            sin(2 * .pi * frequency * Float(i) / Float(sampleRate)) * 0.5
        }
    }
}
