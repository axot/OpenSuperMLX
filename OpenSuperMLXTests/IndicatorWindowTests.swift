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

    func testFirstAudioAdvancesConnectingStateToRecording() {
        XCTAssertEqual(RecordingState.connecting.afterCaptureReadiness(true), .recording)
    }

    func testStoppedInputReturnsActiveRecordingToConnecting() {
        XCTAssertEqual(RecordingState.recording.afterCaptureReadiness(false), .connecting)
    }

    func testLateReadinessCannotReviveFinishedSession() {
        for state in [RecordingState.idle, .decoding, .correcting, .busy] {
            XCTAssertEqual(state.afterCaptureReadiness(true), state)
            XCTAssertEqual(state.afterCaptureReadiness(false), state)
        }
    }

    func testPendingSaveOrBusyWorkRejectsCaptureBeforeHardwareStarts() {
        XCTAssertTrue(RecordingState.allowsCaptureStart(saveBlocked: false, busy: false))
        XCTAssertFalse(RecordingState.allowsCaptureStart(saveBlocked: true, busy: false))
        XCTAssertFalse(RecordingState.allowsCaptureStart(saveBlocked: false, busy: true))
        XCTAssertFalse(RecordingState.allowsCaptureStart(saveBlocked: true, busy: true))
    }
}
