//
//  VADSegmenter.swift
//  MLXAudioSTT
//

import Foundation
import os

import SileroVAD

// MARK: - SpeechSegment

public struct SpeechSegment: Sendable {
    public let samples: [Float]
    public var durationSeconds: Float { Float(samples.count) / Float(SileroVAD.sampleRate) }
}

// MARK: - VADSegmenter

/// Wraps SileroVAD to accumulate speech samples and emit complete segments on pause.
///
/// Feed raw 16kHz PCM in any chunk size. Internally buffers to 576-sample
/// boundaries, runs Silero VAD on each frame, accumulates speech samples,
/// and emits `SpeechSegment` when silence exceeds `minSilenceDuration`.
public final class VADSegmenter {
    private static let logger = Logger(subsystem: "MLXAudioSTT", category: "VADSegmenter")

    let minSilenceDuration: Float
    let minSpeechDuration: Float
    let maxSpeechDuration: Float
    let threshold: Float

    private var vad: SileroVAD?
    private var carryBuffer: [Float] = []
    private var speechBuffer: [Float] = []
    private var silenceFrameCount: Int = 0

    /// Rolling buffer of recent VAD frames for pre-speech lookback (288ms = 8 × 36ms frames).
    private var preSpeechBuffer: [[Float]] = []
    private let maxLookbackFrames: Int = 8

    /// Whether VAD loaded successfully and is ready for use.
    public var isAvailable: Bool { vad != nil }

    /// Current VAD state for UI display.
    public private(set) var isSpeechActive: Bool = false

    public init(
        minSilenceDuration: Float = 0.65,
        minSpeechDuration: Float = 0.5,
        maxSpeechDuration: Float = 30.0,
        threshold: Float = 0.5
    ) {
        self.minSilenceDuration = minSilenceDuration
        self.minSpeechDuration = minSpeechDuration
        self.maxSpeechDuration = maxSpeechDuration
        self.threshold = threshold

        do {
            self.vad = try SileroVAD()
        } catch {
            Self.logger.error("VAD initialization failed: \(error.localizedDescription)")
            self.vad = nil
        }
    }

    // MARK: - Public API

    /// Feed raw PCM samples (any count). Returns 0 or more completed speech segments.
    public func feedSamples(_ samples: [Float]) -> [SpeechSegment] {
        guard let vad else { return [] }

        var input = carryBuffer + samples
        carryBuffer = []
        var segments: [SpeechSegment] = []

        while input.count >= SileroVAD.chunkSize {
            let chunk = Array(input.prefix(SileroVAD.chunkSize))
            input = Array(input.dropFirst(SileroVAD.chunkSize))

            guard let probability = try? vad.process(chunk) else { continue }

            if probability > threshold {
                if !isSpeechActive {
                    for bufferedChunk in preSpeechBuffer {
                        speechBuffer.append(contentsOf: bufferedChunk)
                    }
                    preSpeechBuffer.removeAll()
                }
                isSpeechActive = true
                speechBuffer.append(contentsOf: chunk)
                silenceFrameCount = 0
            } else {
                silenceFrameCount += 1
                if isSpeechActive {
                    speechBuffer.append(contentsOf: chunk)
                } else {
                    preSpeechBuffer.append(chunk)
                    if preSpeechBuffer.count > maxLookbackFrames {
                        preSpeechBuffer.removeFirst()
                    }
                }

                let silenceDuration = Float(silenceFrameCount * SileroVAD.chunkSize) / Float(SileroVAD.sampleRate)
                if silenceDuration >= minSilenceDuration && isSpeechActive {
                    if let segment = emitIfValid() {
                        segments.append(segment)
                    }
                }
            }

            let speechDuration = Float(speechBuffer.count) / Float(SileroVAD.sampleRate)
            if speechDuration >= maxSpeechDuration {
                let splitPoint = findBestSplitPoint(in: speechBuffer)
                let emitted = Array(speechBuffer.prefix(splitPoint))
                speechBuffer = Array(speechBuffer.dropFirst(splitPoint))
                if Float(emitted.count) / Float(SileroVAD.sampleRate) >= minSpeechDuration {
                    segments.append(SpeechSegment(samples: emitted))
                    Self.logger.info("max duration split: emitted \(emitted.count) samples, kept \(self.speechBuffer.count)")
                }
            }
        }

        carryBuffer = input
        return segments
    }

    /// Force-emit any buffered speech (call at end of recording).
    /// When `force` is true, emits regardless of `minSpeechDuration`.
    public func flush(force: Bool = false) -> SpeechSegment? {
        guard !carryBuffer.isEmpty, let vad else { return emitIfValid(force: force) }

        var padded = carryBuffer
        if padded.count < SileroVAD.chunkSize {
            padded += [Float](repeating: 0, count: SileroVAD.chunkSize - padded.count)
        }
        if let probability = try? vad.process(Array(padded.prefix(SileroVAD.chunkSize))),
           probability > threshold || isSpeechActive {
            speechBuffer.append(contentsOf: carryBuffer)
        }
        carryBuffer = []
        return emitIfValid(force: force)
    }

    /// Reset all state for a new session.
    public func reset() {
        carryBuffer = []
        speechBuffer = []
        preSpeechBuffer = []
        silenceFrameCount = 0
        isSpeechActive = false
        vad?.reset()
    }

    // MARK: - Private Helpers

    private func emitIfValid(force: Bool = false) -> SpeechSegment? {
        let duration = Float(speechBuffer.count) / Float(SileroVAD.sampleRate)
        defer {
            speechBuffer = []
            silenceFrameCount = 0
            isSpeechActive = false
        }
        guard !speechBuffer.isEmpty else { return nil }
        guard force || duration >= minSpeechDuration else {
            Self.logger.info("discarded short segment: \(String(format: "%.2f", duration))s")
            return nil
        }
        return SpeechSegment(samples: speechBuffer)
    }

    // Search last 2 seconds for lowest-energy chunk as split point
    private func findBestSplitPoint(in buffer: [Float]) -> Int {
        let searchWindow = 2 * SileroVAD.sampleRate
        let searchStart = max(0, buffer.count - searchWindow)
        var bestIndex = buffer.count
        var lowestEnergy: Float = .infinity

        var offset = searchStart
        while offset + SileroVAD.chunkSize <= buffer.count {
            var energy: Float = 0
            for i in offset..<(offset + SileroVAD.chunkSize) {
                energy += buffer[i] * buffer[i]
            }
            energy /= Float(SileroVAD.chunkSize)
            if energy < lowestEnergy {
                lowestEnergy = energy
                bestIndex = offset + SileroVAD.chunkSize
            }
            offset += SileroVAD.chunkSize
        }
        return bestIndex
    }
}
