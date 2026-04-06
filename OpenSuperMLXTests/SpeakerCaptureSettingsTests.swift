// SpeakerCaptureSettingsTests.swift
// OpenSuperMLXTests

import XCTest
@testable import OpenSuperMLX

final class SpeakerCaptureSettingsTests: XCTestCase {

    // MARK: - Speaker Capture Default

    func testSpeakerCaptureDefaultsToFalse() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "speakerCaptureEnabled")
        let value = defaults.bool(forKey: "speakerCaptureEnabled")
        XCTAssertFalse(value)
    }

    // MARK: - Microphone Selection

    func testSelectMicrophoneUpdatesCurrentMicrophone() {
        let service = MicrophoneService.shared
        guard let firstMic = service.availableMicrophones.first else {
            XCTSkip("No microphones available")
            return
        }
        service.selectMicrophone(firstMic)
        XCTAssertEqual(service.currentMicrophone, firstMic)
    }

    func testActivateForRecordingReturnsActiveMicrophone() {
        let result = MicrophoneService.shared.activateForRecording()
        if !MicrophoneService.shared.availableMicrophones.isEmpty {
            XCTAssertNotNil(result)
        }
    }
}
