// IndicatorWindowTests.swift
// OpenSuperMLXTests

import XCTest

@testable import OpenSuperMLX

final class IndicatorWindowTests: XCTestCase {
    func testCapturingStatesIncludeConnectionAndRecording() {
        XCTAssertTrue(RecordingState.connecting.isCapturing)
        XCTAssertTrue(RecordingState.recording.isCapturing)
        for state in [RecordingState.idle, .decoding, .correcting, .busy] {
            XCTAssertFalse(state.isCapturing)
        }
    }

    func testProcessingStatesIncludeDecodingAndCorrection() {
        XCTAssertTrue(RecordingState.decoding.isProcessing)
        XCTAssertTrue(RecordingState.correcting.isProcessing)
        for state in [RecordingState.idle, .connecting, .recording, .busy] {
            XCTAssertFalse(state.isProcessing)
        }
    }

    func testBusyOverlayDoesNotCreateARecordingSession() {
        XCTAssertFalse(RecordingState.idle.hasRecordingSession)
        XCTAssertFalse(RecordingState.busy.hasRecordingSession)
        for state in [RecordingState.connecting, .recording, .decoding, .correcting] {
            XCTAssertTrue(state.hasRecordingSession)
        }
    }
}
