// NemotronASRAudioTests.swift
// OpenSuperMLXTests

import XCTest

import MLX
import MLXAudioCore
@testable import MLXAudioSTT

final class NemotronASRAudioTests: XCTestCase {

    private var audio: NemotronASRAudio!
    private var waveform: MLXArray!

    override func setUpWithError() throws {
        audio = NemotronASRAudio(config: try NemotronASRFixtures.config().preprocessor)
        MLXRandom.seed(7)
        waveform = audio.preemphasize(MLXRandom.normal([16000]) * 0.1)
    }

    // MARK: - Frames

    func testFrameCountMatchesCenteredSTFT() {
        XCTAssertEqual(audio.frameCount(samples: 16000), 101)
        XCTAssertEqual(audio.frameCount(samples: 159), 1)
    }

    func testFullRangeMatchesLibraryCenteredSTFT() {
        let config = audio.config
        let hann = hanningWindow(size: config.winLength)
        let pad = (config.nFft - config.winLength) / 2
        let window = MLX.concatenated([MLXArray.zeros([pad]), hann, MLXArray.zeros([pad])])
        let spectrum = stft(audio: waveform, window: window, nFft: config.nFft, hopLength: config.hopLength, padMode: .reflect)
        let filters = melFilters(sampleRate: 16000, nFft: config.nFft, nMels: config.features, norm: "slaney", melScale: .slaney)
        let expected = MLX.log(MLX.matmul(MLX.abs(spectrum).square(), filters) + Float(config.logZeroGuardValue))

        let mel = audio.logMel(preemphasized: waveform, frameStart: 0, frameEnd: 101)

        XCTAssertEqual(mel.shape, [1, 101, 16])
        XCTAssertTrue(MLX.allClose(mel[0], expected, rtol: 1e-4, atol: 1e-4).item(Bool.self))
    }

    func testChunkedRangesMatchASingleFullPass() {
        let full = audio.logMel(preemphasized: waveform, frameStart: 0, frameEnd: 101)
        let chunked = MLX.concatenated([
            audio.logMel(preemphasized: waveform, frameStart: 0, frameEnd: 37),
            audio.logMel(preemphasized: waveform, frameStart: 37, frameEnd: 101),
        ], axis: 1)

        XCTAssertTrue(MLX.allClose(full, chunked, rtol: 1e-5, atol: 1e-5).item(Bool.self))
    }

    func testPreemphasisKeepsTheFirstSample() {
        let input = MLXArray([1, 2, 3] as [Float])
        let output = audio.preemphasize(input).asArray(Float.self)

        XCTAssertEqual(output[0], 1)
        XCTAssertEqual(output[1], 2 - 0.97, accuracy: 1e-6)
        XCTAssertEqual(output[2], 3 - 0.97 * 2, accuracy: 1e-6)
    }
}
