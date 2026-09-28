// IncrementalMelSpectrogramTests.swift
// OpenSuperMLXTests

import XCTest

import MLX
import MLXAudioCore
@testable import MLXAudioSTT

final class IncrementalMelSpectrogramTests: XCTestCase {

    // MARK: - Parity With The MLX Implementation

    func testMatchesMLXReferenceAcrossUnevenPieces() {
        let pieces = [1600, 800, 3200, 57, 1600, 4000]
        let signal = Self.speechLikeSignal(samples: pieces.reduce(0, +))

        assertSameFrames(pieces: Self.split(signal, into: pieces), flush: true)
    }

    func testSilenceMatchesMLXReference() {
        assertSameFrames(pieces: [[Float](repeating: 0, count: 3200)], flush: true)
    }

    func testShortPiecesAreBufferedLikeMLXReference() {
        let pieces = [100, 150, 300, 1000]
        let signal = Self.speechLikeSignal(samples: pieces.reduce(0, +))

        assertSameFrames(pieces: Self.split(signal, into: pieces), flush: false)
    }

    // MARK: - Buffering

    func testPieceShorterThanOneFrameIsBuffered() {
        let signal = Self.speechLikeSignal(samples: 2000)
        let mel = IncrementalMelSpectrogram()

        XCTAssertNil(mel.process(samples: Array(signal[0..<100])))
        XCTAssertEqual(mel.process(samples: Array(signal[100..<1100]))?.shape, [6, 128])
        XCTAssertNil(mel.process(samples: Array(signal[1100..<1150])))
        XCTAssertEqual(mel.process(samples: Array(signal[1150..<2000]))?.shape, [6, 128])
        XCTAssertEqual(IncrementalMelSpectrogram().process(samples: signal)?.shape, [12, 128])
    }

    func testResetStartsAFreshSession() {
        let first = Self.speechLikeSignal(samples: 4000)
        let second = Array(Self.speechLikeSignal(samples: 8000).suffix(3000))
        let reused = IncrementalMelSpectrogram()
        _ = reused.process(samples: first)
        reused.reset()

        let afterReset = reused.process(samples: second)
        let fresh = IncrementalMelSpectrogram().process(samples: second)

        XCTAssertEqual(afterReset?.asArray(Float.self), fresh?.asArray(Float.self))
    }

    // MARK: - Helpers

    private func assertSameFrames(pieces: [[Float]], flush: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let mel = IncrementalMelSpectrogram()
        let reference = MLXReferenceMel()
        var outputs = pieces.map { (mel.process(samples: $0), reference.process(samples: $0)) }
        if flush {
            outputs.append((mel.flush(), reference.flush()))
        }
        for (actual, expected) in outputs {
            XCTAssertEqual(actual?.shape, expected?.shape, file: file, line: line)
            guard let actual, let expected, actual.shape == expected.shape else { continue }
            // Float32 DFT and FFT round differently; 1e-3 stays well below the bfloat16 resolution
            // (about 4e-3 near 1.0) of the audio tower that consumes these frames.
            let difference = abs(actual - expected).max().item(Float.self)
            XCTAssertLessThan(difference, 1e-3, file: file, line: line)
        }
    }

    private static func split(_ signal: [Float], into counts: [Int]) -> [[Float]] {
        var start = 0
        return counts.map { count in
            defer { start += count }
            return Array(signal[start..<(start + count)])
        }
    }

    private static func speechLikeSignal(samples: Int) -> [Float] {
        var state: UInt32 = 12345
        return (0..<samples).map { i in
            state = state &* 1_664_525 &+ 1_013_904_223
            let noise = Float(state >> 8) / Float(1 << 24) - 0.5
            let t = Float(i) / 16000
            let envelope = 0.5 + 0.5 * sin(2 * .pi * 3 * t)
            let voiced = 0.3 * sin(2 * .pi * 220 * t) + 0.2 * sin(2 * .pi * 660 * t) + 0.1 * sin(2 * .pi * 1760 * t)
            return envelope * voiced + 0.01 * noise
        }
    }
}

// MARK: - MLX Reference

/// The MLX implementation IncrementalMelSpectrogram used before it moved to Accelerate, with the frame
/// count fixed for signals shorter than one FFT window.
private final class MLXReferenceMel {
    private let nFft = 400
    private let hopLength = 160
    private let window = hanningWindow(size: 400)
    private let filters = melFilters(sampleRate: 16000, nFft: 400, nMels: 128, norm: "slaney", melScale: .slaney)
    private var overlapBuffer: [Float] = []
    private var isFirstChunk = true
    private var runningLogMax = -Float.infinity

    func process(samples: [Float]) -> MLXArray? {
        guard !samples.isEmpty else { return nil }
        let signal: [Float]
        if isFirstChunk {
            let padSize = nFft / 2
            var prefix: [Float] = []
            if samples.count > 1 {
                let reflectLen = min(padSize, samples.count - 1)
                if reflectLen > 0 { prefix = Array(samples[1...reflectLen].reversed()) }
            }
            if prefix.isEmpty {
                prefix = [Float](repeating: samples.first ?? 0, count: padSize)
            } else {
                while prefix.count < padSize { prefix.append(contentsOf: prefix.prefix(padSize - prefix.count)) }
            }
            signal = prefix + samples
            isFirstChunk = false
        } else {
            signal = overlapBuffer + samples
        }
        let numFrames = signal.count >= nFft ? (signal.count - nFft) / hopLength + 1 : 0
        guard numFrames > 0 else {
            overlapBuffer = signal
            return nil
        }
        let consumed = (numFrames - 1) * hopLength + nFft
        overlapBuffer = consumed < signal.count
            ? Array(signal[(consumed - (nFft - hopLength))...]) : Array(signal.suffix(nFft - hopLength))
        return logMel(signal, numFrames)
    }

    func flush() -> MLXArray? {
        guard !overlapBuffer.isEmpty else { return nil }
        var signal = overlapBuffer
        if signal.count < nFft { signal += [Float](repeating: 0, count: nFft - signal.count) }
        let reflectLen = min(nFft / 2, signal.count - 1)
        signal += Array(signal[(signal.count - 1 - reflectLen)..<(signal.count - 1)].reversed())
        overlapBuffer = []
        let numFrames = max(0, (signal.count - nFft) / hopLength + 1)
        return numFrames > 0 ? logMel(signal, numFrames) : nil
    }

    private func logMel(_ signal: [Float], _ numFrames: Int) -> MLXArray {
        let frames = asStrided(MLXArray(signal), [numFrames, nFft], strides: [hopLength, 1], offset: 0)
        let magnitudes = MLX.abs(MLXFFT.rfft(frames * window, axis: 1)).square()
        var melSpec = MLX.log10(MLX.maximum(MLX.matmul(magnitudes, filters), MLXArray(Float(1e-10))))
        runningLogMax = max(runningLogMax, melSpec.max().item(Float.self))
        melSpec = MLX.maximum(melSpec, MLXArray(runningLogMax - 8.0))
        return (melSpec + MLXArray(Float(4.0))) / MLXArray(Float(4.0))
    }
}
