// StreamingAudioServiceDualTrackTests.swift
// OpenSuperMLX

import Combine
import XCTest

@testable import OpenSuperMLX

final class StreamingAudioServiceDualTrackTests: XCTestCase {

    // MARK: - Initial State

    @MainActor
    func testIsDualTrackModeDefaultsToFalse() throws {
        let service = StreamingAudioService.shared
        XCTAssertFalse(service.isDualTrackMode)
    }

    // MARK: - Regression: Existing API Unchanged

    @MainActor
    func testExistingStreamingAPIExists() throws {
        let service = StreamingAudioService.shared
        XCTAssertFalse(service.isStreaming)
        XCTAssertEqual(service.confirmedText, "")
        XCTAssertEqual(service.provisionalText, "")
    }

    // MARK: - Dual-Track Mode Flag

    @MainActor
    func testDualTrackModeIsPublishedProperty() throws {
        let service = StreamingAudioService.shared
        let publisher = service.$isDualTrackMode
        var receivedValues: [Bool] = []
        let cancellable = publisher.sink { receivedValues.append($0) }
        XCTAssertFalse(receivedValues.isEmpty, "Publisher should emit current value immediately")
        XCTAssertFalse(receivedValues.first ?? true)
        cancellable.cancel()
    }

    @MainActor
    func testDualTrackModeNotAffectedByExistingStreamingState() throws {
        let service = StreamingAudioService.shared
        XCTAssertFalse(service.isStreaming)
        XCTAssertFalse(service.isDualTrackMode, "Dual-track mode should be independent of streaming state")
    }
}
