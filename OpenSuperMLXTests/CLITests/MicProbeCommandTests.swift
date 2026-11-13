// MicProbeCommandTests.swift
// OpenSuperMLXTests

import XCTest

@testable import OpenSuperMLX

final class MicProbeCommandTests: XCTestCase {
    func testProbeRequiresEveryDeliveryBelowOneHundredMilliseconds() {
        XCTAssertTrue(MicProbeResult(
            trials: [MicProbeTrial(firstDeliveryMS: 99.9, idleCallbacks: 0, idleHardwareRunning: false)]
        ).passed)
        XCTAssertFalse(MicProbeResult(
            trials: [MicProbeTrial(firstDeliveryMS: 100, idleCallbacks: 0, idleHardwareRunning: false)]
        ).passed)
    }

    func testProbeRejectsMissingAudioAndEmptyResults() {
        XCTAssertFalse(MicProbeResult(trials: []).passed)
        XCTAssertFalse(MicProbeResult(
            trials: [MicProbeTrial(firstDeliveryMS: nil, idleCallbacks: 0, idleHardwareRunning: false)]
        ).passed)
    }

    func testProbeRejectsInputActivityDuringIdle() {
        for trial in [
            MicProbeTrial(firstDeliveryMS: 60, idleCallbacks: 1, idleHardwareRunning: false),
            MicProbeTrial(firstDeliveryMS: 60, idleCallbacks: 0, idleHardwareRunning: true),
        ] {
            XCTAssertFalse(MicProbeResult(trials: [trial]).passed)
        }
    }
}
