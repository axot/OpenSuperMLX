// AppUpdaterTests.swift
// OpenSuperMLXTests

import Combine
import XCTest

@testable import OpenSuperMLX

// MARK: - UpdateDeferral

@MainActor
final class UpdateDeferralTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    func testRelaunchIsReadyOnlyAfterIdleSettles() {
        let deferral = UpdateDeferral()
        deferral.setBusy(true, now: start)
        XCTAssertFalse(deferral.isReady(.relaunch, now: start, secondsSinceInput: 60))

        deferral.setBusy(false, now: start)
        XCTAssertFalse(deferral.isReady(.relaunch, now: start.addingTimeInterval(1), secondsSinceInput: 60))
        XCTAssertTrue(deferral.isReady(.relaunch, now: start.addingTimeInterval(2), secondsSinceInput: 60))
    }

    func testShowUpdateAlsoWaitsForInputToPause() {
        let deferral = UpdateDeferral()

        XCTAssertTrue(deferral.isReady(.relaunch, now: start, secondsSinceInput: 1))
        XCTAssertFalse(deferral.isReady(.showUpdate, now: start, secondsSinceInput: 1))
        XCTAssertTrue(deferral.isReady(.showUpdate, now: start, secondsSinceInput: 5))
    }

    func testDeferredActionRunsOnceWhenReady() {
        let deferral = UpdateDeferral()
        var runs = 0
        deferral.setBusy(true, now: start)
        XCTAssertTrue(deferral.deferUnlessReady(.relaunch, now: start, secondsSinceInput: 60) { runs += 1 })

        deferral.setBusy(false, now: start)
        deferral.runReady(now: start.addingTimeInterval(1), secondsSinceInput: 60)
        XCTAssertEqual(runs, 0)
        deferral.runReady(now: start.addingTimeInterval(2), secondsSinceInput: 60)
        deferral.runReady(now: start.addingTimeInterval(3), secondsSinceInput: 60)
        XCTAssertEqual(runs, 1)
        XCTAssertFalse(deferral.hasPending)
    }

    func testBusyAgainBeforeSettlingRestartsTheWait() {
        let deferral = UpdateDeferral()
        var runs = 0
        deferral.setBusy(true, now: start)
        deferral.deferUnlessReady(.relaunch, now: start, secondsSinceInput: 60) { runs += 1 }

        deferral.setBusy(false, now: start)
        deferral.setBusy(true, now: start.addingTimeInterval(1))
        deferral.setBusy(false, now: start.addingTimeInterval(4))
        deferral.runReady(now: start.addingTimeInterval(5), secondsSinceInput: 60)
        XCTAssertEqual(runs, 0)

        deferral.runReady(now: start.addingTimeInterval(6), secondsSinceInput: 60)
        XCTAssertEqual(runs, 1)
    }

    func testDeferringSameActionAgainKeepsOnlyLatest() {
        let deferral = UpdateDeferral()
        var calls: [String] = []
        deferral.setBusy(true, now: start)

        deferral.deferUnlessReady(.showUpdate, now: start, secondsSinceInput: 60) { calls.append("first") }
        deferral.deferUnlessReady(.showUpdate, now: start, secondsSinceInput: 60) { calls.append("second") }
        deferral.setBusy(false, now: start)
        deferral.runReady(now: start.addingTimeInterval(2), secondsSinceInput: 60)

        XCTAssertEqual(calls, ["second"])
    }

    func testCancelDropsDeferredAction() {
        let deferral = UpdateDeferral()
        var calls: [String] = []
        deferral.setBusy(true, now: start)
        deferral.deferUnlessReady(.showUpdate, now: start, secondsSinceInput: 60) { calls.append("show") }
        deferral.deferUnlessReady(.relaunch, now: start, secondsSinceInput: 60) { calls.append("relaunch") }

        deferral.cancel(.showUpdate)
        deferral.setBusy(false, now: start)
        deferral.runReady(now: start.addingTimeInterval(2), secondsSinceInput: 60)

        XCTAssertEqual(calls, ["relaunch"])
    }
}

// MARK: - AppUpdater

@MainActor
final class AppUpdaterTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_000)
    private var secondsSinceInput: TimeInterval = 60
    private var shownCount = 0
    private var quitCount = 0
    private let busy = CurrentValueSubject<Bool, Never>(false)

    private func makeUpdater() -> AppUpdater {
        let updater = AppUpdater(
            now: { [unowned self] in clock },
            secondsSinceUserInput: { [unowned self] in secondsSinceInput },
            presentUpdate: { [unowned self] in shownCount += 1 },
            quit: { [unowned self] in quitCount += 1 }
        )
        updater.observeBusy(busy.eraseToAnyPublisher())
        return updater
    }

    private func finishBusyAndSettle(_ updater: AppUpdater) {
        busy.send(false)
        clock = clock.addingTimeInterval(UpdateDeferral.settleInterval)
        updater.runReadyActions()
    }

    func testScheduledUpdateShowsRightAwayWhenIdleAndQuiet() {
        let updater = makeUpdater()

        updater.handleScheduledUpdate()

        XCTAssertEqual(shownCount, 1)
    }

    func testScheduledUpdateWaitsUntilRecordingEndsAndSettles() {
        let updater = makeUpdater()
        busy.send(true)

        updater.handleScheduledUpdate()
        busy.send(false)
        updater.runReadyActions()
        XCTAssertEqual(shownCount, 0)

        clock = clock.addingTimeInterval(UpdateDeferral.settleInterval)
        updater.runReadyActions()
        XCTAssertEqual(shownCount, 1)
    }

    func testScheduledUpdateWaitsWhileUserIsTyping() {
        let updater = makeUpdater()
        secondsSinceInput = 1

        updater.handleScheduledUpdate()
        updater.runReadyActions()
        XCTAssertEqual(shownCount, 0)

        secondsSinceInput = UpdateDeferral.inputQuietInterval
        updater.runReadyActions()
        XCTAssertEqual(shownCount, 1)
    }

    func testUserAttentionCancelsPendingScheduledUpdate() {
        let updater = makeUpdater()
        busy.send(true)
        updater.handleScheduledUpdate()

        updater.cancelScheduledUpdate()
        finishBusyAndSettle(updater)

        XCTAssertEqual(shownCount, 0)
    }

    func testRelaunchIsPostponedWhileBusyThenInstalls() {
        let updater = makeUpdater()
        var installs = 0
        busy.send(true)

        XCTAssertTrue(updater.handleRelaunchRequest { installs += 1 })
        XCTAssertEqual(installs, 0)

        finishBusyAndSettle(updater)
        XCTAssertEqual(installs, 1)
    }

    func testQuitForUpdateWaitsForRecordingStartedDuringRelaunch() {
        let updater = makeUpdater()
        XCTAssertFalse(updater.handleRelaunchRequest {})
        busy.send(true)

        XCTAssertTrue(updater.holdsTerminationForUpdate())
        XCTAssertEqual(quitCount, 0)

        finishBusyAndSettle(updater)
        XCTAssertEqual(quitCount, 1)
    }

    func testOrdinaryQuitIsNotHeld() {
        let updater = makeUpdater()
        busy.send(true)

        XCTAssertFalse(updater.holdsTerminationForUpdate())
    }
}
