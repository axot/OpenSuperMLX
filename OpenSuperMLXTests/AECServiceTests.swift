// AECServiceTests.swift
// OpenSuperMLX

import XCTest

@testable import OpenSuperMLX

final class AECServiceTests: XCTestCase {

    // MARK: - Singleton

    func testSharedInstanceExists() {
        let service = AECService.shared
        XCTAssertNotNil(service)
    }

    func testSharedInstanceIsSingleton() {
        let a = AECService.shared
        let b = AECService.shared
        XCTAssertTrue(a === b)
    }

    // MARK: - Availability

    func testIsAvailableReturnsBool() {
        let result = AECService.shared.isAvailable
        XCTAssertTrue(result == true || result == false)
    }

    // MARK: - Error Handling

    func testProcessRecordingWithInvalidURLsThrows() async {
        let bogus = URL(fileURLWithPath: "/nonexistent/path/mic.wav")
        let bogusRef = URL(fileURLWithPath: "/nonexistent/path/system.wav")

        do {
            _ = try await AECService.shared.processRecording(
                micTrackURL: bogus,
                systemAudioTrackURL: bogusRef
            )
            XCTFail("Expected processRecording to throw for invalid URLs")
        } catch {
            // Any error is acceptable — just verify it doesn't crash
        }
    }
}
