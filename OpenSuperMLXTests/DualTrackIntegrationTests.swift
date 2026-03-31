// DualTrackIntegrationTests.swift
// OpenSuperMLXTests

import XCTest

@testable import OpenSuperMLX

final class DualTrackIntegrationTests: XCTestCase {

    // MARK: - shouldUseDualTrack

    func testMicOnlyFallbackWhenAudioSourceModeMicrophoneOnly() {
        let resolved = ResolvedAudioSource(
            mode: .micOnly,
            outputType: .speakers,
            callingApp: nil,
            bundleID: nil
        )
        XCTAssertFalse(
            DualTrackDecision.shouldUseDualTrack(
                resolvedSource: resolved,
                hasScreenRecordingPermission: true
            )
        )
    }

    func testMicOnlyFallbackWhenNoCallDetectedInAutoMode() {
        let resolved = ResolvedAudioSource(
            mode: .micOnly,
            outputType: .headphones,
            callingApp: nil,
            bundleID: nil
        )
        XCTAssertFalse(
            DualTrackDecision.shouldUseDualTrack(
                resolvedSource: resolved,
                hasScreenRecordingPermission: true
            )
        )
    }

    func testDualTrackFallbackWhenNoScreenRecordingPermission() {
        let resolved = ResolvedAudioSource(
            mode: .dualTrack,
            outputType: .headphones,
            callingApp: "Zoom",
            bundleID: "us.zoom.xos"
        )
        XCTAssertFalse(
            DualTrackDecision.shouldUseDualTrack(
                resolvedSource: resolved,
                hasScreenRecordingPermission: false
            )
        )
    }

    func testDualTrackEnabledWhenCallDetectedAndPermissionGranted() {
        let resolved = ResolvedAudioSource(
            mode: .dualTrack,
            outputType: .headphones,
            callingApp: "Zoom",
            bundleID: "us.zoom.xos"
        )
        XCTAssertTrue(
            DualTrackDecision.shouldUseDualTrack(
                resolvedSource: resolved,
                hasScreenRecordingPermission: true
            )
        )
    }

    // MARK: - shouldProcessSystemAudio

    func testShortRecordingSkipsSystemAudioTranscription() {
        let url = URL(fileURLWithPath: "/tmp/test.wav")
        XCTAssertFalse(
            DualTrackDecision.shouldProcessSystemAudio(
                recordingDuration: 1.5,
                systemAudioURL: url
            )
        )
    }

    func testNilSystemAudioURLSkipsTranscription() {
        XCTAssertFalse(
            DualTrackDecision.shouldProcessSystemAudio(
                recordingDuration: 10.0,
                systemAudioURL: nil
            )
        )
    }

    func testSystemAudioProcessedWhenURLPresentAndDurationSufficient() {
        let url = URL(fileURLWithPath: "/tmp/test.wav")
        XCTAssertTrue(
            DualTrackDecision.shouldProcessSystemAudio(
                recordingDuration: 5.0,
                systemAudioURL: url
            )
        )
    }

    func testBoundaryDurationExactlyTwoSecondsIsProcessed() {
        let url = URL(fileURLWithPath: "/tmp/test.wav")
        XCTAssertTrue(
            DualTrackDecision.shouldProcessSystemAudio(
                recordingDuration: 2.0,
                systemAudioURL: url
            )
        )
    }
}
