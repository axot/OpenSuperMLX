// PreparedMicrophoneInputTests.swift
// OpenSuperMLXTests

import CoreAudio
import XCTest

@testable import OpenSuperMLX

final class PreparedMicrophoneInputTests: XCTestCase {
    private final class Engine: MicrophoneInputEngine {
        var isRunning = false
        var boundDeviceID: AudioDeviceID? = 109
        var format: EngineInitFormat? = EngineInitFormat(
            sampleRate: 48000, channelCount: 1, isInterleaved: false
        )
        var configurationObject: AnyObject { self }
        var hardwareIsRunning: Bool { isRunning }
        var prepares = 0
        var starts = 0
        var pauses = 0
        var stops = 0
        var stopsDuringStart = false

        func prepare() { prepares += 1 }
        func start() throws {
            starts += 1
            isRunning = !stopsDuringStart
        }
        func pause() {
            pauses += 1
            isRunning = false
        }
        func stop() {
            stops += 1
            isRunning = false
        }
    }

    private func makeInput(_ engine: Engine) -> PreparedMicrophoneInput {
        PreparedMicrophoneInput(
            targetDeviceID: 109, engine: engine,
            buffer: MicrophoneCaptureBuffer(capacity: 16)
        )
    }

    private func receive(_ samples: [Float], into input: PreparedMicrophoneInput) {
        samples.withUnsafeBufferPointer {
            input.buffer.receive($0, hostTime: 10, sampleRate: 48000, deliveredAt: 20)
        }
    }

    func testPreparingValidInputDoesNotStartMicrophoneHardware() {
        let engine = Engine()
        let input = makeInput(engine)

        XCTAssertEqual(input.prepare(), .commit(nativeSampleRate: 48000))
        XCTAssertEqual(engine.prepares, 1)
        XCTAssertEqual(engine.starts, 0)
        XCTAssertFalse(engine.hardwareIsRunning)
    }

    func testResumeStartsExistingPreparedEngine() {
        let engine = Engine()
        let input = makeInput(engine)
        _ = input.prepare()

        XCTAssertEqual(input.start(at: 10), .commit(nativeSampleRate: 48000))
        XCTAssertEqual(engine.starts, 1)
        XCTAssertEqual(engine.prepares, 1)
    }

    func testConfigurationRecoveryPreservesAcceptedStartupAudio() {
        let engine = Engine()
        let input = makeInput(engine)
        _ = input.start(at: 10)
        receive([1, 2], into: input)
        engine.isRunning = false

        XCTAssertEqual(input.resume(), .commit(nativeSampleRate: 48000))
        XCTAssertEqual(engine.starts, 2)
        XCTAssertEqual(input.buffer.drain(), [1, 2])

        receive([3], into: input)
        XCTAssertEqual(input.restart(), .commit(nativeSampleRate: 48000))
        XCTAssertEqual(engine.pauses, 1)
        XCTAssertEqual(engine.starts, 3)
        XCTAssertEqual(input.buffer.drain(), [3])
    }

    func testChangedBindingIsRejectedBeforeRestart() {
        let engine = Engine()
        let input = makeInput(engine)
        _ = input.start(at: 10)
        engine.isRunning = false
        engine.boundDeviceID = 105

        XCTAssertEqual(input.resume(), .failExplicit(.deviceReverted))
        XCTAssertEqual(engine.starts, 1)
        XCTAssertFalse(engine.hardwareIsRunning)

        engine.boundDeviceID = 109
        input.pause()
        XCTAssertEqual(input.resume(), .abandon)
        XCTAssertEqual(engine.starts, 1)
    }

    func testEngineStoppedDuringStartIsNotAccepted() {
        let engine = Engine()
        engine.stopsDuringStart = true
        let input = makeInput(engine)

        guard case .failExplicit(.engineStartFailed) = input.start(at: 10) else {
            return XCTFail("A stopped engine must not be committed")
        }
        XCTAssertFalse(engine.hardwareIsRunning)
    }

    func testPauseStopsIOAndPreservesPreparedResourcesAndTailAudio() {
        let engine = Engine()
        let input = makeInput(engine)
        _ = input.start(at: 10)
        receive([1], into: input)

        input.pause()
        receive([2], into: input)

        XCTAssertEqual(engine.pauses, 1)
        XCTAssertEqual(engine.stops, 0)
        XCTAssertFalse(engine.hardwareIsRunning)
        XCTAssertEqual(input.buffer.drain(), [1])
    }

    func testInvalidFormatRejectsPreparationAndStart() {
        let engine = Engine()
        engine.format = EngineInitFormat(sampleRate: 0, channelCount: 0, isInterleaved: false)
        let input = makeInput(engine)

        XCTAssertEqual(input.prepare(), .failExplicit(.invalidGraphFormat))
        XCTAssertEqual(input.start(at: 10), .failExplicit(.invalidGraphFormat))
        XCTAssertEqual(engine.starts, 0)
    }

    func testChangedFormatRequiresGraphPreparationBeforeRestart() {
        let engine = Engine()
        let input = makeInput(engine)
        _ = input.prepare()
        _ = input.start(at: 10)
        engine.isRunning = false
        engine.format = EngineInitFormat(sampleRate: 96000, channelCount: 1, isInterleaved: false)

        XCTAssertEqual(input.resume(), .failExplicit(.invalidGraphFormat))
        XCTAssertEqual(engine.starts, 1)
    }
}
