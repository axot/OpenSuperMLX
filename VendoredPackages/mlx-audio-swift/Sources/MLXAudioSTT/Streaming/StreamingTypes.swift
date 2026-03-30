//
//  StreamingTypes.swift
//  MLXAudioSTT
//
//  Created by Prince Canuma on 07/02/2026.
//

import Foundation

// MARK: - Streaming Configuration

/// Configuration for a streaming inference session.
public struct StreamingConfig: Sendable {
    /// Language for transcription
    public var language: String
    /// Sampling temperature (0 = greedy)
    public var temperature: Float
    /// Maximum new tokens to generate per decode chunk.
    public var maxNewTokensPerChunk: Int
    /// Penalty factor applied to recently-seen tokens to prevent repetition loops.
    /// 1.0 = disabled. ASR-safe default is 1.2.
    public var repetitionPenalty: Float
    /// Number of recent tokens considered for repetition penalty.
    public var repetitionContextSize: Int

    public init(
        language: String = "English",
        temperature: Float = 0.0,
        maxNewTokensPerChunk: Int = 200,
        repetitionPenalty: Float = 1.0,
        repetitionContextSize: Int = 32
    ) {
        self.language = language
        self.temperature = temperature
        self.maxNewTokensPerChunk = maxNewTokensPerChunk
        self.repetitionPenalty = repetitionPenalty
        self.repetitionContextSize = repetitionContextSize
    }
}

// MARK: - Transcription Events

/// Events emitted by a streaming inference session.
public enum TranscriptionEvent: Sendable {
    /// Provisional text that may still change
    case provisional(text: String)
    /// Text that has been confirmed and will not change
    case confirmed(text: String)
    /// Combined display update with both confirmed and provisional text
    case displayUpdate(confirmedText: String, provisionalText: String)
    /// Performance statistics
    case stats(StreamingStats)
    /// Session has ended with final text
    case ended(fullText: String)
}

// MARK: - Streaming Stats

/// Performance statistics for a streaming session.
public struct StreamingStats: Sendable {
    /// Number of encoder windows processed
    public var encodedWindowCount: Int
    /// Total audio duration processed so far (seconds)
    public var totalAudioSeconds: Double
    /// Tokens generated per second
    public var tokensPerSecond: Double
    /// Real-time factor (< 1.0 means faster than real-time)
    public var realTimeFactor: Double
    /// Peak memory usage in GB
    public var peakMemoryGB: Double

    public init(
        encodedWindowCount: Int = 0,
        totalAudioSeconds: Double = 0,
        tokensPerSecond: Double = 0,
        realTimeFactor: Double = 0,
        peakMemoryGB: Double = 0
    ) {
        self.encodedWindowCount = encodedWindowCount
        self.totalAudioSeconds = totalAudioSeconds
        self.tokensPerSecond = tokensPerSecond
        self.realTimeFactor = realTimeFactor
        self.peakMemoryGB = peakMemoryGB
    }
}
