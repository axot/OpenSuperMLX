// Qwen3ASRCoreMLAudioTowerTests.swift
// OpenSuperMLXTests

import XCTest

import HuggingFace
import MLX
@testable import MLXAudioSTT
@testable import OpenSuperMLX

final class Qwen3ASRCoreMLAudioTowerTests: XCTestCase {

    // MARK: - Window Layout

    func testValidTokenCountMatchesFeatureExtractorLengths() {
        for frames in [1, 37, 99, 100, 101, 250, 799, 800] {
            let expected = Int(getFeatExtractOutputLengths(MLXArray([Int32(frames)]))[0].item(Int32.self))
            XCTAssertEqual(Qwen3ASRCoreMLAudioTower.validTokenCount(frames: frames), expected, "frames=\(frames)")
        }
    }

    func testWindowRangesSplitIntoEightHundredFrameWindows() {
        XCTAssertEqual(Qwen3ASRCoreMLAudioTower.windowRanges(frames: 800), [0..<800])
        XCTAssertEqual(
            Qwen3ASRCoreMLAudioTower.windowRanges(frames: 1750),
            [0..<800, 800..<1600, 1600..<1750]
        )
    }

    // MARK: - Parity (real models, opt-in)

    /// Set QWEN3_ASR_TEST_COREML_TOWER (compiled tower) and QWEN3_ASR_TEST_MODEL (MLX repo ID).
    func testCoreMLWindowMatchesMLXEncoder() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let towerPath = environment["QWEN3_ASR_TEST_COREML_TOWER"],
              let repoID = environment["QWEN3_ASR_TEST_MODEL"] else {
            throw XCTSkip("Set QWEN3_ASR_TEST_COREML_TOWER and QWEN3_ASR_TEST_MODEL to compare encoders")
        }
        let model = try await Qwen3ASRModel.fromPretrained(
            repoID,
            cache: HubCache(cacheDirectory: MLXModelManager.modelsDirectory)
        )
        let melBins = model.config.audioConfig.numMelBins
        let tower = try Qwen3ASRCoreMLAudioTower(url: URL(fileURLWithPath: towerPath), melBins: melBins)

        for frames in [250, 800] {
            let mel = MLXRandom.uniform(low: -1, high: 1, [frames, melBins], key: MLXRandom.key(UInt64(frames)))
            let reference = try model.audioTower.encodeSingleWindow(mel).asType(.float32)
            let candidate = try tower.encodeWindow(mel).asType(.float32)
            XCTAssertEqual(candidate.shape, reference.shape, "frames=\(frames)")

            let width = reference.dim(1)
            let lhs = reference.asArray(Float.self)
            let rhs = candidate.asArray(Float.self)
            let cosines = (0..<reference.dim(0)).map { token in
                Self.cosine(lhs[(token * width)..<((token + 1) * width)], rhs[(token * width)..<((token + 1) * width)])
            }
            let mean = cosines.reduce(0, +) / Float(cosines.count)
            XCTAssertGreaterThan(mean, 0.99, "frames=\(frames) mean token cosine=\(mean)")
            XCTAssertGreaterThan(cosines.min() ?? 0, 0.9, "frames=\(frames) worst token cosine=\(cosines.min() ?? 0)")
        }
    }

    private static func cosine(_ lhs: ArraySlice<Float>, _ rhs: ArraySlice<Float>) -> Float {
        var dot: Float = 0
        var lhsNorm: Float = 0
        var rhsNorm: Float = 0
        for (a, b) in zip(lhs, rhs) {
            dot += a * b
            lhsNorm += a * a
            rhsNorm += b * b
        }
        return dot / max(sqrt(lhsNorm * rhsNorm), .leastNormalMagnitude)
    }
}
