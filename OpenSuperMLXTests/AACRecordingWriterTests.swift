// AACRecordingWriterTests.swift
// OpenSuperMLXTests

import AVFoundation
import XCTest

@testable import OpenSuperMLX

final class AACRecordingWriterTests: XCTestCase {

    func testWritesPlayableMono16kHzAACNear48kbps() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recording.m4a")
        let writer = try AACRecordingWriter(url: url)

        var state: UInt64 = 0x123456789ABCDEF
        for _ in 0..<100 {
            let samples = (0..<1_600).map { _ -> Float in
                state = state &* 6_364_136_223_846_793_005 &+ 1
                return (Float((state >> 40) & 0xFFFF) / 32_768 - 1) * 0.1
            }
            try writer.writeChunk(samples)
        }
        _ = try writer.finalize()

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.streamDescription.pointee.mFormatID, kAudioFormatMPEG4AAC)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let estimatedDataRate = try await track.load(.estimatedDataRate)
        XCTAssertEqual(CMTimeGetSeconds(duration), 10, accuracy: 0.15)
        XCTAssertEqual(estimatedDataRate, 48_000, accuracy: 4_000)
    }

    func testMultipleChunksPreserveTotalDuration() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("chunks.m4a")
        let writer = try AACRecordingWriter(url: url)

        try writer.writeChunk([Float](repeating: 0.1, count: 8_000))
        try writer.writeChunk([Float](repeating: -0.1, count: 16_000))
        _ = try writer.finalize()

        let duration = try await AVURLAsset(url: url).load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 1.5, accuracy: 0.15)
        XCTAssertEqual(writer.framesWritten, 24_000)
    }

    func testEmptyChunkDoesNotWriteFrames() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try AACRecordingWriter(url: directory.appendingPathComponent("empty.m4a"))

        try writer.writeChunk([])

        XCTAssertEqual(writer.framesWritten, 0)
    }

    func testWriteAfterFinalizeThrows() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try AACRecordingWriter(url: directory.appendingPathComponent("finalized.m4a"))
        _ = try writer.finalize()

        XCTAssertThrowsError(try writer.writeChunk([0.1]))
    }

    func testCancelRemovesTemporaryFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cancelled.m4a")
        let writer = try AACRecordingWriter(url: url)
        try writer.writeChunk([Float](repeating: 0.1, count: 1_600))

        writer.cancel()

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testArchiveCapturesInitializationFailure() {
        let archive = StreamingAACArchive(
            url: URL(fileURLWithPath: "/tmp/unwritten.m4a"),
            writerFactory: { _ in throw FakeAACWriterError.failure }
        )

        XCTAssertNotNil(archive.failure)
        guard case .failure = archive.finalize() else {
            return XCTFail("Expected initialization failure")
        }
    }

    func testArchiveLatchesFirstWriteFailure() {
        let writer = FakeAACWriter(writeError: FakeAACWriterError.failure)
        let archive = StreamingAACArchive(
            url: writer.url,
            writerFactory: { _ in writer }
        )

        XCTAssertNotNil(archive.write([0.1]))
        XCTAssertNil(archive.write([0.2]))
        XCTAssertEqual(writer.writeCallCount, 1)
        XCTAssertEqual(writer.cancelCallCount, 1)
    }

    func testArchiveCapturesFinalizeFailure() {
        let writer = FakeAACWriter(finalizeError: FakeAACWriterError.failure)
        let archive = StreamingAACArchive(
            url: writer.url,
            writerFactory: { _ in writer }
        )

        guard case .failure = archive.finalize() else {
            return XCTFail("Expected finalize failure")
        }
        XCTAssertEqual(writer.finalizeCallCount, 1)
        XCTAssertEqual(writer.cancelCallCount, 1)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AACRecordingWriterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private enum FakeAACWriterError: Error {
    case failure
}

private final class FakeAACWriter: AACRecordingWriting {
    let url = URL(fileURLWithPath: "/tmp/fake-aac-writer.m4a")
    var framesWritten = 0
    private let writeError: Error?
    private let finalizeError: Error?
    private(set) var writeCallCount = 0
    private(set) var finalizeCallCount = 0
    private(set) var cancelCallCount = 0

    init(writeError: Error? = nil, finalizeError: Error? = nil) {
        self.writeError = writeError
        self.finalizeError = finalizeError
    }

    func writeChunk(_ samples: [Float]) throws {
        writeCallCount += 1
        if let writeError { throw writeError }
        framesWritten += samples.count
    }

    func finalize() throws -> URL {
        finalizeCallCount += 1
        if let finalizeError { throw finalizeError }
        return url
    }

    func cancel() {
        cancelCallCount += 1
    }
}
