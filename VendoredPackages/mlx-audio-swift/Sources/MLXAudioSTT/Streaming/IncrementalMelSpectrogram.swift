//
//  IncrementalMelSpectrogram.swift
//  MLXAudioSTT
//
//  Created by Prince Canuma on 07/02/2026.
//

import Accelerate
import Foundation
import MLX
import MLXAudioCore
import os

private let melLogger = Logger(subsystem: "MLXAudioSTT", category: "MelSpectrogram")

/// Computes mel spectrograms incrementally using an overlap-save approach.
///
/// Maintains a rolling buffer of `nFft - hopLength` samples between calls
/// so that STFT frames spanning chunk boundaries are computed correctly.
/// The first chunk uses reflect padding at the start; subsequent chunks
/// overlap with the tail of the previous chunk.
///
/// The spectrum is computed on the CPU with Accelerate as two small matrix multiplies (a windowed
/// DFT, then the mel filterbank), so feeding audio never wakes the GPU between decoder chunks.
public class IncrementalMelSpectrogram {
    private let nFft: Int
    private let hopLength: Int
    private let nMels: Int
    private let sampleRate: Int
    private let frequencyBins: Int

    /// Overlap samples kept between chunks
    private let overlapSize: Int

    /// `[nFft, 2 * frequencyBins]`: real then imaginary DFT bases with the Hann window folded in.
    private let windowedDFT: [Float]
    /// `[frequencyBins, nMels]`
    private let filters: [Float]

    /// Rolling buffer of leftover samples from previous chunk
    private var overlapBuffer: [Float] = []

    /// Whether this is the first chunk (needs reflect padding)
    private var isFirstChunk: Bool = true

    /// Running max for log normalization (grows monotonically)
    private var runningLogMax: Float = -Float.infinity

    /// Total mel frames produced so far
    private(set) var totalFrames: Int = 0

    public init(
        sampleRate: Int = 16000,
        nFft: Int = 400,
        hopLength: Int = 160,
        nMels: Int = 128
    ) {
        self.sampleRate = sampleRate
        self.nFft = nFft
        self.hopLength = hopLength
        self.nMels = nMels
        self.overlapSize = nFft - hopLength

        let bins = nFft / 2 + 1
        let window = hanningWindow(size: nFft).asArray(Float.self)
        var basis = [Float](repeating: 0, count: nFft * 2 * bins)
        for n in 0..<nFft {
            for k in 0..<bins {
                let angle = 2 * Double.pi * Double((k * n) % nFft) / Double(nFft)
                basis[n * 2 * bins + k] = Float(cos(angle)) * window[n]
                basis[n * 2 * bins + bins + k] = Float(-sin(angle)) * window[n]
            }
        }
        self.frequencyBins = bins
        self.windowedDFT = basis
        self.filters = melFilters(
            sampleRate: sampleRate,
            nFft: nFft,
            nMels: nMels,
            norm: "slaney",
            melScale: .slaney
        ).asArray(Float.self)
    }

    /// Process new audio samples and return new mel frames.
    ///
    /// - Parameter samples: Raw audio samples as Float array
    /// - Returns: Mel spectrogram frames `[newFrames, nMels]`, or nil if not enough samples
    public func process(samples: [Float]) -> MLXArray? {
        guard !samples.isEmpty else { return nil }

        let signal: [Float]

        if isFirstChunk {
            // Reflect padding at the start (nFft/2 samples)
            let padSize = nFft / 2
            var prefix: [Float] = []
            if samples.count > 1 {
                let reflectLen = min(padSize, samples.count - 1)
                if reflectLen > 0 {
                    prefix = Array(samples[1...reflectLen].reversed())
                }
            }

            if prefix.isEmpty {
                let fill = samples.first ?? 0
                prefix = [Float](repeating: fill, count: padSize)
            } else if prefix.count < padSize {
                // If samples are shorter than padSize, repeat the reflected prefix
                while prefix.count < padSize {
                    let needed = padSize - prefix.count
                    prefix.append(contentsOf: prefix.prefix(needed))
                }
            }
            signal = prefix + samples
            isFirstChunk = false
        } else {
            // Prepend overlap from previous chunk
            signal = overlapBuffer + samples
        }

        // Calculate how many complete frames we can compute
        let numFrames = frameCount(signalLength: signal.count)
        guard numFrames > 0 else {
            // Not enough samples yet - save everything as overlap
            overlapBuffer = signal
            return nil
        }

        // Save leftover samples for next chunk
        let consumedSamples = (numFrames - 1) * hopLength + nFft
        if consumedSamples < signal.count {
            overlapBuffer = Array(signal[(consumedSamples - overlapSize)...])
        } else {
            overlapBuffer = Array(signal.suffix(overlapSize))
        }

        return logMel(signal: signal, numFrames: numFrames)
    }

    /// Process remaining samples at session end.
    /// Pads with zeros to fill the last frame if needed.
    public func flush() -> MLXArray? {
        guard !overlapBuffer.isEmpty else { return nil }

        // Pad with zeros to make at least one frame
        let needed = nFft
        var signal = overlapBuffer
        if signal.count < needed {
            signal += [Float](repeating: 0, count: needed - signal.count)
        }

        // Add reflect padding at the end
        let padSize = nFft / 2
        let signalLen = signal.count
        let reflectLen = min(padSize, signalLen - 1)
        let suffix = Array(signal[(signalLen - 1 - reflectLen)..<(signalLen - 1)].reversed())
        signal += suffix

        overlapBuffer = []

        let numFrames = frameCount(signalLength: signal.count)
        guard numFrames > 0 else { return nil }

        return logMel(signal: signal, numFrames: numFrames)
    }

    /// Reset state for a new session.
    public func reset() {
        overlapBuffer = []
        isFirstChunk = true
        runningLogMax = -Float.infinity
        totalFrames = 0
    }

    private func frameCount(signalLength: Int) -> Int {
        signalLength >= nFft ? (signalLength - nFft) / hopLength + 1 : 0
    }

    private func logMel(signal: [Float], numFrames: Int) -> MLXArray {
        let spectrumWidth = 2 * frequencyBins
        var frames = [Float](repeating: 0, count: numFrames * nFft)
        for frame in 0..<numFrames {
            let start = frame * hopLength
            frames.replaceSubrange(frame * nFft..<(frame + 1) * nFft, with: signal[start..<(start + nFft)])
        }

        var spectrum = [Float](repeating: 0, count: numFrames * spectrumWidth)
        vDSP_mmul(
            frames, 1, windowedDFT, 1, &spectrum, 1,
            vDSP_Length(numFrames), vDSP_Length(spectrumWidth), vDSP_Length(nFft)
        )

        var power = [Float](repeating: 0, count: numFrames * frequencyBins)
        spectrum.withUnsafeMutableBufferPointer { spectrumBuffer in
            power.withUnsafeMutableBufferPointer { powerBuffer in
                for frame in 0..<numFrames {
                    let row = spectrumBuffer.baseAddress! + frame * spectrumWidth
                    var bins = DSPSplitComplex(realp: row, imagp: row + frequencyBins)
                    vDSP_zvmags(
                        &bins, 1, powerBuffer.baseAddress! + frame * frequencyBins, 1,
                        vDSP_Length(frequencyBins)
                    )
                }
            }
        }

        let count = numFrames * nMels
        var melSpec = [Float](repeating: 0, count: count)
        vDSP_mmul(
            power, 1, filters, 1, &melSpec, 1,
            vDSP_Length(numFrames), vDSP_Length(nMels), vDSP_Length(frequencyBins)
        )

        melSpec.withUnsafeMutableBufferPointer { buffer in
            let values = buffer.baseAddress!
            let length = vDSP_Length(count)
            var powerFloor: Float = 1e-10
            vDSP_vthr(values, 1, &powerFloor, values, 1, length)
            var elementCount = Int32(count)
            vvlog10f(values, values, &elementCount)

            var chunkMax: Float = 0
            vDSP_maxv(values, 1, &chunkMax, length)
            let prevMax = runningLogMax
            runningLogMax = max(runningLogMax, chunkMax)
            if runningLogMax != prevMax {
                melLogger.info("runningLogMax changed: \(prevMax) → \(self.runningLogMax) (chunkMax=\(chunkMax)) totalFrames=\(self.totalFrames)")
            }

            var logFloor = runningLogMax - 8.0
            vDSP_vthr(values, 1, &logFloor, values, 1, length)
            var four: Float = 4.0
            vDSP_vsadd(values, 1, &four, values, 1, length)
            vDSP_vsdiv(values, 1, &four, values, 1, length)
        }

        totalFrames += numFrames
        return MLXArray(melSpec, [numFrames, nMels])  // [numFrames, nMels]
    }
}
