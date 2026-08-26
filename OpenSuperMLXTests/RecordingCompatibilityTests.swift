// RecordingCompatibilityTests.swift
// OpenSuperMLXTests

import AVFoundation
import XCTest

import MLXAudioCore
@testable import OpenSuperMLX

final class RecordingCompatibilityTests: XCTestCase {

    func testLegacyWAVDecodesAt16kHz() throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.directory) }
        let url = context.directory.appendingPathComponent("legacy.wav")
        try writeWAV(to: url, samples: context.samples)

        let (sampleRate, audio) = try loadAudioArray(from: url, sampleRate: 16_000)

        XCTAssertEqual(sampleRate, 16_000)
        XCTAssertEqual(audio.shape[0], context.samples.count)
    }

    func testM4ADecodesAt16kHz() throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.directory) }
        let url = context.directory.appendingPathComponent("recording.m4a")
        let writer = try AACRecordingWriter(url: url)
        try writer.writeChunk(context.samples)
        _ = try writer.finalize()

        let (sampleRate, audio) = try loadAudioArray(from: url, sampleRate: 16_000)

        XCTAssertEqual(sampleRate, 16_000)
        XCTAssertEqual(audio.shape[0], context.samples.count)
    }

    func testWAVAndM4AInitializePlayback() throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.directory) }
        let wavURL = context.directory.appendingPathComponent("legacy.wav")
        let m4aURL = context.directory.appendingPathComponent("recording.m4a")
        try writeWAV(to: wavURL, samples: context.samples)
        let writer = try AACRecordingWriter(url: m4aURL)
        try writer.writeChunk(context.samples)
        _ = try writer.finalize()

        XCTAssertEqual(try AVAudioPlayer(contentsOf: wavURL).duration, 1, accuracy: 0.01)
        XCTAssertEqual(try AVAudioPlayer(contentsOf: m4aURL).duration, 1, accuracy: 0.15)
    }

    func testMissingAudioFailsToInitializePlayback() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).m4a")

        XCTAssertThrowsError(try AVAudioPlayer(contentsOf: url))
    }

    private func makeContext() throws -> (directory: URL, samples: [Float]) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingCompatibilityTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let samples = (0..<16_000).map {
            sin(Float($0) * 2 * .pi * 440 / 16_000) * 0.2
        }
        return (directory, samples)
    }

    private func writeWAV(to url: URL, samples: [Float]) throws {
        try autoreleasepool {
            let format = try XCTUnwrap(AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            ))
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
            ))
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { source in
                buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
            }
            try file.write(from: buffer)
        }
    }
}
