// MLXModelManagerTests.swift
// OpenSuperMLXTests

import XCTest
@testable import OpenSuperMLX

final class MLXModelManagerTests: XCTestCase {

    // MARK: - Built-in Model

    func testOnlyModelIsQwen3ASR17BFiveBit() {
        let model = MLXModelManager.model
        XCTAssertEqual(model.id, "qwen3-asr-1.7b-5bit")
        XCTAssertEqual(model.repoID, "mlx-community/Qwen3-ASR-1.7B-5bit")
        XCTAssertEqual(model.size, "~1.8GB")
    }

    // MARK: - Discovery

    func testDiscoversFoldersWithConfigAndWeights() throws {
        let directory = try makeModelsDirectory()
        try makeModel("mlx-community_nemotron-3.5-asr-streaming-0.6b-8bit", modelType: "nemotron_asr", in: directory)
        try makeModel("mlx-community_Qwen3-ASR-1.7B-5bit", modelType: "qwen3_asr", in: directory)
        try makeModel("no-weights", modelType: "qwen3_asr", weights: false, in: directory)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(".cache"), withIntermediateDirectories: true)

        let models = MLXModelManager.installedModels(in: directory)

        XCTAssertEqual(models.map(\.id), ["mlx-community_nemotron-3.5-asr-streaming-0.6b-8bit", "mlx-community_Qwen3-ASR-1.7B-5bit"])
        XCTAssertEqual(models.map(\.architecture), [.nemotronASR, .qwen3ASR])
        XCTAssertEqual(models[0].name, "nemotron-3.5-asr-streaming-0.6b-8bit")
        XCTAssertEqual(models[0].repoID, "mlx-community/nemotron-3.5-asr-streaming-0.6b-8bit")
        XCTAssertGreaterThan(models[0].sizeBytes, 0)
    }

    func testUnknownModelTypesAreListedAsUnsupported() throws {
        let directory = try makeModelsDirectory()
        try makeModel("org_whisper", modelType: "whisper", in: directory)

        let model = try XCTUnwrap(MLXModelManager.installedModels(in: directory).first)

        XCTAssertFalse(model.isSupported)
        XCTAssertEqual(model.modelType, "whisper")
    }

    func testAvailableModelsAlwaysOfferTheBuiltInModel() throws {
        let directory = try makeModelsDirectory()
        try makeModel("mlx-community_nemotron-3.5-asr-streaming-0.6b-8bit", modelType: "nemotron_asr", in: directory)

        let models = MLXModelManager.availableModels(in: directory)

        XCTAssertEqual(models.map(\.id), [MLXModelManager.builtInModelID, "mlx-community_nemotron-3.5-asr-streaming-0.6b-8bit"])
        XCTAssertEqual(models[0].repoID, MLXModelManager.model.repoID)
    }

    // MARK: - Selection

    func testSelectionUsesTheChosenSupportedModel() throws {
        let directory = try makeModelsDirectory()
        try makeModel("mlx-community_nemotron-3.5-asr-streaming-0.6b-8bit", modelType: "nemotron_asr", in: directory)
        let installed = MLXModelManager.installedModels(in: directory)

        let selected = MLXModelManager.resolveSelectedModel(
            selectedID: "mlx-community_nemotron-3.5-asr-streaming-0.6b-8bit", installed: installed, directory: directory
        )

        XCTAssertEqual(selected.architecture, .nemotronASR)
        XCTAssertFalse(selected.supportsStreaming)
    }

    func testSelectionFallsBackToTheBuiltInModel() throws {
        let directory = try makeModelsDirectory()
        try makeModel("org_whisper", modelType: "whisper", in: directory)
        let installed = MLXModelManager.installedModels(in: directory)

        for selectedID in [nil, "missing", "org_whisper"] {
            let selected = MLXModelManager.resolveSelectedModel(selectedID: selectedID, installed: installed, directory: directory)
            XCTAssertEqual(selected.id, MLXModelManager.builtInModelID)
            XCTAssertEqual(selected.architecture, .qwen3ASR)
            XCTAssertTrue(selected.supportsStreaming)
        }
    }

    // MARK: - Helpers

    private func makeModelsDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MLXModelManagerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func makeModel(_ name: String, modelType: String, weights: Bool = true, in directory: URL) throws {
        let folder = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{\"model_type\": \"\(modelType)\"}".utf8).write(to: folder.appendingPathComponent("config.json"))
        if weights {
            try Data("weights".utf8).write(to: folder.appendingPathComponent("model.safetensors"))
        }
    }
}
