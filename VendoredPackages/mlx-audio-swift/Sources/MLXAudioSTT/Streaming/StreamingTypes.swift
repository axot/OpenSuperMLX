//
//  StreamingTypes.swift
//  MLXAudioSTT
//
//  Created by Prince Canuma on 07/02/2026.
//

import Foundation

// MARK: - Duration Helper

extension ContinuousClock.Duration {
    public var milliseconds: Int {
        Int(components.seconds) * 1000 + Int(components.attoseconds / 1_000_000_000_000_000)
    }
}

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
    public var blockPatternMaxPeriod: Int = 15
    public var blockPatternMinReps: Int = 4
    public var stagnationChunkThreshold: Int = 4
    public var prefixDiversityThreshold: Double = 0.3
    public var pastTextConditioning: Bool = true
    public var repetitionRecoveryEnabled: Bool = true

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
    public var isComplete: Bool = true
    /// Present only on the event announcing a newly skipped recording range.
    public var recoveryGap: StreamingTranscriptionGap?
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

// MARK: - Transcription Gaps

public struct StreamingTranscriptionGap: Sendable, Equatable, Encodable {
    public let startSeconds: Double
    public let endSeconds: Double
    public let reason: String

    public init(startSeconds: Double, endSeconds: Double, reason: String) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.reason = reason
    }

    public var timeRange: String {
        "\(Self.timestamp(startSeconds))–\(Self.timestamp(endSeconds))"
    }

    private enum CodingKeys: String, CodingKey {
        case startSeconds = "start_seconds"
        case endSeconds = "end_seconds"
        case reason
    }

    private static func timestamp(_ seconds: Double) -> String {
        let tenths = Int((seconds * 10).rounded())
        return String(format: "%02d:%02d.%d", tenths / 600, tenths / 10 % 60, tenths % 10)
    }
}
