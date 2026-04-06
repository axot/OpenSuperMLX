// RMSNormalizerTests.swift
// OpenSuperMLXTests

import Accelerate
import XCTest
@testable import OpenSuperMLX

final class RMSNormalizerTests: XCTestCase {

    // MARK: - Silence

    func testSilenceRemainsZero() {
        let normalizer = RMSNormalizer()
        var samples = [Float](repeating: 0, count: 1000)
        normalizer.process(&samples)
        XCTAssertTrue(samples.allSatisfy { $0 == 0 })
    }

    // MARK: - Loud Signal

    func testLoudSignalAttenuated() {
        let normalizer = RMSNormalizer(targetRMS: 0.126)
        var samples = (0..<4410).map { Float(sin(Double($0) * 2 * .pi * 440 / 44100)) * 0.9 }
        for _ in 0..<10 {
            normalizer.process(&samples)
        }
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        XCTAssertLessThan(rms, 0.9, "Loud signal should be attenuated")
    }

    // MARK: - Quiet Signal

    func testQuietSignalBoosted() {
        let normalizer = RMSNormalizer(targetRMS: 0.126)
        var samples = (0..<4410).map { Float(sin(Double($0) * 2 * .pi * 440 / 44100)) * 0.01 }
        let originalRMS = computeRMS(samples)
        for _ in 0..<20 {
            normalizer.process(&samples)
        }
        let boostedRMS = computeRMS(samples)
        XCTAssertGreaterThan(boostedRMS, originalRMS, "Quiet signal should be boosted")
    }

    // MARK: - Gain Limit

    func testGainLimitRespected() {
        let normalizer = RMSNormalizer(targetRMS: 0.126, maxGainDB: 24)
        var samples = [Float](repeating: 0.0001, count: 4410)
        for _ in 0..<50 {
            normalizer.process(&samples)
        }
        let maxGainLinear = pow(Float(10), 24.0 / 20.0)
        XCTAssertLessThanOrEqual(normalizer.smoothedGain, maxGainLinear + 0.01)
    }

    // MARK: - Reset

    func testResetRestoresGain() {
        let normalizer = RMSNormalizer()
        var samples = (0..<1000).map { Float(sin(Double($0) * 2 * .pi * 440 / 44100)) * 0.5 }
        normalizer.process(&samples)
        normalizer.reset()
        XCTAssertEqual(normalizer.smoothedGain, 1.0)
    }

    // MARK: - Empty Input

    func testEmptyInputNoOp() {
        let normalizer = RMSNormalizer()
        var samples = [Float]()
        normalizer.process(&samples)
        XCTAssertEqual(normalizer.smoothedGain, 1.0)
    }

    // MARK: - Helpers

    private func computeRMS(_ samples: [Float]) -> Float {
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        return rms
    }
}
