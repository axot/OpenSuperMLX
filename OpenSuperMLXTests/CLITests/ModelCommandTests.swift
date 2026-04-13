// ModelCommandTests.swift
// OpenSuperMLXTests

import XCTest

@testable import OpenSuperMLX

@MainActor
final class ModelCommandTests: XCTestCase {

    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        testDefaults = UserDefaults(suiteName: "com.opensupermlx.test.model.\(name)")!
        testDefaults.removePersistentDomain(forName: "com.opensupermlx.test.model.\(name)")
        AppPreferences.store = testDefaults
    }

    override func tearDown() {
        AppPreferences.store = .standard
        testDefaults.removePersistentDomain(forName: "com.opensupermlx.test.model.\(name)")
        testDefaults = nil
        super.tearDown()
    }

    // MARK: - List

    func testModelListIncludesBuiltIn() throws {
        let result = ModelListCommand.executeList()
        guard case .success(let entries) = result else {
            XCTFail("Expected success"); return
        }
        XCTAssertGreaterThanOrEqual(entries.count, 3)
        let ids = entries.map(\.id)
        XCTAssertTrue(ids.contains("qwen3-asr-0.6b-4bit"))
        XCTAssertTrue(ids.contains("qwen3-asr-1.7b-8bit"))
        XCTAssertTrue(ids.contains("qwen3-asr-1.7b-bf16"))
    }

    // MARK: - Add & Remove

    func testModelAddCustomModel() throws {
        let result = ModelAddCommand.executeAdd(repoId: "user/test-model")
        guard case .success(let data) = result else {
            XCTFail("Expected success"); return
        }
        XCTAssertEqual(data.repoId, "user/test-model")

        let listResult = ModelListCommand.executeList()
        guard case .success(let entries) = listResult else {
            XCTFail("Expected success"); return
        }
        XCTAssertTrue(entries.contains(where: { $0.repoId == "user/test-model" }))

        MLXModelManager.shared.customModels.removeAll()
    }

    func testModelRemoveCustomModel() throws {
        MLXModelManager.shared.addCustomModel(repoID: "user/remove-test")
        let result = ModelRemoveCommand.executeRemove(name: "custom-remove-test")
        guard case .success(let data) = result else {
            XCTFail("Expected success"); return
        }
        XCTAssertTrue(data.message.contains("Removed"))

        let remaining = MLXModelManager.shared.customModels
        XCTAssertFalse(remaining.contains(where: { $0.repoID == "user/remove-test" }))
    }

    // MARK: - Select

    func testModelSelectNonExistent() throws {
        let result = ModelSelectCommand.executeSelect(name: "nonexistent-model-xyz")
        guard case .failure(let error) = result else {
            XCTFail("Expected failure"); return
        }
        XCTAssertEqual(error, .modelNotFound)
    }

    func testModelSelectBuiltIn() throws {
        let result = ModelSelectCommand.executeSelect(name: "qwen3-asr-0.6b-4bit")
        guard case .success(let data) = result else {
            XCTFail("Expected success"); return
        }
        XCTAssertEqual(data.id, "qwen3-asr-0.6b-4bit")
        XCTAssertEqual(
            testDefaults.string(forKey: "selectedMLXModel"),
            "mlx-community/Qwen3-ASR-0.6B-4bit"
        )
    }
}
