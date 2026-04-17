// AudioMixerTests.swift
// OpenSuperMLXTests

import XCTest

@testable import OpenSuperMLX

final class AudioMixerTests: XCTestCase {

    // MARK: - Basic Mixing

    func testMixEqualSignalsDoubleAmplitude() {
        let mixer = AudioMixer(inputSampleRate: 16000)
        let signal: [Float] = (0..<1600).map { Float(sin(Double($0) * 2 * .pi * 440 / 16000)) * 0.4 }
        let result = mixer.mix(mic: signal, micSampleRate: 16000, sys: signal, sysSampleRate: 16000, outputSampleRate: 16000)
        XCTAssertFalse(result.isEmpty)
        let maxVal = result.max() ?? 0
        XCTAssertGreaterThan(maxVal, 0.4, "Mixed signal should be louder than individual")
    }

    // MARK: - Soft Saturation

    func testTanhSoftSaturationBoundsOutput() {
        let mixer = AudioMixer(inputSampleRate: 16000)
        let loud: [Float] = [Float](repeating: 0.9, count: 1600)
        let result = mixer.mix(mic: loud, micSampleRate: 16000, sys: loud, sysSampleRate: 16000, outputSampleRate: 16000)
        XCTAssertTrue(result.allSatisfy { $0 >= -1.0 && $0 <= 1.0 }, "tanh output must be within [-1, 1]")
    }

    func testTanhAvoidsFlatTopClipping() {
        let mixer = AudioMixer(inputSampleRate: 16000)
        let loud: [Float] = [Float](repeating: 0.9, count: 1600)
        let result = mixer.mix(mic: loud, micSampleRate: 16000, sys: loud, sysSampleRate: 16000, outputSampleRate: 16000)
        let atExactOne = result.filter { $0 == 1.0 || $0 == -1.0 }
        XCTAssertTrue(atExactOne.isEmpty, "tanh should never produce exactly ±1.0 (that's hard clipping)")
    }

    // MARK: - System Audio Peak Ceiling

    func testSystemAudioPeakCeilingPreventsClipping() {
        let mixer = AudioMixer(inputSampleRate: 16000)
        let mic: [Float] = [Float](repeating: 0.3, count: 1600)
        let loudSys: [Float] = [Float](repeating: 0.9, count: 1600)
        let result = mixer.mix(mic: mic, micSampleRate: 16000, sys: loudSys, sysSampleRate: 16000, outputSampleRate: 16000)
        let peak = result.map { abs($0) }.max() ?? 0
        XCTAssertLessThan(peak, 1.0, "Peak ceiling + tanh should prevent reaching 1.0")
    }

    // MARK: - Regression: System Audio Clipping

    func testSystemAudioDoesNotHardClip() {
        let mixer = AudioMixer(inputSampleRate: 44100)
        let mic: [Float] = (0..<4410).map { Float(sin(Double($0) * 2 * .pi * 440 / 44100)) * 0.2 }
        let sys: [Float] = (0..<4410).map { Float(sin(Double($0) * 2 * .pi * 1000 / 44100)) * 0.8 }

        var result = [Float]()
        for _ in 0..<10 {
            let chunk = mixer.mix(mic: mic, micSampleRate: 44100, sys: sys, sysSampleRate: 44100, outputSampleRate: 16000)
            result.append(contentsOf: chunk)
        }

        let hardClipped = result.filter { $0 == 1.0 || $0 == -1.0 }.count
        XCTAssertEqual(hardClipped, 0, "No samples should be hard-clipped at exactly ±1.0")
    }

    // MARK: - Regression: Sample Rate Mismatch Gaps

    func testDifferentSampleRatesProduceMatchingOutputLengths() {
        let mixer = AudioMixer(inputSampleRate: 48000)
        let mic48k: [Float] = (0..<4800).map { Float(sin(Double($0) * 2 * .pi * 440 / 48000)) * 0.3 }
        let sys44k: [Float] = (0..<4410).map { Float(sin(Double($0) * 2 * .pi * 1000 / 44100)) * 0.5 }

        let result = mixer.mix(mic: mic48k, micSampleRate: 48000, sys: sys44k, sysSampleRate: 44100, outputSampleRate: 16000)

        let expectedMicLength = Int(Double(4800) * 16000 / 48000)
        let expectedSysLength = Int(Double(4410) * 16000 / 44100)
        XCTAssertEqual(expectedMicLength, 1600)
        XCTAssertEqual(expectedSysLength, 1600)
        XCTAssertEqual(result.count, 1600, "Both sources at 100ms should produce 1600 samples at 16kHz")
    }

    func testMixedRateSamplesHaveNoSystematicSilenceGap() {
        let mixer = AudioMixer(inputSampleRate: 48000)
        let mic48k: [Float] = [Float](repeating: 0.2, count: 4800)
        let sys44k: [Float] = [Float](repeating: 0.3, count: 4410)

        let result = mixer.mix(mic: mic48k, micSampleRate: 48000, sys: sys44k, sysSampleRate: 44100, outputSampleRate: 16000)

        let lastQuarter = result[(result.count * 3 / 4)...]
        let minInLastQuarter = lastQuarter.map { abs($0) }.min() ?? 0
        XCTAssertGreaterThan(minInLastQuarter, 0.1, "Last quarter should not contain silence gaps from zero-padding")
    }

    // MARK: - Silence Passthrough

    func testSilencePassesThroughWithoutPops() {
        let mixer = AudioMixer(inputSampleRate: 16000)
        let silence = [Float](repeating: 0, count: 1600)
        let result = mixer.mix(mic: silence, micSampleRate: 16000, sys: silence, sysSampleRate: 16000, outputSampleRate: 16000)
        XCTAssertTrue(result.allSatisfy { $0 == 0 }, "Silent input should produce zeros (tanh(0)=0)")
    }

    // MARK: - Mic Only

    func testMicOnlyWhenNoSystemAudio() {
        let mixer = AudioMixer(inputSampleRate: 16000)
        let mic: [Float] = [Float](repeating: 0.3, count: 1600)
        let result = mixer.mix(mic: mic, micSampleRate: 16000, sys: [], sysSampleRate: 16000, outputSampleRate: 16000)
        XCTAssertEqual(result.count, 1600, "Empty sys should fallback to mic passthrough")
        XCTAssertTrue(result.allSatisfy { abs($0) > 0.1 }, "Passthrough should contain actual mic audio")
    }

    func testCarryOverRecoveryAfterFallback() {
        let mixer = AudioMixer(inputSampleRate: 16000)

        let longMic: [Float] = [Float](repeating: 0.3, count: 2000)
        let shortSys: [Float] = [Float](repeating: 0.4, count: 1600)
        let result1 = mixer.mix(mic: longMic, micSampleRate: 16000, sys: shortSys, sysSampleRate: 16000, outputSampleRate: 16000)
        XCTAssertEqual(result1.count, 1600, "Step 1: mix truncates to shorter, 400 mic samples in carry-over")

        let mic2: [Float] = [Float](repeating: 0.2, count: 1200)
        let result2 = mixer.mix(mic: mic2, micSampleRate: 16000, sys: [], sysSampleRate: 16000, outputSampleRate: 16000)
        XCTAssertEqual(result2.count, 1600, "Step 2: fallback returns 400 carry-over + 1200 new mic = 1600")
        XCTAssertTrue(result2.allSatisfy { abs($0) > 0.1 }, "Step 2: all samples should be real audio, not zeros")

        let mic3: [Float] = [Float](repeating: 0.25, count: 1600)
        let sys3: [Float] = [Float](repeating: 0.35, count: 1600)
        let result3 = mixer.mix(mic: mic3, micSampleRate: 16000, sys: sys3, sysSampleRate: 16000, outputSampleRate: 16000)
        XCTAssertEqual(result3.count, 1600, "Step 3: normal mix, no stale carry-over")
        let expectedMin = Float(tanh(0.25 + 0.35 * 0.7) - 0.05)
        XCTAssertTrue(result3.allSatisfy { $0 > expectedMin }, "Step 3: values should reflect tanh(mic+sys), not carry-over artifacts")
    }

    // MARK: - Downsampling

    func testDownsampleTo16kHz() {
        let mixer = AudioMixer(inputSampleRate: 44100)
        let signal: [Float] = (0..<4410).map { Float(sin(Double($0) * 2 * .pi * 440 / 44100)) * 0.5 }
        let result = mixer.micOnly(signal, inputSampleRate: 44100, outputSampleRate: 16000)
        let expectedLength = Int(Double(4410) * 16000 / 44100)
        XCTAssertEqual(result.count, expectedLength)
    }

    // MARK: - Carry-Over Buffer

    func testMismatchedLengthsUsesCarryOver() {
        let mixer = AudioMixer(inputSampleRate: 16000)
        let mic: [Float] = (0..<1600).map { Float(sin(Double($0) * 2 * .pi * 440 / 16000)) * 0.5 }
        let sys: [Float] = (0..<800).map { Float(sin(Double($0) * 2 * .pi * 440 / 16000)) * 0.5 }
        let result = mixer.mix(mic: mic, micSampleRate: 16000, sys: sys, sysSampleRate: 16000, outputSampleRate: 16000)
        XCTAssertEqual(result.count, 800, "Output length should match shorter input (carry-over stores excess)")
    }

    func testCarryOverAppliedToNextCycle() {
        let mixer = AudioMixer(inputSampleRate: 16000)
        let longMic: [Float] = [Float](repeating: 0.3, count: 2000)
        let shortSys: [Float] = [Float](repeating: 0.3, count: 1600)

        let result1 = mixer.mix(mic: longMic, micSampleRate: 16000, sys: shortSys, sysSampleRate: 16000, outputSampleRate: 16000)
        XCTAssertEqual(result1.count, 1600, "First call: output = min(2000, 1600) = 1600, carry-over = 400 mic samples")

        let equalMic: [Float] = [Float](repeating: 0.3, count: 1200)
        let equalSys: [Float] = [Float](repeating: 0.3, count: 1600)
        let result2 = mixer.mix(mic: equalMic, micSampleRate: 16000, sys: equalSys, sysSampleRate: 16000, outputSampleRate: 16000)
        XCTAssertEqual(result2.count, 1600, "Second call: mic = 400 carry-over + 1200 new = 1600, sys = 1600")
    }

    func testNoZeroPaddingInOutput() {
        let mixer = AudioMixer(inputSampleRate: 48000)
        let mic: [Float] = [Float](repeating: 0.2, count: 4800)
        let sys: [Float] = [Float](repeating: 0.3, count: 5760)

        let result = mixer.mix(mic: mic, micSampleRate: 48000, sys: sys, sysSampleRate: 48000, outputSampleRate: 16000)

        let exactZeros = result.filter { $0 == 0.0 }.count
        XCTAssertEqual(exactZeros, 0, "No zero-padded samples should exist in output when both sources have audio")
    }

    func testCarryOverPreventsAccumulation() {
        let mixer = AudioMixer(inputSampleRate: 48000)

        for _ in 0..<20 {
            let mic: [Float] = [Float](repeating: 0.2, count: 4800)
            let sys: [Float] = [Float](repeating: 0.3, count: 5760)
            let result = mixer.mix(mic: mic, micSampleRate: 48000, sys: sys, sysSampleRate: 48000, outputSampleRate: 16000)
            XCTAssertLessThan(result.count, 3200, "Output should stay bounded, carry-over should not accumulate indefinitely")
        }
    }

    func testResetClearsCarryOver() {
        let mixer = AudioMixer(inputSampleRate: 16000)
        let longMic: [Float] = [Float](repeating: 0.3, count: 2000)
        let shortSys: [Float] = [Float](repeating: 0.3, count: 1000)
        _ = mixer.mix(mic: longMic, micSampleRate: 16000, sys: shortSys, sysSampleRate: 16000, outputSampleRate: 16000)

        mixer.reset()

        let mic: [Float] = [Float](repeating: 0.3, count: 1600)
        let sys: [Float] = [Float](repeating: 0.3, count: 1600)
        let result = mixer.mix(mic: mic, micSampleRate: 16000, sys: sys, sysSampleRate: 16000, outputSampleRate: 16000)
        XCTAssertEqual(result.count, 1600, "After reset, no carry-over should affect output")
    }
}
