// MicrophoneCaptureRecoveryTests.swift
// OpenSuperMLXTests

import XCTest

@testable import OpenSuperMLX

@MainActor
final class MicrophoneCaptureRecoveryTests: XCTestCase {
    func testMissingInputCanRebuildAfterAnEarlierFailure() async {
        let recovery = MicrophoneCaptureRecovery()
        var rebuilds = 0
        let rebuild = {
            rebuilds += 1
            return rebuilds == 2
        }

        let first = await recovery.recover(resume: nil, rebuild: rebuild)
        let second = await recovery.recover(resume: nil, rebuild: rebuild)

        XCTAssertEqual(first, .retryNeeded)
        XCTAssertEqual(second, .restored)
        XCTAssertEqual(rebuilds, 2)
    }

    func testFailedRebuildsStopAfterTheRetryLimit() async {
        let recovery = MicrophoneCaptureRecovery()
        var rebuilds = 0
        let rebuild = {
            rebuilds += 1
            return false
        }

        let first = await recovery.recover(resume: { false }, rebuild: rebuild)
        let second = await recovery.recover(resume: nil, rebuild: rebuild)
        let third = await recovery.recover(resume: nil, rebuild: rebuild)

        XCTAssertEqual(first, .retryNeeded)
        XCTAssertEqual(second, .exhausted)
        XCTAssertEqual(third, .exhausted)
        XCTAssertEqual(rebuilds, 2)

        recovery.reset()
        let restarted = await recovery.recover(resume: nil, rebuild: rebuild)

        XCTAssertEqual(restarted, .retryNeeded)
        XCTAssertEqual(rebuilds, 3)
    }

    func testSuccessfulResumePreservesTheEngineAndRestoresTheRetryBudget() async {
        let recovery = MicrophoneCaptureRecovery()
        var rebuilds = 0
        let first = await recovery.recover(resume: { false }, rebuild: {
            rebuilds += 1
            return false
        })
        let restored = await recovery.recover(resume: { true }, rebuild: {
            rebuilds += 1
            return false
        })
        let next = await recovery.recover(resume: nil, rebuild: {
            rebuilds += 1
            return false
        })

        XCTAssertEqual(first, .retryNeeded)
        XCTAssertEqual(restored, .restored)
        XCTAssertEqual(next, .retryNeeded)
        XCTAssertEqual(rebuilds, 2)
    }

    func testResetDuringRecoverySuppressesStaleFailure() async {
        let recovery = MicrophoneCaptureRecovery()
        let result = await recovery.recover(resume: { false }, rebuild: {
            recovery.reset()
            return false
        })
        let next = await recovery.recover(resume: nil, rebuild: { false })

        XCTAssertEqual(result, .abandon)
        XCTAssertEqual(next, .retryNeeded)
    }
}
