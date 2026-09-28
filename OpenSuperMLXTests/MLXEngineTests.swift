// MLXEngineTests.swift
// OpenSuperMLXTests

import XCTest
@testable import OpenSuperMLX

final class MLXEngineTests: XCTestCase {

    // MARK: - Neural Engine Audio Tower

    func testDisabledNeuralEngineNeverResolvesTheTower() async {
        let url = await MLXEngine.neuralEngineAudioTowerURL(
            enabled: false,
            resolve: {
                XCTFail("Must not resolve while disabled")
                return URL(fileURLWithPath: "/unused")
            },
            onFallback: { _ in XCTFail("No fallback while disabled") }
        )
        XCTAssertNil(url)
    }

    func testUnavailableTowerFallsBackToGPU() async {
        var reported: Error?
        let url = await MLXEngine.neuralEngineAudioTowerURL(
            enabled: true,
            resolve: { throw URLError(.notConnectedToInternet) },
            onFallback: { reported = $0 }
        )
        XCTAssertNil(url)
        XCTAssertNotNil(reported)
    }

    func testEnabledNeuralEngineUsesTheResolvedTower() async {
        let tower = URL(fileURLWithPath: "/tmp/qwen3_asr_audio_tower_int8.mlmodelc")
        let url = await MLXEngine.neuralEngineAudioTowerURL(
            enabled: true,
            resolve: { tower },
            onFallback: { _ in XCTFail("Unexpected fallback") }
        )
        XCTAssertEqual(url, tower)
    }
}
