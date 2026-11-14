// StreamingAudioServiceStartupTests.swift
// OpenSuperMLXTests

import XCTest

@testable import OpenSuperMLX

final class StreamingAudioServiceStartupTests: XCTestCase {
    func testRejectedCompetingStartCannotEndAPendingForeignCapture() {
        let gate = EngineInitGate()
        let generation = gate.beginRequest(targetUID: "recording")
        let claim = MicrophoneCaptureClaim(existingGeneration: generation, isReady: false)

        if let owned = claim.generationToEnd(currentGeneration: generation) {
            gate.endRequest(generation: owned)
        }

        XCTAssertTrue(gate.shouldCommit(generation: generation, targetUID: "recording"))
    }

    func testReadyPreopenedCaptureCanBeAdoptedAndReleasedOnFailure() {
        let gate = EngineInitGate()
        let generation = gate.beginRequest(targetUID: "recording")
        let claim = MicrophoneCaptureClaim(existingGeneration: generation, isReady: true)

        let owned = claim.generationToEnd(currentGeneration: generation)
        XCTAssertEqual(owned, generation)
        if let owned { gate.endRequest(generation: owned) }

        XCTAssertFalse(gate.shouldCommit(generation: generation, targetUID: "recording"))
    }

    func testNewlyStartedCaptureIsOwnedOnlyAfterSuccessfulStart() {
        var claim = MicrophoneCaptureClaim(existingGeneration: nil, isReady: false)
        XCTAssertNil(claim.generationToEnd(currentGeneration: 5))

        claim.claim(5)

        XCTAssertEqual(claim.generationToEnd(currentGeneration: 5), 5)
        XCTAssertNil(claim.generationToEnd(currentGeneration: 6))
        XCTAssertNil(claim.generationToEnd(currentGeneration: nil))
        XCTAssertEqual(claim.generationToAbort(currentGeneration: 5, isStreaming: false, hasPendingStart: false), 5)
        XCTAssertNil(claim.generationToAbort(currentGeneration: 5, isStreaming: true, hasPendingStart: false))
        XCTAssertNil(claim.generationToAbort(currentGeneration: 5, isStreaming: false, hasPendingStart: true))
        XCTAssertNil(claim.generationToAbort(currentGeneration: 6, isStreaming: false, hasPendingStart: false))
    }
}
