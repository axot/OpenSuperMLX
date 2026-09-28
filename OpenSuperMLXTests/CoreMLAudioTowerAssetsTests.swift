// CoreMLAudioTowerAssetsTests.swift
// OpenSuperMLXTests

import XCTest
@testable import OpenSuperMLX

final class CoreMLAudioTowerAssetsTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreMLAudioTowerAssetsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Tests

    func testDownloadURLPointsAtThePinnedRepository() {
        XCTAssertEqual(
            CoreMLAudioTowerAssets.downloadURL(for: "model.mil").absoluteString,
            "https://huggingface.co/axot/Qwen3-ASR-1.7B-CoreML-INT8/resolve/main/qwen3_asr_audio_tower_int8.mlmodelc/model.mil"
        )
    }

    func testResolveUsesAnInstalledModelWithoutDownloading() async throws {
        let model = directory.appendingPathComponent(CoreMLAudioTowerAssets.modelName)
        try writeModelFiles(into: model)

        let resolved = try await CoreMLAudioTowerAssets.resolve(in: directory) { _, _ in
            XCTFail("An installed model must not be downloaded again")
        }

        XCTAssertEqual(resolved.standardizedFileURL, model.standardizedFileURL)
    }

    func testResolveInstallsEveryModelFile() async throws {
        let resolved = try await CoreMLAudioTowerAssets.resolve(in: directory) { _, destination in
            try Data("x".utf8).write(to: destination)
        }

        XCTAssertTrue(CoreMLAudioTowerAssets.isInstalled(at: resolved))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [CoreMLAudioTowerAssets.modelName])
    }

    func testFailedDownloadLeavesNoPartialModel() async throws {
        do {
            _ = try await CoreMLAudioTowerAssets.resolve(in: directory) { remote, destination in
                if remote.lastPathComponent == "weight.bin" { throw URLError(.networkConnectionLost) }
                try Data("x".utf8).write(to: destination)
            }
            XCTFail("Expected the download to fail")
        } catch {}

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    // MARK: - Helpers

    private func writeModelFiles(into model: URL) throws {
        for file in CoreMLAudioTowerAssets.modelFiles {
            let url = model.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
    }
}
