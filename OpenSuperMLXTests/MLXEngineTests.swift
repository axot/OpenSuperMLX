// MLXEngineTests.swift
// OpenSuperMLXTests

import XCTest

import MLXAudioSTT
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

    func testNeuralEngineTowerFollowsTheCheckpointAudioEncoder() throws {
        let large = try makeQwen3Checkpoint(id: "mlx-community_Qwen3-ASR-1.7B-8bit", audioConfig: [
            "d_model": 1024, "encoder_layers": 24, "encoder_attention_heads": 16,
            "encoder_ffn_dim": 4096, "output_dim": 2048,
        ])
        let small = try makeQwen3Checkpoint(id: "mlx-community_Qwen3-ASR-0.6B-8bit", audioConfig: [
            "d_model": 896, "encoder_layers": 18, "encoder_attention_heads": 14,
            "encoder_ffn_dim": 3584, "output_dim": 1024,
        ])

        XCTAssertTrue(MLXEngine.supportsNeuralEngineAudioTower(large))
        XCTAssertFalse(MLXEngine.supportsNeuralEngineAudioTower(small))
    }

    func testNeuralEngineTowerWithoutAConfigOnlySupportsTheBuiltInModel() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let builtIn = LocalMLXModel(
            id: MLXModelManager.builtInModelID,
            directory: directory.appendingPathComponent(MLXModelManager.builtInModelID),
            modelType: "qwen3_asr",
            sizeBytes: 0
        )
        let other = LocalMLXModel(
            id: "mlx-community_Qwen3-ASR-0.6B-8bit",
            directory: directory.appendingPathComponent("mlx-community_Qwen3-ASR-0.6B-8bit"),
            modelType: "qwen3_asr",
            sizeBytes: 0
        )

        XCTAssertTrue(MLXEngine.supportsNeuralEngineAudioTower(builtIn))
        XCTAssertFalse(MLXEngine.supportsNeuralEngineAudioTower(other))
    }

    // MARK: - Nemotron Language

    func testNemotronLanguageMapsAppCodesToPromptKeys() throws {
        let model = try NemotronASRModel(config: try NemotronASRFixtures.config())

        XCTAssertEqual(MLXEngine.nemotronLanguage(for: "auto", model: model), "auto")
        XCTAssertEqual(MLXEngine.nemotronLanguage(for: "de", model: model), "de")
        XCTAssertEqual(MLXEngine.nemotronLanguage(for: "zh", model: model), "zh-CN")
    }

    func testNemotronLanguageFallsBackToAutoDetectWhenUnsupported() throws {
        let model = try NemotronASRModel(config: try NemotronASRFixtures.config())

        XCTAssertNil(MLXEngine.nemotronLanguage(for: "ca", model: model))
    }

    // MARK: - Helpers

    private func makeQwen3Checkpoint(id: String, audioConfig: [String: Any]) throws -> LocalMLXModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MLXEngineTests-\(UUID().uuidString)")
            .appendingPathComponent(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let config: [String: Any] = ["model_type": "qwen3_asr", "thinker_config": ["audio_config": audioConfig]]
        try JSONSerialization.data(withJSONObject: config).write(to: directory.appendingPathComponent("config.json"))
        return LocalMLXModel(id: id, directory: directory, modelType: "qwen3_asr", sizeBytes: 0)
    }
}
