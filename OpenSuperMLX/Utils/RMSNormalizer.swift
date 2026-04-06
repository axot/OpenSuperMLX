// RMSNormalizer.swift
// OpenSuperMLX

import Accelerate
import Foundation

final class RMSNormalizer: @unchecked Sendable {
    private let targetRMS: Float
    private let attackCoeff: Float
    private let releaseCoeff: Float
    private let maxGain: Float
    private let minGain: Float
    private(set) var smoothedGain: Float = 1.0

    init(targetRMS: Float = 0.126, attackMs: Float = 15, releaseMs: Float = 200,
         maxGainDB: Float = 24, sampleRate: Float = 44100) {
        self.targetRMS = targetRMS
        self.attackCoeff = 1.0 - exp(-1.0 / (attackMs * 0.001 * sampleRate))
        self.releaseCoeff = 1.0 - exp(-1.0 / (releaseMs * 0.001 * sampleRate))
        self.maxGain = pow(10, maxGainDB / 20)
        self.minGain = pow(10, -maxGainDB / 20)
    }

    func process(_ samples: inout [Float]) {
        guard !samples.isEmpty else { return }
        var sumSquares: Float = 0
        vDSP_svesq(samples, 1, &sumSquares, vDSP_Length(samples.count))
        let rms = sqrt(sumSquares / Float(samples.count))
        guard rms > 1e-8 else { return }

        let desiredGain = min(max(targetRMS / rms, minGain), maxGain)
        let baseCoeff = desiredGain > smoothedGain ? attackCoeff : releaseCoeff
        let effectiveCoeff = 1.0 - pow(1.0 - baseCoeff, Float(samples.count))
        smoothedGain += effectiveCoeff * (desiredGain - smoothedGain)

        var gain = smoothedGain
        vDSP_vsmul(samples, 1, &gain, &samples, 1, vDSP_Length(samples.count))
    }

    func reset() { smoothedGain = 1.0 }
}
