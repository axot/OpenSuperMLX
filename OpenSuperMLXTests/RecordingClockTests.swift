// RecordingClockTests.swift
// OpenSuperMLXTests

import XCTest

@testable import OpenSuperMLX

final class RecordingClockTests: XCTestCase {
    func testInputRecoveryPreservesElapsedRecordingTime() {
        var clock = RecordingClock()
        clock.start(at: Date(timeIntervalSince1970: 10))
        clock.stop(reset: false)
        clock.start(at: Date(timeIntervalSince1970: 20))

        XCTAssertEqual(clock.elapsed(at: Date(timeIntervalSince1970: 25)), 15)
    }

    func testRealStopResetsTheNextRecordingOrigin() {
        var clock = RecordingClock()
        clock.start(at: Date(timeIntervalSince1970: 10))
        clock.stop()
        XCTAssertEqual(clock.elapsed(at: Date(timeIntervalSince1970: 20)), 0)
        clock.start(at: Date(timeIntervalSince1970: 30))

        XCTAssertEqual(clock.elapsed(at: Date(timeIntervalSince1970: 35)), 5)
    }

    func testRepeatedReadyEventsAndClockBoundariesDoNotChangeTheOrigin() {
        var clock = RecordingClock()
        XCTAssertEqual(clock.elapsed(), 0)
        clock.start(at: Date(timeIntervalSince1970: 10))
        clock.start(at: Date(timeIntervalSince1970: 20))

        XCTAssertEqual(clock.elapsed(at: Date(timeIntervalSince1970: 5)), 0)
        XCTAssertEqual(clock.elapsed(at: Date(timeIntervalSince1970: 25)), 15)
    }
}
