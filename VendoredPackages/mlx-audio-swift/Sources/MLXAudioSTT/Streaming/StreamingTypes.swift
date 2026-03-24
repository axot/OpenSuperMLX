//
//  StreamingTypes.swift
//  MLXAudioSTT
//
//  Created by Prince Canuma on 07/02/2026.
//

import Foundation

// MARK: - Delay Presets

/// Controls the tradeoff between latency and accuracy for streaming transcription.
public enum DelayPreset: Sendable {
    /// ~200ms delay — fastest feedback, may have more provisional corrections
    case realtime
    /// ~480ms delay — balanced for voice agent use cases
    case agent
    /// ~2400ms delay — higher accuracy, suitable for subtitles
    case subtitle
    /// Custom delay in milliseconds
    case custom(ms: Int)

    public var delayMs: Int {
        switch self {
        case .realtime: return 200
        case .agent: return 480
        case .subtitle: return 2400
        case .custom(let ms): return ms
        }
    }
}

// MARK: - Streaming Configuration

/// Configuration for a streaming inference session.
public struct StreamingConfig: Sendable {
    /// How often to run decode passes (seconds)
    public var decodeIntervalSeconds: Double
    /// Maximum number of cached encoder windows (~8s each)
    public var maxCachedWindows: Int
    /// Maximum number of recent encoder windows used per decode pass.
    /// Limits the audio context to the most recent `decodeWindowCount` windows,
    /// keeping each decode pass roughly constant-time instead of O(total_duration²).
    /// Set to 0 to use all cached windows (original behavior).
    public var decodeWindowCount: Int
    /// Delay preset controlling provisional → confirmed promotion
    public var delayPreset: DelayPreset
    /// Language for transcription
    public var language: String
    /// Sampling temperature (0 = greedy)
    public var temperature: Float
    /// Maximum tokens per decode pass
    public var maxTokensPerPass: Int
    /// Number of trailing tokens to keep unfixed for prefix-rollback
    public var unfixedTokenNum: Int
    /// Penalty factor applied to recently-seen tokens to prevent repetition loops.
    /// 1.0 = disabled. ASR-safe default is 1.2.
    public var repetitionPenalty: Float
    /// Number of recent tokens considered for repetition penalty.
    public var repetitionContextSize: Int

    public init(
        decodeIntervalSeconds: Double = 1.0,
        maxCachedWindows: Int = 60,
        decodeWindowCount: Int = 10,
        delayPreset: DelayPreset = .agent,
        language: String = "English",
        temperature: Float = 0.0,
        maxTokensPerPass: Int = 512,
        unfixedTokenNum: Int = 5,
        repetitionPenalty: Float = 1.2,
        repetitionContextSize: Int = 32
    ) {
        self.decodeIntervalSeconds = decodeIntervalSeconds
        self.maxCachedWindows = maxCachedWindows
        self.decodeWindowCount = decodeWindowCount
        self.delayPreset = delayPreset
        self.language = language
        self.temperature = temperature
        self.maxTokensPerPass = maxTokensPerPass
        self.unfixedTokenNum = unfixedTokenNum
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
