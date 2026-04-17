// AudioMixer.swift
// OpenSuperMLX

import Accelerate
import Foundation

/// Not thread-safe — must be called from a single serial context (the feed loop's Task.detached).
final class AudioMixer: @unchecked Sendable {
    private let sysAGC: RMSNormalizer
    private static let sysPeakCeiling: Float = 0.7
    private static let systemAudioRate: Double = 48000
    private var traceFile: FileHandle?
    private var traceCounter = 0
    private var micCarryOver = [Float]()
    private var sysCarryOver = [Float]()

    init(inputSampleRate: Double = 48000) {
        sysAGC = RMSNormalizer(maxGainDB: 12, sampleRate: Float(inputSampleRate))
    }

    func startTrace(url: URL) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        traceFile = FileHandle(forWritingAtPath: url.path)
        traceCounter = 0
    }

    func stopTrace() {
        traceFile?.closeFile()
        traceFile = nil
    }

    private func trace(_ msg: String) {
        traceFile?.write(Data((msg + "\n").utf8))
    }

    private func peak(_ arr: [Float]) -> Float {
        arr.isEmpty ? 0 : arr.reduce(Float(0)) { max($0, abs($1)) }
    }

    private func rms(_ arr: [Float]) -> Float {
        arr.isEmpty ? 0 : sqrt(arr.reduce(Float(0)) { $0 + $1 * $1 } / Float(arr.count))
    }

    func mix(mic: [Float], micSampleRate: Double, sys: [Float], sysSampleRate: Double = systemAudioRate,
             outputSampleRate: Double = 16000) -> [Float] {

        traceCounter += 1
        let n = traceCounter
        let t = traceFile != nil

        if t { trace("MIX-\(n) IN mic=\(mic.count) sys=\(sys.count)") }

        var sysProcessed = sys
        if !sysProcessed.isEmpty {
            sysAGC.process(&sysProcessed)

            var sysLower: Float = -Self.sysPeakCeiling
            var sysUpper: Float = Self.sysPeakCeiling
            vDSP_vclip(sysProcessed, 1, &sysLower, &sysUpper, &sysProcessed, 1, vDSP_Length(sysProcessed.count))
        }

        var mic16k = downsample(mic, from: micSampleRate, to: outputSampleRate)
        var sys16k = downsample(sysProcessed, from: sysSampleRate, to: outputSampleRate)

        if !micCarryOver.isEmpty {
            mic16k = micCarryOver + mic16k
            micCarryOver.removeAll(keepingCapacity: true)
        }
        if !sysCarryOver.isEmpty {
            sys16k = sysCarryOver + sys16k
            sysCarryOver.removeAll(keepingCapacity: true)
        }

        let mixLen = min(mic16k.count, sys16k.count)
        if mixLen == 0 {
            if !mic16k.isEmpty { return mic16k }
            if !sys16k.isEmpty { return sys16k }
            return []
        }

        if mic16k.count > mixLen {
            micCarryOver = Array(mic16k[mixLen...])
            mic16k = Array(mic16k[..<mixLen])
        }
        if sys16k.count > mixLen {
            sysCarryOver = Array(sys16k[mixLen...])
            sys16k = Array(sys16k[..<mixLen])
        }

        if t { trace("MIX-\(n) ALIGN mic16k=\(mic16k.count) sys16k=\(sys16k.count) micCO=\(micCarryOver.count) sysCO=\(sysCarryOver.count)") }

        var mixed = [Float](repeating: 0, count: mixLen)
        vDSP_vadd(mic16k, 1, sys16k, 1, &mixed, 1, vDSP_Length(mixLen))

        var count = Int32(mixLen)
        vvtanhf(&mixed, mixed, &count)

        if t { trace("MIX-\(n) OUT n=\(mixed.count) pk=\(peak(mixed)) rms=\(rms(mixed))") }

        return mixed
    }

    func micOnly(_ samples: [Float], inputSampleRate: Double, outputSampleRate: Double = 16000) -> [Float] {
        downsample(samples, from: inputSampleRate, to: outputSampleRate)
    }

    func reset() {
        sysAGC.reset()
        micCarryOver.removeAll()
        sysCarryOver.removeAll()
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
