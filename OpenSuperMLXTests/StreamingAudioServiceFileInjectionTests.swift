// StreamingAudioServiceFileInjectionTests.swift
// OpenSuperMLXTests

import XCTest

@testable import OpenSuperMLX

@MainActor
final class StreamingAudioServiceFileInjectionTests: XCTestCase {

    private var sut: StreamingAudioService!

    override func setUp() async throws {
        try await super.setUp()
        sut = StreamingAudioService.shared
        sut.clearRingBuffer()
    }

    override func tearDown() async throws {
        sut.clearRingBuffer()
        sut = nil
        try await super.tearDown()
    }

    // MARK: - Ring Buffer Write

    func testInjectWritesToRingBuffer() {
        let samples = [Float](repeating: 0.5, count: 16000)
        let chunksFed = sut.writeRawSamplesToRingBuffer(samples, chunkDuration: 0.5)

        XCTAssertEqual(chunksFed, 2)
        XCTAssertEqual(sut.ringBufferSampleCount, 16000 + 10560)
    }

    // MARK: - Tail Silence

    func testInjectAppendsTailSilence() {
        let sampleCount = 8000
        let samples = [Float](repeating: 0.1, count: sampleCount)
        _ = sut.writeRawSamplesToRingBuffer(samples, chunkDuration: 0.5)

        XCTAssertEqual(sut.ringBufferSampleCount, sampleCount + 10560)
    }

    // MARK: - No Audio Engine

    func testInjectDoesNotInitializeAudioEngine() throws {
        try XCTSkipIf(
            sut.isAudioEngineInitialized,
            "Audio engine already initialized by another test"
        )

        let samples = [Float](repeating: 0.5, count: 8000)
        _ = sut.writeRawSamplesToRingBuffer(samples, chunkDuration: 0.5)

        XCTAssertFalse(sut.isAudioEngineInitialized)
    }
}
