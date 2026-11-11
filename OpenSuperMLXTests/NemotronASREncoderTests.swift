// NemotronASREncoderTests.swift
// OpenSuperMLXTests

import XCTest

import MLX
@testable import MLXAudioSTT

final class NemotronASREncoderTests: XCTestCase {

    private var encoder: NemotronASREncoder!

    override func setUpWithError() throws {
        MLXRandom.seed(11)
        encoder = NemotronASREncoder(config: try NemotronASRFixtures.config().encoder)
    }

    // MARK: - Subsampling

    func testCausalSubsamplingReducesTimeEightfold() {
        let output = encoder.preEncode(MLXRandom.normal([1, 100, 16]))

        XCTAssertEqual(output.shape, [1, 14, 32])
    }

    // MARK: - Streaming State

    func testStreamingEmitsEveryOfflineFrame() {
        let mel = MLXRandom.normal([1, 100, 16])
        let state = NemotronEncoderStreamingState(encoder: encoder, attContextSize: [4, 1])

        let frames = state.push(mel, final: true).reduce(0) { $0 + $1.shape[1] }

        XCTAssertEqual(frames, encoder.preEncode(mel).shape[1])
    }

    func testOutputDoesNotDependOnHowMelIsPushed() {
        let mel = MLXRandom.normal([1, 100, 16])
        let whole = NemotronEncoderStreamingState(encoder: encoder, attContextSize: [4, 1])
        let pieces = NemotronEncoderStreamingState(encoder: encoder, attContextSize: [4, 1])

        let expected = MLX.concatenated(whole.push(mel, final: true), axis: 1)
        let actual = MLX.concatenated(
            pieces.push(mel[0..., ..<37, 0...], final: false)
                + pieces.push(mel[0..., 37..<38, 0...], final: false)
                + pieces.push(mel[0..., 38..., 0...], final: true),
            axis: 1
        )

        XCTAssertEqual(actual.shape, expected.shape)
        XCTAssertTrue(MLX.allClose(actual, expected, rtol: 1e-5, atol: 1e-5).item(Bool.self))
    }

    func testIncompleteChunkWaitsForMoreMelUnlessFinal() {
        let state = NemotronEncoderStreamingState(encoder: encoder, attContextSize: [4, 1])

        XCTAssertTrue(state.push(MLXRandom.normal([1, 15, 16]), final: false).isEmpty)
        XCTAssertFalse(state.push(MLXArray.zeros([1, 0, 16]), final: true).isEmpty)
    }
}
