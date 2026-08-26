// RecordingAudioFormat.swift
// OpenSuperMLX

import AVFoundation
import Foundation

enum RecordingAudioFormat {
    static let sampleRate: Double = 16_000
    static let channelCount = 1
    static let bitRate = 48_000
    static let fileExtension = "m4a"

    static var aacSettings: [String: Any] {
        [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVEncoderBitRateKey: bitRate,
            AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_Constant,
            AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue
        ]
    }

    static func makeFileName(
        timestamp: Date,
        id: UUID,
        pathExtension: String = fileExtension,
        isTaken: (String) -> Bool = { _ in false },
        nextID: () -> UUID = { UUID() }
    ) -> String {
        let milliseconds = Int64((timestamp.timeIntervalSince1970 * 1_000).rounded(.down))
        let normalizedExtension = normalize(pathExtension: pathExtension)
        var candidateID = id

        while true {
            let suffix = candidateID.uuidString
                .replacingOccurrences(of: "-", with: "")
                .suffix(4)
                .lowercased()
            let fileName = "\(milliseconds)-\(suffix).\(normalizedExtension)"
            if !isTaken(fileName) {
                return fileName
            }
            candidateID = nextID()
        }
    }

    private static func normalize(pathExtension: String) -> String {
        let normalized = pathExtension
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        return normalized.isEmpty ? fileExtension : normalized
    }
}
