//
//  StreamingAudioServiceRMSTests.swift
//  OpenSuperMLXTests
//
//  Tests the pure StreamingAudioService.computeRMS helper used by the
//  recording-dock VU meter. Timer/threading verified manually.
//

import AVFoundation
import XCTest
@testable import OpenSuperMLX

final class StreamingAudioServiceRMSTests: XCTestCase {

    private func makeBuffer(_ samples: [Float], sampleRate: Double = 16000) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, samples.count)))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if !samples.isEmpty {
            memcpy(buffer.floatChannelData![0], samples, samples.count * MemoryLayout<Float>.size)
        }
        return buffer
    }

    func testSilenceReturnsZero() {
        let buffer = makeBuffer([Float](repeating: 0, count: 512))
        XCTAssertEqual(StreamingAudioService.computeRMS(buffer), 0, accuracy: 1e-6)
    }

    func testConstantAmplitudeReturnsThatAmplitude() {
        let buffer = makeBuffer([Float](repeating: 0.5, count: 1000))
        XCTAssertEqual(StreamingAudioService.computeRMS(buffer), 0.5, accuracy: 1e-5)
    }

    func testClippingIsClampedToOne() {
        // RMS of constant 2.0 is 2.0 before clamp; must clamp to 1.0.
        let buffer = makeBuffer([Float](repeating: 2.0, count: 256))
        XCTAssertEqual(StreamingAudioService.computeRMS(buffer), 1.0, accuracy: 1e-6)
    }

    func testEmptyBufferReturnsZero() {
        let buffer = makeBuffer([])
        XCTAssertEqual(StreamingAudioService.computeRMS(buffer), 0, accuracy: 1e-6)
    }

    func testMixedAmplitudeMatchesManualRMS() {
        let samples: [Float] = [1.0, -1.0, 0.0, 0.0]
        // sqrt((1 + 1 + 0 + 0) / 4) = sqrt(0.5) ≈ 0.70710678
        XCTAssertEqual(StreamingAudioService.computeRMS(makeBuffer(samples)), 0.7071068, accuracy: 1e-5)
    }

    // MARK: - Duration resolution (mini-recorder duration=0 regression)

    func testResolveDurationPrefersMeasured() {
        // Measured session duration wins even when a caller passes its own value.
        XCTAssertEqual(StreamingAudioService.resolveDuration(measured: 8.0, caller: 0), 8.0, accuracy: 1e-9)
        XCTAssertEqual(StreamingAudioService.resolveDuration(measured: 8.0, caller: 3.0), 8.0, accuracy: 1e-9)
    }

    func testResolveDurationFallsBackToCallerWhenUnmeasured() {
        // No measured duration (no session start time) → use the caller's value.
        XCTAssertEqual(StreamingAudioService.resolveDuration(measured: 0, caller: 5.0), 5.0, accuracy: 1e-9)
    }

    func testResolveDurationNeverNegative() {
        XCTAssertEqual(StreamingAudioService.resolveDuration(measured: 0, caller: -2), 0, accuracy: 1e-9)
    }
}
