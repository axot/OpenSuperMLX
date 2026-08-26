// StreamingAudioServiceArchiveTests.swift
// OpenSuperMLXTests

import XCTest

@testable import OpenSuperMLX

final class StreamingAudioServiceArchiveTests: XCTestCase {

    func testSamplesWithinThresholdAreIdenticalForArchiveAndInference() {
        let samples = (0..<80_000).map(Float.init)

        let split = StreamingAudioService.splitArchiveAndInferenceSamples(samples)

        XCTAssertEqual(split.archive, samples)
        XCTAssertEqual(split.inference, samples)
    }

    func testBackpressureDropsOnlyInferenceSamples() {
        let samples = (0..<96_000).map(Float.init)

        let split = StreamingAudioService.splitArchiveAndInferenceSamples(samples)

        XCTAssertEqual(split.archive, samples)
        XCTAssertEqual(split.inference, Array(samples.suffix(16_000)))
    }

    func testEmptySamplesProduceEmptyBranches() {
        let split = StreamingAudioService.splitArchiveAndInferenceSamples([])

        XCTAssertTrue(split.archive.isEmpty)
        XCTAssertTrue(split.inference.isEmpty)
    }

    func testFinalMixIncludesLongerMicrophoneTail() {
        let mixer = AudioMixer(inputSampleRate: 16_000)
        let mic = [Float](repeating: 0.2, count: 2_000)
        let system = [Float](repeating: 0.3, count: 1_600)

        let samples = StreamingAudioService.makeFinalMixedSamples(
            mixer: mixer,
            microphone: mic,
            microphoneSampleRate: 16_000,
            system: system,
            systemSampleRate: 16_000,
            speakerCaptureActive: true
        )

        XCTAssertEqual(samples.count, 2_000)
    }

    func testFinalMixIncludesLongerSystemTail() {
        let mixer = AudioMixer(inputSampleRate: 16_000)
        let mic = [Float](repeating: 0.2, count: 1_600)
        let system = [Float](repeating: 0.3, count: 2_000)

        let samples = StreamingAudioService.makeFinalMixedSamples(
            mixer: mixer,
            microphone: mic,
            microphoneSampleRate: 16_000,
            system: system,
            systemSampleRate: 16_000,
            speakerCaptureActive: true
        )

        XCTAssertEqual(samples.count, 2_000)
    }

    func testFeedStateRetainsSamplesWhenArchiveInitializationFailed() {
        let archive = StreamingAACArchive(
            url: URL(fileURLWithPath: "/tmp/unwritten-retry.m4a"),
            writerFactory: { _ in throw ArchiveTestError.failure }
        )
        var state = StreamingFeedState(archive: archive)

        let error = state.append([0.1, 0.2, 0.3])

        XCTAssertNotNil(error)
        XCTAssertEqual(state.retryBuffer.count, 3)
    }

    func testCancelledFeedTaskTransfersOwnedRetryBuffer() async {
        let archive = StreamingAACArchive(
            url: URL(fileURLWithPath: "/tmp/cancelled-feed.m4a"),
            writerFactory: { _ in NoOpAACWriter() }
        )
        let task = Task.detached { () -> StreamingFeedState in
            var state = StreamingFeedState(archive: archive)
            _ = state.append([0.1, 0.2])
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return state }
            _ = state.append([0.3])
            return state
        }

        task.cancel()
        let state = await task.value

        XCTAssertEqual(state.retryBuffer.count, 2)
    }

    func testCaptureOutcomePreservesTextWithoutAudioURL() {
        var buffer = PCMRetryBuffer()
        buffer.append([0.1, 0.2])

        let outcome = StreamingCaptureOutcome(
            text: "preserved transcript",
            duration: 2,
            audioURL: nil,
            storageError: RecordingStorageError.classify(ArchiveTestError.failure),
            retryBuffer: buffer,
            recordingID: UUID(),
            timestamp: Date(),
            fileName: "recording.m4a"
        )

        XCTAssertEqual(outcome.text, "preserved transcript")
        XCTAssertNil(outcome.audioURL)
        XCTAssertNotNil(outcome.storageError)
        XCTAssertEqual(outcome.retryBuffer.count, 2)
    }
}

private enum ArchiveTestError: Error {
    case failure
}

private final class NoOpAACWriter: AACRecordingWriting {
    var framesWritten = 0

    func writeChunk(_ samples: [Float]) throws {
        framesWritten += samples.count
    }

    func finalize() throws -> URL {
        URL(fileURLWithPath: "/tmp/no-op.m4a")
    }

    func cancel() {}
}
