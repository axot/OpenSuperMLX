// StreamingAudioServiceArchiveTests.swift
// OpenSuperMLXTests

import XCTest

@testable import OpenSuperMLX

final class StreamingAudioServiceArchiveTests: XCTestCase {

    func testSamplesWithinThresholdAreIdenticalForArchiveAndInference() {
        let samples = (0..<80_000).map(Float.init)

        let split = StreamingAudioService.splitArchiveAndInferenceSamples(samples)

        XCTAssertEqual(split.archive, samples)
        XCTAssertEqual(split.inference, samples)
    }

    func testBackpressureDropsOnlyInferenceSamples() {
        let samples = (0..<96_000).map(Float.init)

        let split = StreamingAudioService.splitArchiveAndInferenceSamples(samples)

        XCTAssertEqual(split.archive, samples)
        XCTAssertEqual(split.inference, Array(samples.suffix(16_000)))
    }

    func testEmptySamplesProduceEmptyBranches() {
        let split = StreamingAudioService.splitArchiveAndInferenceSamples([])

        XCTAssertTrue(split.archive.isEmpty)
        XCTAssertTrue(split.inference.isEmpty)
    }

    func testFinalMixIncludesLongerMicrophoneTail() {
        let mixer = AudioMixer(inputSampleRate: 16_000)
        let mic = [Float](repeating: 0.2, count: 2_000)
        let system = [Float](repeating: 0.3, count: 1_600)

        let samples = StreamingAudioService.makeFinalMixedSamples(
            mixer: mixer,
            microphone: mic,
            microphoneSampleRate: 16_000,
            system: system,
            systemSampleRate: 16_000,
            speakerCaptureActive: true
        )

        XCTAssertEqual(samples.count, 2_000)
    }

    func testFinalMixIncludesLongerSystemTail() {
        let mixer = AudioMixer(inputSampleRate: 16_000)
        let mic = [Float](repeating: 0.2, count: 1_600)
        let system = [Float](repeating: 0.3, count: 2_000)

        let samples = StreamingAudioService.makeFinalMixedSamples(
            mixer: mixer,
            microphone: mic,
            microphoneSampleRate: 16_000,
            system: system,
            systemSampleRate: 16_000,
            speakerCaptureActive: true
        )

        XCTAssertEqual(samples.count, 2_000)
    }
}
