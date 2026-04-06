// AudioMixer.swift
// OpenSuperMLX

import Accelerate
import Foundation

final class AudioMixer: @unchecked Sendable {
    private let sysAGC: RMSNormalizer
    private let silenceThreshold: Float = 0.001

    init(inputSampleRate: Double = 44100) {
        sysAGC = RMSNormalizer(sampleRate: Float(inputSampleRate))
    }

    func mix(mic: [Float], sys: [Float], inputSampleRate: Double, outputSampleRate: Double = 16000) -> [Float] {
        let length = max(mic.count, sys.count)
        guard length > 0 else { return [] }

        var micPadded = mic.count < length
            ? mic + [Float](repeating: 0, count: length - mic.count)
            : mic
        var sysPadded = sys.count < length
            ? sys + [Float](repeating: 0, count: length - sys.count)
            : sys

        sysAGC.process(&sysPadded)

        var mixed = [Float](repeating: 0, count: length)
        vDSP_vadd(micPadded, 1, sysPadded, 1, &mixed, 1, vDSP_Length(length))

        var minVal: Float = -1.0
        var maxVal: Float = 1.0
        vDSP_vclip(mixed, 1, &minVal, &maxVal, &mixed, 1, vDSP_Length(length))

        var rms: Float = 0
        vDSP_rmsqv(mixed, 1, &rms, vDSP_Length(length))
        if rms < silenceThreshold {
            let outputLength = Int(Double(length) * outputSampleRate / inputSampleRate)
            return [Float](repeating: 0, count: max(outputLength, 0))
        }

        return downsample(mixed, from: inputSampleRate, to: outputSampleRate)
    }

    func micOnly(_ samples: [Float], inputSampleRate: Double, outputSampleRate: Double = 16000) -> [Float] {
        downsample(samples, from: inputSampleRate, to: outputSampleRate)
    }

    func reset() {
        sysAGC.reset()
    }

    // MARK: - Downsampling

    private func downsample(_ samples: [Float], from srcRate: Double, to dstRate: Double) -> [Float] {
        guard srcRate != dstRate, !samples.isEmpty else { return samples }
        let ratio = dstRate / srcRate
        let outputLength = Int(Double(samples.count) * ratio)
        guard outputLength > 0 else { return [] }

        var result = [Float](repeating: 0, count: outputLength)
        for i in 0..<outputLength {
            let srcIndex = Double(i) / ratio
            let lower = Int(srcIndex)
            let frac = Float(srcIndex - Double(lower))
            let upper = min(lower + 1, samples.count - 1)
            result[i] = samples[lower] * (1 - frac) + samples[upper] * frac
        }
        return result
    }
}
