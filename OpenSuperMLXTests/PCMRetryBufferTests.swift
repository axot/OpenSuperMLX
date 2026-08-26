// PCMRetryBufferTests.swift
// OpenSuperMLXTests

import XCTest

@testable import OpenSuperMLX

final class PCMRetryBufferTests: XCTestCase {

    func testAppendClipsOutsideFloatRange() {
        var buffer = PCMRetryBuffer()

        buffer.append([-2, -1, 0, 1, 2])

        XCTAssertEqual(buffer.samples, [.min, .min, 0, .max, .max])
    }

    func testDecodedSamplesRoundTripWithinInt16Tolerance() {
        let input: [Float] = [-1, -0.75, -0.25, 0, 0.25, 0.75, 1]
        var buffer = PCMRetryBuffer()

        buffer.append(input)

        let decoded = buffer.decodedSamples()
        XCTAssertEqual(decoded.count, input.count)
        for (actual, expected) in zip(decoded, input) {
            XCTAssertEqual(actual, expected, accuracy: 1 / Float(Int16.max))
        }
    }

    func testMultipleChunksPreserveArrivalOrder() {
        var buffer = PCMRetryBuffer()

        buffer.append([-0.75, -0.25])
        buffer.append([0.25, 0.75])

        let decoded = buffer.decodedSamples()
        XCTAssertEqual(decoded[0], -0.75, accuracy: 0.0001)
        XCTAssertEqual(decoded[1], -0.25, accuracy: 0.0001)
        XCTAssertEqual(decoded[2], 0.25, accuracy: 0.0001)
        XCTAssertEqual(decoded[3], 0.75, accuracy: 0.0001)
    }

    func testByteCountUsesTwoBytesPerSample() {
        var buffer = PCMRetryBuffer()

        buffer.append([Float](repeating: 0.1, count: 16_000))

        XCTAssertEqual(buffer.count, 16_000)
        XCTAssertEqual(buffer.byteCount, 32_000)
    }

    func testEmptyChunkDoesNotChangeBuffer() {
        var buffer = PCMRetryBuffer()

        buffer.append([])

        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(buffer.byteCount, 0)
    }

    func testNonFiniteSamplesBecomeSilence() {
        var buffer = PCMRetryBuffer()

        buffer.append([.nan, .infinity, -.infinity])

        XCTAssertEqual(buffer.samples, [0, 0, 0])
    }

    func testReleaseRemovesRetainedAudio() {
        var buffer = PCMRetryBuffer()
        buffer.append([0.1, 0.2, 0.3])

        buffer.release()

        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(buffer.byteCount, 0)
    }
}
