// RecordingActivityTests.swift
// OpenSuperMLXTests

import XCTest

@testable import OpenSuperMLX

@MainActor
final class RecordingActivityTests: XCTestCase {

    func testActiveWhileAnyOwnerIsActive() {
        let activity = RecordingActivity()
        let indicator = NSObject()
        let mainWindow = NSObject()

        activity.report(indicator, isActive: true)
        activity.report(mainWindow, isActive: true)
        activity.report(indicator, isActive: false)
        XCTAssertTrue(activity.isActive)

        activity.report(mainWindow, isActive: false)
        XCTAssertFalse(activity.isActive)
    }

    func testRepeatedReportsFromOneOwnerCountOnce() {
        let activity = RecordingActivity()
        let owner = NSObject()

        activity.report(owner, isActive: true)
        activity.report(owner, isActive: true)
        activity.report(owner, isActive: false)

        XCTAssertFalse(activity.isActive)
    }

    func testDeallocatedOwnerStopsCountingOnNextReport() {
        let activity = RecordingActivity()
        let survivor = NSObject()
        var discarded: NSObject? = NSObject()
        activity.report(discarded!, isActive: true)

        discarded = nil
        activity.report(survivor, isActive: false)

        XCTAssertFalse(activity.isActive)
    }
}
