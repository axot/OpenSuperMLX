// DeviceDisconnectTests.swift
// OpenSuperMLXTests

import XCTest
@testable import OpenSuperMLX

final class DeviceDisconnectTests: XCTestCase {

    // MARK: - Notification Name

    func testMicrophoneDisconnectedNotificationExists() {
        let name = Notification.Name.microphoneDisconnected
        XCTAssertEqual(name.rawValue, "microphoneDisconnected")
    }

    // MARK: - Device Availability

    func testDisconnectedDeviceNotInAvailableList() {
        let service = MicrophoneService.shared
        let fakeDevice = MicrophoneService.AudioDevice(
            id: "nonexistent-device-id",
            name: "Phantom Mic",
            manufacturer: nil,
            isBuiltIn: false
        )
        XCTAssertFalse(service.isDeviceAvailable(fakeDevice))
    }

    func testAvailableMicrophoneIsDetected() {
        let service = MicrophoneService.shared
        guard let mic = service.availableMicrophones.first else {
            XCTSkip("No microphones available")
            return
        }
        XCTAssertTrue(service.isDeviceAvailable(mic))
    }
}
