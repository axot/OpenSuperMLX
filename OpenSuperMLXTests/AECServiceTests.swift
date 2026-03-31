// AECServiceTests.swift
// OpenSuperMLX

import AVFoundation
import XCTest

@testable import OpenSuperMLX

final class AECServiceTests: XCTestCase {

    // MARK: - Singleton

    func testSharedInstanceExists() {
        let service = AECService.shared
        XCTAssertNotNil(service)
    }

    func testSharedInstanceIsSingleton() {
        let a = AECService.shared
        let b = AECService.shared
        XCTAssertTrue(a === b)
    }

    // MARK: - Availability

    func testIsAvailableReturnsBool() {
        let result = AECService.shared.isAvailable
        XCTAssertTrue(result == true || result == false)
    }

    // MARK: - Error Handling

    func testProcessRecordingWithInvalidURLsThrows() async {
        let bogus = URL(fileURLWithPath: "/nonexistent/path/mic.wav")
        let bogusRef = URL(fileURLWithPath: "/nonexistent/path/system.wav")

        do {
            _ = try await AECService.shared.processRecording(
                micTrackURL: bogus,
                systemAudioTrackURL: bogusRef
            )
            XCTFail("Expected processRecording to throw for invalid URLs")
        } catch let error as AECError {
            if case .inputFileNotFound = error {
                // Expected
            } else {
                XCTFail("Expected inputFileNotFound, got \(error)")
            }
        } catch {
            XCTFail("Expected AECError, got \(error)")
        }
    }

    func testProcessRecordingWithMissingSystemFileThrows() async throws {
        let micURL = try createTestWAVFile(sampleCount: 1600, name: "mic_only")
        defer { try? FileManager.default.removeItem(at: micURL) }

        let bogusRef = URL(fileURLWithPath: "/nonexistent/system.wav")

        do {
            _ = try await AECService.shared.processRecording(
                micTrackURL: micURL,
                systemAudioTrackURL: bogusRef
            )
            XCTFail("Expected processRecording to throw for missing system file")
        } catch let error as AECError {
            if case .inputFileNotFound = error {
                // Expected
            } else {
                XCTFail("Expected inputFileNotFound, got \(error)")
            }
        }
    }

    // MARK: - Processing

    func testProcessRecordingProducesOutputInTempDirectory() async throws {
        try XCTSkipUnless(AECService.shared.isAvailable, "AEC models not available")

        let micURL = try createTestWAVFile(sampleCount: 16000, name: "test_mic")
        let sysURL = try createTestWAVFile(sampleCount: 16000, name: "test_sys")
        defer {
            try? FileManager.default.removeItem(at: micURL)
            try? FileManager.default.removeItem(at: sysURL)
        }

        let outputURL = try await AECService.shared.processRecording(
            micTrackURL: micURL,
            systemAudioTrackURL: sysURL
        )
        defer { try? FileManager.default.removeItem(at: outputURL) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertTrue(
            outputURL.path.hasPrefix(FileManager.default.temporaryDirectory.path),
            "Output should be in temp directory"
        )
    }

    func testProcessRecordingWithEmptyMicReturnsOriginalURL() async throws {
        try XCTSkipUnless(AECService.shared.isAvailable, "AEC models not available")

        let micURL = try createTestWAVFile(sampleCount: 0, name: "empty_mic")
        let sysURL = try createTestWAVFile(sampleCount: 16000, name: "nonempty_sys")
        defer {
            try? FileManager.default.removeItem(at: micURL)
            try? FileManager.default.removeItem(at: sysURL)
        }

        let outputURL = try await AECService.shared.processRecording(
            micTrackURL: micURL,
            systemAudioTrackURL: sysURL
        )

        XCTAssertEqual(outputURL, micURL, "Empty mic should return original mic URL")
    }

    func testProcessRecordingWithDifferentLengthTracks() async throws {
        try XCTSkipUnless(AECService.shared.isAvailable, "AEC models not available")

        let micURL = try createTestWAVFile(sampleCount: 32000, name: "long_mic")
        let sysURL = try createTestWAVFile(sampleCount: 16000, name: "short_sys")
        defer {
            try? FileManager.default.removeItem(at: micURL)
            try? FileManager.default.removeItem(at: sysURL)
        }

        let outputURL = try await AECService.shared.processRecording(
            micTrackURL: micURL,
            systemAudioTrackURL: sysURL
        )
        defer { try? FileManager.default.removeItem(at: outputURL) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
    }

    // MARK: - AECError

    func testAECErrorDescriptions() {
        let notFound = AECError.inputFileNotFound(URL(fileURLWithPath: "/test/mic.wav"))
        XCTAssertTrue(notFound.localizedDescription.contains("mic.wav"))

        let failed = AECError.processingFailed("test reason")
        XCTAssertTrue(failed.localizedDescription.contains("test reason"))

        let formatError = AECError.audioFormatError("bad format")
        XCTAssertTrue(formatError.localizedDescription.contains("bad format"))
    }

    // MARK: - Helpers

    private func createTestWAVFile(sampleCount: Int, name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)_\(UUID().uuidString).wav")

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw AECError.audioFormatError("Cannot create test format")
        }

        let file = try AVAudioFile(forWriting: url, settings: format.settings)

        if sampleCount > 0 {
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(sampleCount)
            ) else {
                throw AECError.audioFormatError("Cannot create test buffer")
            }

            buffer.frameLength = AVAudioFrameCount(sampleCount)
            if let channelData = buffer.floatChannelData {
                // Generate sine wave test signal
                for i in 0..<sampleCount {
                    channelData[0][i] = sin(Float(i) * 2.0 * .pi * 440.0 / 16000.0) * 0.5
                }
            }

            try file.write(from: buffer)
        }

        return url
    }
}
