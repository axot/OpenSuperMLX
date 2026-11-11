// StreamingAudioServiceIdleReleaseTests.swift
// OpenSuperMLXTests
//
// Tests the policy that releases the input engine when the app is idle, so
// Bluetooth headsets are not held in the hands-free (HFP) profile between recordings.

import XCTest
@testable import OpenSuperMLX

final class StreamingAudioServiceIdleReleaseTests: XCTestCase {

    // MARK: - Release policy

    func testIdleAppReleasesEngine() {
        XCTAssertTrue(StreamingAudioService.shouldReleaseEngine(
            isStreaming: false, hasPendingStart: false, popoverWantsMetering: false
        ))
    }

    func testStreamingKeepsEngine() {
        XCTAssertFalse(StreamingAudioService.shouldReleaseEngine(
            isStreaming: true, hasPendingStart: false, popoverWantsMetering: false
        ))
    }

    func testOpenPopoverKeepsEngineForMetering() {
        XCTAssertFalse(StreamingAudioService.shouldReleaseEngine(
            isStreaming: false, hasPendingStart: false, popoverWantsMetering: true
        ))
    }

    func testPendingStartKeepsEngineWhenPopoverCloses() {
        XCTAssertFalse(StreamingAudioService.shouldReleaseEngine(
            isStreaming: false, hasPendingStart: true, popoverWantsMetering: false
        ))
    }
}
