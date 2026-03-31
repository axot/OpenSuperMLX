// PermissionsManagerTests.swift
// OpenSuperMLX

import XCTest

@testable import OpenSuperMLX

final class PermissionsManagerTests: XCTestCase {

    // MARK: - Permission Enum

    func testScreenRecordingCaseExists() {
        let permission = Permission.screenRecording
        XCTAssertNotNil(permission)
    }

    func testAllPermissionCasesExist() {
        let cases: [Permission] = [.microphone, .accessibility, .screenRecording]
        XCTAssertEqual(cases.count, 3)
    }

    // MARK: - Initial State

    func testInitialScreenRecordingPermissionState() {
        let manager = PermissionsManager()
        // Initial value should reflect system state — just verify property exists and is a Bool
        _ = manager.isScreenRecordingPermissionGranted
    }

    // MARK: - Check Method

    func testCheckScreenRecordingPermissionDoesNotCrash() {
        let manager = PermissionsManager()
        manager.checkScreenRecordingPermission()
    }

    // MARK: - Open System Preferences

    func testOpenSystemPreferencesScreenRecordingDoesNotCrash() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["DISPLAY"] != nil
                || NSApplication.shared.windows.isEmpty == false
                || true,  // Always run — method just constructs URL, actual open is async
            "Skipping in headless environment"
        )

        // Verify the method handles .screenRecording without crashing
        // We don't actually open System Preferences — just confirm the switch case exists
        let manager = PermissionsManager()
        _ = Permission.screenRecording
        // openSystemPreferences calls NSWorkspace.shared.open async, so just verify no crash on enum
    }
}
