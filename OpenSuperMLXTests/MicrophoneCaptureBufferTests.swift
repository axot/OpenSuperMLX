// MicrophoneCaptureBufferTests.swift
// OpenSuperMLXTests

import XCTest

@testable import OpenSuperMLX

final class MicrophoneCaptureBufferTests: XCTestCase {
    private func receive(
        _ samples: [Float],
        into buffer: MicrophoneCaptureBuffer,
        hostTime: UInt64 = 10_000_000,
        deliveredAt: UInt64 = 70_000_000
    ) {
        samples.withUnsafeBufferPointer {
            buffer.receive($0, hostTime: hostTime, sampleRate: 1000, deliveredAt: deliveredAt)
        }
    }

    func testIdleInputIsNotRetainedOrMarkedReady() {
        let buffer = MicrophoneCaptureBuffer(capacity: 8)
        receive([1, 2], into: buffer)

        XCTAssertTrue(buffer.drain().isEmpty)
        XCTAssertFalse(buffer.hasReceivedAudio)
        XCTAssertNil(buffer.firstBufferLatencyMilliseconds)
    }

    func testStartupAudioIsPreservedBeforeConsumerExists() {
        let buffer = MicrophoneCaptureBuffer(capacity: 8)
        buffer.begin(at: 10_000_000)
        receive([1, 2, 3], into: buffer)

        XCTAssertTrue(buffer.hasReceivedAudio)
        XCTAssertEqual(buffer.drain(), [1, 2, 3])
        XCTAssertTrue(buffer.drain().isEmpty)
    }

    func testFirstBlockExcludesSamplesBeforeRequest() {
        let buffer = MicrophoneCaptureBuffer(capacity: 8)
        buffer.begin(at: 10_000_000)
        receive([1, 2, 3], into: buffer, hostTime: 9_000_000)

        XCTAssertEqual(buffer.drain(), [2, 3])
    }

    func testWrappedBlocksAreDrainedInOriginalOrder() {
        let buffer = MicrophoneCaptureBuffer(capacity: 5)
        buffer.begin(at: 10_000_000)
        receive([1, 2, 3], into: buffer)
        XCTAssertEqual(buffer.drain(), [1, 2, 3])

        receive([4, 5, 6, 7], into: buffer)
        XCTAssertEqual(buffer.drain(), [4, 5, 6, 7])
    }

    func testOverflowIsReportedWithoutOverwritingAcceptedAudio() {
        let buffer = MicrophoneCaptureBuffer(capacity: 4)
        buffer.begin(at: 10_000_000)
        receive([1, 2, 3, 4, 5, 6], into: buffer)

        XCTAssertEqual(buffer.drain(), [1, 2, 3, 4])
        XCTAssertEqual(buffer.droppedSampleCount, 2)
    }

    func testCloseRejectsLateCallbacksAndNewStartDropsOldAudio() {
        let buffer = MicrophoneCaptureBuffer(capacity: 8)
        buffer.begin(at: 10_000_000)
        receive([1, 2], into: buffer)
        buffer.close()
        receive([3, 4], into: buffer)
        XCTAssertEqual(buffer.drain(), [1, 2])

        buffer.begin(at: 20_000_000)
        receive([5, 6], into: buffer, hostTime: 20_000_000)
        XCTAssertEqual(buffer.drain(), [5, 6])
    }

    func testLatencyUsesFirstDeliveryAndIgnoresEmptyBlocks() {
        let buffer = MicrophoneCaptureBuffer(capacity: 8)
        buffer.begin(at: 10_000_000)
        receive([], into: buffer)
        XCTAssertNil(buffer.firstBufferLatencyMilliseconds)

        receive([1], into: buffer, deliveredAt: 70_000_000)
        receive([2], into: buffer, deliveredAt: 90_000_000)
        XCTAssertEqual(buffer.firstBufferLatencyMilliseconds, 60)
        XCTAssertEqual(buffer.rmsLevel, 1)
        receive([.nan], into: buffer, deliveredAt: 100_000_000)
        XCTAssertEqual(buffer.rmsLevel, 0)
    }

    func testConcurrentProducerAndConsumerPreserveSamplesExactlyOnce() {
        let count = 20_000
        let buffer = MicrophoneCaptureBuffer(capacity: count)
        buffer.begin(at: 10_000_000)
        let producer = DispatchGroup()
        producer.enter()
        DispatchQueue.global().async {
            for offset in stride(from: 0, to: count, by: 100) {
                let values = (offset..<(offset + 100)).map(Float.init)
                values.withUnsafeBufferPointer {
                    buffer.receive(
                        $0, hostTime: 10_000_000, sampleRate: 48000,
                        deliveredAt: 70_000_000
                    )
                }
            }
            producer.leave()
        }
        var received: [Float] = []
        let deadline = Date().addingTimeInterval(2)
        while received.count < count && Date() < deadline {
            received.append(contentsOf: buffer.drain())
            Thread.sleep(forTimeInterval: 0.0001)
        }
        XCTAssertEqual(producer.wait(timeout: .now() + 1), .success)
        received.append(contentsOf: buffer.drain())
        XCTAssertEqual(received, (0..<count).map(Float.init))
        XCTAssertEqual(buffer.droppedSampleCount, 0)
    }
}
