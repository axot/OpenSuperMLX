// EngineInitTransactionTests.swift
// OpenSuperMLXTests

import AVFoundation
import CoreAudio
import XCTest

@testable import OpenSuperMLX

final class EngineInitTransactionTests: XCTestCase {

    // MARK: - evaluate

    func testCommitWhenBoundDeviceMatchesTargetAndFormatsSane() {
        let observation = EngineInitObservation(
            engineRunning: true,
            startErrorDescription: nil,
            boundDeviceID: 109,
            targetDeviceID: 109,
            deviceSideFormat: EngineInitFormat(sampleRate: 48000, channelCount: 2, isInterleaved: false)
        )

        XCTAssertEqual(
            EngineInitTransaction.evaluate(observation),
            .commit(nativeSampleRate: 48000)
        )
    }

    func testFailExplicitWhenDeviceRevertsAfterStart() {
        let observation = EngineInitObservation(
            engineRunning: true,
            startErrorDescription: nil,
            boundDeviceID: 105,
            targetDeviceID: 109,
            deviceSideFormat: EngineInitFormat(sampleRate: 48000, channelCount: 1, isInterleaved: false)
        )

        XCTAssertEqual(
            EngineInitTransaction.evaluate(observation),
            .failExplicit(.deviceReverted)
        )
    }

    func testFailExplicitWhenDeviceSideFormatDegenerate() {
        let sane = EngineInitFormat(sampleRate: 48000, channelCount: 1, isInterleaved: false)
        let degenerateFormats: [EngineInitFormat?] = [
            nil,
            EngineInitFormat(sampleRate: 0, channelCount: 1, isInterleaved: false),
            EngineInitFormat(sampleRate: 48000, channelCount: 0, isInterleaved: false),
            EngineInitFormat(sampleRate: 48000, channelCount: 2, isInterleaved: true),
        ]
        for format in degenerateFormats {
            let observation = EngineInitObservation(
                engineRunning: true,
                startErrorDescription: nil,
                boundDeviceID: 109,
                targetDeviceID: 109,
                deviceSideFormat: format
            )
            XCTAssertEqual(
                EngineInitTransaction.evaluate(observation),
                .failExplicit(.invalidGraphFormat),
                "format \(String(describing: format)) must fail the transaction"
            )
        }
    }

    func testFailExplicitWhenEngineFailedToStart() {
        let observation = EngineInitObservation(
            engineRunning: false,
            startErrorDescription: "required condition is false: format.sampleRate > 0",
            boundDeviceID: nil,
            targetDeviceID: 109,
            deviceSideFormat: nil
        )

        XCTAssertEqual(
            EngineInitTransaction.evaluate(observation),
            .failExplicit(.engineStartFailed("required condition is false: format.sampleRate > 0"))
        )
    }

    func testFailExplicitWhenTargetDeviceUnresolvable() {
        let observation = EngineInitObservation(
            engineRunning: true,
            startErrorDescription: nil,
            boundDeviceID: nil,
            targetDeviceID: nil,
            deviceSideFormat: EngineInitFormat(sampleRate: 48000, channelCount: 1, isInterleaved: false)
        )

        XCTAssertEqual(
            EngineInitTransaction.evaluate(observation),
            .failExplicit(.deviceUnresolvable)
        )
    }

    func testFailExplicitWhenDeviceBindFails() {
        let observation = EngineInitObservation(
            engineRunning: false,
            startErrorDescription: nil,
            boundDeviceID: nil,
            targetDeviceID: 109,
            deviceSideFormat: nil,
            bindFailedStatus: -50
        )

        XCTAssertEqual(
            EngineInitTransaction.evaluate(observation),
            .failExplicit(.bindFailed(-50))
        )
    }

    func testAbandonBeatsFailureWhenCancelled() {
        var observation = EngineInitObservation(
            engineRunning: true,
            startErrorDescription: nil,
            boundDeviceID: 105,
            targetDeviceID: 109,
            deviceSideFormat: EngineInitFormat(sampleRate: 48000, channelCount: 1, isInterleaved: false)
        )
        observation.cancelled = true

        XCTAssertEqual(EngineInitTransaction.evaluate(observation), .abandon)
    }

    func testAbandonBeatsBindFailureWhenCancelled() {
        var observation = EngineInitObservation(
            engineRunning: false,
            startErrorDescription: nil,
            boundDeviceID: nil,
            targetDeviceID: 109,
            deviceSideFormat: nil,
            bindFailedStatus: -50
        )
        observation.cancelled = true

        XCTAssertEqual(EngineInitTransaction.evaluate(observation), .abandon)
    }

    // MARK: - EngineInitGate

    func testTargetChangeBumpsGenerationAndInvalidatesOldAttempt() {
        let gate = EngineInitGate()

        let generationA = gate.beginRequest(targetUID: "usb-mic")
        XCTAssertTrue(gate.shouldCommit(generation: generationA, targetUID: "usb-mic"))

        let generationB = gate.beginRequest(targetUID: "bt-headset")
        XCTAssertNotEqual(generationA, generationB, "a target change must supersede the in-flight attempt")
        XCTAssertFalse(
            gate.shouldCommit(generation: generationA, targetUID: "usb-mic"),
            "the superseded attempt must not commit"
        )
        XCTAssertTrue(gate.shouldCommit(generation: generationB, targetUID: "bt-headset"))
    }

    func testSameTargetRequestsShareGeneration() {
        let gate = EngineInitGate()

        let first = gate.beginRequest(targetUID: "usb-mic")
        let second = gate.beginRequest(targetUID: "usb-mic")

        XCTAssertEqual(first, second, "concurrent same-target requests must share one init")
        XCTAssertTrue(gate.shouldCommit(generation: first, targetUID: "usb-mic"))
    }

    func testEndRequestClearsInFlightTargetOnlyForCurrentGeneration() {
        let gate = EngineInitGate()

        let generationA = gate.beginRequest(targetUID: "usb-mic")
        let generationB = gate.beginRequest(targetUID: "bt-headset")
        gate.endRequest(generation: generationA)

        XCTAssertTrue(gate.shouldCommit(generation: generationB, targetUID: "bt-headset"))

        gate.endRequest(generation: generationB)
        let generationC = gate.beginRequest(targetUID: "usb-mic")
        XCTAssertTrue(gate.shouldCommit(generation: generationC, targetUID: "usb-mic"))
    }

    func testCancelInFlightInvalidatesCurrentAttempt() {
        let gate = EngineInitGate()

        let generation = gate.beginRequest(targetUID: "usb-mic")
        gate.cancelInFlight()

        XCTAssertFalse(
            gate.shouldCommit(generation: generation, targetUID: "usb-mic"),
            "cool-down during init must invalidate the in-flight attempt"
        )

        let fresh = gate.beginRequest(targetUID: "usb-mic")
        XCTAssertTrue(gate.shouldCommit(generation: fresh, targetUID: "usb-mic"))
    }

    // MARK: - Join / teardown

    func testJoinOnlyWhenSameTargetTaskIsStillRunning() {
        XCTAssertEqual(
            EngineInitTransaction.joinDecision(hasInFlightTask: true, sameTarget: true, isCancelled: false),
            .join
        )
        XCTAssertEqual(
            EngineInitTransaction.joinDecision(hasInFlightTask: true, sameTarget: true, isCancelled: true),
            .startFresh,
            "coolDown-cancelled init must not be rejoined"
        )
        XCTAssertEqual(
            EngineInitTransaction.joinDecision(hasInFlightTask: true, sameTarget: false, isCancelled: false),
            .startFresh
        )
        XCTAssertEqual(
            EngineInitTransaction.joinDecision(hasInFlightTask: false, sameTarget: true, isCancelled: false),
            .startFresh
        )
    }

    func testUnadoptedRunningEngineMustBeTornDown() {
        XCTAssertTrue(EngineInitTransaction.shouldTeardownUnadoptedEngine(engineRunning: true, tapInstalled: false))
        XCTAssertTrue(EngineInitTransaction.shouldTeardownUnadoptedEngine(engineRunning: false, tapInstalled: true))
        XCTAssertFalse(EngineInitTransaction.shouldTeardownUnadoptedEngine(engineRunning: false, tapInstalled: false))
    }
}
