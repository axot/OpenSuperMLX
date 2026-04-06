// AudioMixerTests.swift
// OpenSuperMLXTests

import Accelerate
import XCTest

@testable import OpenSuperMLX

final class AudioMixerTests: XCTestCase {

    // MARK: - Basic Mixing

    func testMixEqualSignalsDoubleAmplitude() {
        let mixer = AudioMixer(inputSampleRate: 16000)
        let signal: [Float] = (0..<1600).map { Float(sin(Double($0) * 2 * .pi * 440 / 16000)) * 0.4 }
        let result = mixer.mix(mic: signal, sys: signal, inputSampleRate: 16000, outputSampleRate: 16000)
        XCTAssertFalse(result.isEmpty)
        let maxVal = result.max() ?? 0
        XCTAssertGreaterThan(maxVal, 0.4, "Mixed signal should be louder than individual")
    }

    // MARK: - Clipping

    func testHardClipAtPlusMinusOne() {
        let mixer = AudioMixer(inputSampleRate: 16000)
        let loud: [Float] = [Float](repeating: 0.9, count: 1600)
        let result = mixer.mix(mic: loud, sys: loud, inputSampleRate: 16000, outputSampleRate: 16000)
        XCTAssertTrue(result.allSatisfy { $0 >= -1.0 && $0 <= 1.0 }, "All samples must be clipped to [-1, 1]")
    }

    // MARK: - Mic Only

    func testMicOnlyWhenNoSystemAudio() {
        let mixer = AudioMixer(inputSampleRate: 16000)
        let mic: [Float] = (0..<1600).map { Float(sin(Double($0) * 2 * .pi * 440 / 16000)) * 0.5 }
        let result = mixer.mix(mic: mic, sys: [], inputSampleRate: 16000, outputSampleRate: 16000)
        XCTAssertFalse(result.isEmpty)
    }

    // MARK: - Silence Gate

    func testSilenceGateBlocksSilence() {
        let mixer = AudioMixer(inputSampleRate: 16000)
        let silence = [Float](repeating: 0, count: 1600)
        let result = mixer.mix(mic: silence, sys: silence, inputSampleRate: 16000, outputSampleRate: 16000)
        XCTAssertTrue(result.allSatisfy { $0 == 0 }, "Silent input should produce zeros")
    }

    // MARK: - Downsampling

    func testDownsampleTo16kHz() {
        let mixer = AudioMixer(inputSampleRate: 44100)
        let signal: [Float] = (0..<4410).map { Float(sin(Double($0) * 2 * .pi * 440 / 44100)) * 0.5 }
        let result = mixer.micOnly(signal, inputSampleRate: 44100, outputSampleRate: 16000)
        let expectedLength = Int(Double(4410) * 16000 / 44100)
        XCTAssertEqual(result.count, expectedLength)
    }

    // MARK: - Mismatched Lengths

    func testMismatchedLengthsPadsShorter() {
        let mixer = AudioMixer(inputSampleRate: 16000)
        let mic: [Float] = (0..<1600).map { Float(sin(Double($0) * 2 * .pi * 440 / 16000)) * 0.5 }
        let sys: [Float] = (0..<800).map { Float(sin(Double($0) * 2 * .pi * 440 / 16000)) * 0.5 }
        let result = mixer.mix(mic: mic, sys: sys, inputSampleRate: 16000, outputSampleRate: 16000)
        XCTAssertEqual(result.count, 1600, "Output length should match longer input")
    }
}
