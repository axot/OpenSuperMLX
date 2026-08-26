// RecordingAudioFormatTests.swift
// OpenSuperMLXTests

import AVFoundation
import XCTest

@testable import OpenSuperMLX

final class RecordingAudioFormatTests: XCTestCase {

    func testAACSettingsUseMono16kHzAt48kbpsCBR() {
        let settings = RecordingAudioFormat.aacSettings

        XCTAssertEqual(settings[AVFormatIDKey] as? Int, Int(kAudioFormatMPEG4AAC))
        XCTAssertEqual(settings[AVSampleRateKey] as? Double, 16_000)
        XCTAssertEqual(settings[AVNumberOfChannelsKey] as? Int, 1)
        XCTAssertEqual(settings[AVEncoderBitRateKey] as? Int, 48_000)
        XCTAssertEqual(settings[AVEncoderBitRateStrategyKey] as? String, AVAudioBitRateStrategy_Constant)
        XCTAssertEqual(settings[AVEncoderAudioQualityKey] as? Int, AVAudioQuality.max.rawValue)
    }

    func testCapturedFileNameUsesMillisecondsRandomSuffixAndM4AExtension() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000.123)
        let id = UUID(uuidString: "12345678-1234-4234-9234-12345678CDEF")!

        let fileName = RecordingAudioFormat.makeFileName(timestamp: timestamp, id: id)

        XCTAssertEqual(fileName, "1700000000123-cdef.m4a")
    }

    func testImportedFileNamePreservesNormalizedSourceExtension() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000.456)
        let id = UUID(uuidString: "12345678-1234-4234-9234-12345678ABCD")!

        let fileName = RecordingAudioFormat.makeFileName(
            timestamp: timestamp,
            id: id,
            pathExtension: ".WAV"
        )

        XCTAssertEqual(fileName, "1700000000456-abcd.wav")
    }

    func testFileNameRegeneratesSuffixWhenCandidateIsTaken() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000.789)
        let initialID = UUID(uuidString: "12345678-1234-4234-9234-123456781111")!
        let replacementID = UUID(uuidString: "12345678-1234-4234-9234-123456782222")!

        let fileName = RecordingAudioFormat.makeFileName(
            timestamp: timestamp,
            id: initialID,
            pathExtension: "m4a",
            isTaken: { $0.hasSuffix("1111.m4a") },
            nextID: { replacementID }
        )

        XCTAssertEqual(fileName, "1700000000789-2222.m4a")
    }
}
