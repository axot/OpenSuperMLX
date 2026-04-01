// EncoderWindowCache.swift
// MLXAudioSTT

import Foundation
import MLX

// MARK: - CachedWindow

struct CachedWindow {
    let encoderOutput: MLXArray
    let seqLen: Int
    let startMelFrame: Int
}

// MARK: - EncoderWindowCache

struct EncoderWindowCache {
    let maxWindows: Int
    let windowSizeMelFrames: Int

    private(set) var windows: [CachedWindow] = []

    init(maxWindows: Int = 4, windowSizeMelFrames: Int = 800) {
        self.maxWindows = maxWindows
        self.windowSizeMelFrames = windowSizeMelFrames
    }

    var count: Int { windows.count }

    var isEmpty: Bool { windows.isEmpty }

    var totalSeqLen: Int { windows.reduce(0) { $0 + $1.seqLen } }

    mutating func addWindow(_ window: CachedWindow) {
        if windows.count >= maxWindows {
            windows.removeFirst()
        }
        windows.append(window)
    }

    mutating func clear() {
        windows.removeAll()
    }

    func concatenatedOutput() -> MLXArray? {
        guard !windows.isEmpty else { return nil }
        let outputs = windows.map { $0.encoderOutput }
        return MLX.concatenated(outputs, axis: 0)
    }
}
