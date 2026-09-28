// IncrementalMelSpectrogramTests.swift
// OpenSuperMLXTests

import XCTest

import MLX
@testable import MLXAudioSTT

final class IncrementalMelSpectrogramTests: XCTestCase {

    // MARK: - Buffering

    func testPieceShorterThanOneFrameIsBuffered() {
        let signal = Self.speechLikeSignal(samples: 2000)
        let mel = IncrementalMelSpectrogram()

        XCTAssertNil(mel.process(samples: Array(signal[0..<100])))
        XCTAssertEqual(mel.process(samples: Array(signal[100..<1100]))?.shape, [6, 128])
        XCTAssertNil(mel.process(samples: Array(signal[1100..<1150])))
        XCTAssertEqual(mel.process(samples: Array(signal[1150..<2000]))?.shape, [6, 128])
        XCTAssertEqual(IncrementalMelSpectrogram().process(samples: signal)?.shape, [12, 128])
    }

    func testResetStartsAFreshSession() {
        let first = Self.speechLikeSignal(samples: 4000)
        let second = Array(Self.speechLikeSignal(samples: 8000).suffix(3000))
        let reused = IncrementalMelSpectrogram()
        _ = reused.process(samples: first)
        reused.reset()

        let afterReset = reused.process(samples: second)
        let fresh = IncrementalMelSpectrogram().process(samples: second)

        XCTAssertEqual(afterReset?.asArray(Float.self), fresh?.asArray(Float.self))
    }

    // MARK: - Helpers

    private static func speechLikeSignal(samples: Int) -> [Float] {
        var state: UInt32 = 12345
        return (0..<samples).map { i in
            state = state &* 1_664_525 &+ 1_013_904_223
            let noise = Float(state >> 8) / Float(1 << 24) - 0.5
            let t = Float(i) / 16000
            let envelope = 0.5 + 0.5 * sin(2 * .pi * 3 * t)
            let voiced = 0.3 * sin(2 * .pi * 220 * t) + 0.2 * sin(2 * .pi * 660 * t) + 0.1 * sin(2 * .pi * 1760 * t)
            return envelope * voiced + 0.01 * noise
        }
    }
}
