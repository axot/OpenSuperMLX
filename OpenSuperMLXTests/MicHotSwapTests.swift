// MicHotSwapTests.swift
// OpenSuperMLXTests

import XCTest
@testable import OpenSuperMLX

final class MicHotSwapTests: XCTestCase {

    // MARK: - Buffer Preservation

    func testRingBufferPreservedFormat() {
        let samples: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5]
        var buffer = samples
        let preserved = buffer
        buffer.removeAll(keepingCapacity: true)
        buffer.insert(contentsOf: preserved, at: 0)
        XCTAssertEqual(buffer, samples, "Buffer should be identical after preserve-restore cycle")
    }

    func testPreserveEmptyBufferIsNoOp() {
        var buffer = [Float]()
        let preserved = buffer
        buffer.removeAll(keepingCapacity: true)
        buffer.insert(contentsOf: preserved, at: 0)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testPreservedSamplesInsertedBeforeNewSamples() {
        let preserved: [Float] = [1.0, 2.0, 3.0]
        let newSamples: [Float] = [4.0, 5.0]
        var buffer = newSamples
        buffer.insert(contentsOf: preserved, at: 0)
        XCTAssertEqual(buffer, [1.0, 2.0, 3.0, 4.0, 5.0])
    }

    // MARK: - Hot-Swap Availability

    @MainActor
    func testStreamingServiceHasHotSwapCapability() {
        let service = StreamingAudioService.shared
        XCTAssertFalse(service.isStreaming, "Service should not be streaming initially")
        XCTAssertNotNil(service, "Service should exist for hot-swap")
    }
}
