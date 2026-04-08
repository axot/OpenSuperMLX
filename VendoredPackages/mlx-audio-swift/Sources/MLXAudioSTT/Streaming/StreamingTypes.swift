//
//  StreamingTypes.swift
//  MLXAudioSTT
//
//  Created by Prince Canuma on 07/02/2026.
//

import Foundation

// MARK: - Streaming Configuration

public struct StreamingConfig: Sendable {
    public var language: String
    public var temperature: Float
    public var maxNewTokensPerChunk: Int
    public var chunkDurationSeconds: Float = 2.0
    public var rollbackTokens: Int = 5
    public var coldStartChunks: Int = 2
    public var maxEncoderWindows: Int = 4
    public var encoderWindowSizeMelFrames: Int = 800
    public var maxPrefixTokens: Int = 150
    public var resetIntervalChunks: Int = 45
    public var resetCarryTokens: Int = 24
    public var singleTokenRunThreshold: Int = 12
    public var blockPatternMaxPeriod: Int = 6
    public var blockPatternMinReps: Int = 4
    public var stagnationChunkThreshold: Int = 4
    public var pastTextConditioning: Bool = true

    public init(
        language: String = "English",
        temperature: Float = 0.0,
        maxNewTokensPerChunk: Int = 32
    ) {
        self.language = language
        self.temperature = temperature
        self.maxNewTokensPerChunk = maxNewTokensPerChunk
    }
}

// MARK: - Transcription Events

public enum TranscriptionEvent: Sendable {
    /// Provisional text that may still change
    case provisional(text: String)
    /// Text that has been confirmed and will not change
    case confirmed(text: String)
    case displayUpdate(confirmedText: String, provisionalText: String)
    case stats(StreamingStats)
    case ended(fullText: String)
}

// MARK: - Streaming Stats

public struct StreamingStats: Sendable {
    public var encodedWindowCount: Int
    public var totalAudioSeconds: Double
    public var tokensPerSecond: Double
    public var realTimeFactor: Double
    public var peakMemoryGB: Double
    public var chunkElapsedSeconds: Double

    public init(
        encodedWindowCount: Int = 0,
        totalAudioSeconds: Double = 0,
        tokensPerSecond: Double = 0,
        realTimeFactor: Double = 0,
        peakMemoryGB: Double = 0,
        chunkElapsedSeconds: Double = 0
    ) {
        self.encodedWindowCount = encodedWindowCount
        self.totalAudioSeconds = totalAudioSeconds
        self.tokensPerSecond = tokensPerSecond
        self.realTimeFactor = realTimeFactor
        self.peakMemoryGB = peakMemoryGB
        self.chunkElapsedSeconds = chunkElapsedSeconds
    }
}
