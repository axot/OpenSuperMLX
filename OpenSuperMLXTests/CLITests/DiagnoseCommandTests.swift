// DiagnoseCommandTests.swift
// OpenSuperMLXTests

import XCTest

import ArgumentParser
@testable import OpenSuperMLX

final class DiagnoseCommandTests: XCTestCase {

    // MARK: - Output Content

    func testDiagnoseIncludesMacOSVersion() {
        let result = DiagnoseCommand.collectDiagnostics()
        XCTAssertFalse(result.macosVersion.isEmpty)
        XCTAssertTrue(result.macosVersion.contains("Version"))
    }

    func testDiagnoseIncludesChipModel() {
        let result = DiagnoseCommand.collectDiagnostics()
        XCTAssertFalse(result.chipModel.isEmpty)
    }

    func testDiagnoseIncludesMemory() {
        let result = DiagnoseCommand.collectDiagnostics()
        XCTAssertGreaterThan(result.availableMemoryGB, 0.0)
    }

    // MARK: - JSON Output

    func testDiagnoseJSONOutputStructure() throws {
        let result = DiagnoseCommand.collectDiagnostics()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(result)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertNotNil(json["macos_version"] as? String)
        XCTAssertNotNil(json["chip_model"] as? String)
        XCTAssertNotNil(json["available_memory_gb"] as? Double)
        XCTAssertNotNil(json["installed_models"] as? [String])
        XCTAssertNotNil(json["permissions"] as? [String: Any])
        XCTAssertNotNil(json["settings"] as? [String: Any])
    }

    // MARK: - Settings

    func testDiagnoseReportsNeuralEngineAudioTowerOnWhenUnset() {
        let suiteName = "DiagnoseCommandTests.\(name)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        AppPreferences.store = defaults
        defer {
            AppPreferences.store = .standard
            defaults.removePersistentDomain(forName: suiteName)
        }

        XCTAssertTrue(DiagnoseCommand.collectDiagnostics().settings.neuralEngineAudioTower)
    }

    // MARK: - Installed Models

    func testDiagnoseListsTheModelOnceItsWeightsAreDownloaded() throws {
        let directory = try makeModelsDirectory()
        let model = directory.appendingPathComponent("mlx-audio/mlx-community_Qwen3-ASR-1.7B-5bit")
        try writeFile(at: model.appendingPathComponent("config.json"))
        XCTAssertEqual(DiagnoseCommand.listInstalledModels(in: directory), [])

        try writeFile(at: model.appendingPathComponent("model.safetensors"))
        XCTAssertEqual(DiagnoseCommand.listInstalledModels(in: directory), ["mlx-community/Qwen3-ASR-1.7B-5bit"])
    }

    func testDiagnoseListsTheInstalledNeuralEngineAudioEncoder() throws {
        let directory = try makeModelsDirectory()
        let model = CoreMLAudioTowerAssets.installDirectory(in: directory)
            .appendingPathComponent(CoreMLAudioTowerAssets.modelName)
        for file in CoreMLAudioTowerAssets.modelFiles {
            try writeFile(at: model.appendingPathComponent(file))
        }

        XCTAssertEqual(DiagnoseCommand.listInstalledModels(in: directory), [CoreMLAudioTowerAssets.repositoryID])
    }

    // MARK: - Option Parsing

    func testDiagnoseParses() throws {
        let command = try DiagnoseCommand.parse([])
        XCTAssertNotNil(command)
    }

    // MARK: - Helpers

    private func makeModelsDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnoseCommandTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func writeFile(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }
}
