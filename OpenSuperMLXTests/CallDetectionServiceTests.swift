// CallDetectionServiceTests.swift
// OpenSuperMLXTests

import XCTest
@testable import OpenSuperMLX

final class CallDetectionServiceTests: XCTestCase {

    // MARK: - Bundle ID Resolution

    func testChromeHelperResolvesToParent() {
        let result = CallDetectionService.shared.resolveParentBundleID("com.google.Chrome.helper.renderer")
        XCTAssertEqual(result, "com.google.Chrome")
    }

    func testTeamsHelperResolvesToParent() {
        let result = CallDetectionService.shared.resolveParentBundleID("com.microsoft.teams2.helper")
        XCTAssertEqual(result, "com.microsoft.teams2")
    }

    func testZoomBundleIDUnchanged() {
        let result = CallDetectionService.shared.resolveParentBundleID("us.zoom.xos")
        XCTAssertEqual(result, "us.zoom.xos")
    }

    func testDeepNestedHelperResolvesToParent() {
        let result = CallDetectionService.shared.resolveParentBundleID("com.google.Chrome.helper.renderer.gpu")
        XCTAssertEqual(result, "com.google.Chrome")
    }

    func testSlackHelperResolvesToParent() {
        let result = CallDetectionService.shared.resolveParentBundleID("com.tinyspeck.slackmacgap.helper")
        XCTAssertEqual(result, "com.tinyspeck.slackmacgap")
    }

    // MARK: - Process Exclusion

    func testOwnPIDIsExcluded() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        XCTAssertTrue(CallDetectionService.shared.isExcludedProcess(bundleID: "com.example.test", pid: ownPID))
    }

    func testScreenCaptureKitExcluded() {
        XCTAssertTrue(CallDetectionService.shared.isExcludedProcess(bundleID: "com.apple.screencapturekit.something", pid: 999))
    }

    func testReplaydExcluded() {
        XCTAssertTrue(CallDetectionService.shared.isExcludedProcess(bundleID: "com.apple.replayd", pid: 999))
    }

    func testNormalAppNotExcluded() {
        XCTAssertFalse(CallDetectionService.shared.isExcludedProcess(bundleID: "us.zoom.xos", pid: 999))
    }

    // MARK: - Detection Result

    func testDetectActiveCallReturnsResult() {
        let result = CallDetectionService.shared.detectActiveCall()
        XCTAssertNotNil(result)
        // In test environment without active calls, expect no call detected
        // (This validates the method runs without crashing on CoreAudio queries)
    }
}
