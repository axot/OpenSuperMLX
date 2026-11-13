// StreamingAudioServiceHandoffTests.swift
// OpenSuperMLXTests

import XCTest

@testable import OpenSuperMLX

final class StreamingAudioServiceHandoffTests: XCTestCase {
    func testIdleReplacementDiscardsCancelledAudio() {
        let samples = StreamingAudioService.makeMicrophoneHandoffSamples(
            retained: [1, 2], captured: [3, 4],
            inputSampleRate: 48000, outputSampleRate: 48000,
            preserve: false
        )

        XCTAssertTrue(samples.isEmpty)
    }

    func testActiveReplacementPreservesTailInOrderAtNewSampleRate() {
        let samples = StreamingAudioService.makeMicrophoneHandoffSamples(
            retained: [1, 2], captured: [3, 4],
            inputSampleRate: 24000, outputSampleRate: 48000,
            preserve: true
        )

        XCTAssertEqual(samples, [1, 1.5, 2, 2.5, 3, 3.5, 4, 4])
    }

    func testEmptyReplacementHasNoAudioToTransfer() {
        let samples = StreamingAudioService.makeMicrophoneHandoffSamples(
            retained: [], captured: [],
            inputSampleRate: 48000, outputSampleRate: 16000,
            preserve: true
        )

        XCTAssertTrue(samples.isEmpty)
    }

    func testCancelledReplacementCannotCarryTailIntoNewRequest() {
        let buffer = MicrophoneCaptureBuffer(capacity: 2)
        buffer.begin(at: 10)
        [Float(1), 2, 3].withUnsafeBufferPointer {
            buffer.receive($0, hostTime: 10, sampleRate: 48000, deliveredAt: 20)
        }
        buffer.close()
        var source = MicrophoneCaptureSource(buffer: buffer, sampleRate: 48000, pendingDrops: 5)

        source.discard()
        source.beginRequest()
        let transferred = StreamingAudioService.makeMicrophoneHandoffSamples(
            retained: [], captured: source.buffer?.drain() ?? [],
            inputSampleRate: source.sampleRate, outputSampleRate: 48000,
            preserve: true
        )

        XCTAssertTrue(transferred.isEmpty)
        XCTAssertNil(source.buffer)
        XCTAssertEqual(source.pendingDrops, 0)
    }

    func testTransferredDropsResetForNextRecording() {
        var source = MicrophoneCaptureSource(pendingDrops: 7)

        source.beginRequest()

        XCTAssertEqual(source.pendingDrops, 0)
    }
}
