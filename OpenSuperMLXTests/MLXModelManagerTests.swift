// MLXModelManagerTests.swift
// OpenSuperMLXTests

import XCTest
@testable import OpenSuperMLX

final class MLXModelManagerTests: XCTestCase {

    // MARK: - Built-in Model Sizes

    func testBuiltInModelSizes() {
        let models = MLXModelManager.builtInModels
        let sizes = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0.size) })

        XCTAssertEqual(sizes["qwen3-asr-0.6b-4bit"], "~700MB")
        XCTAssertEqual(sizes["qwen3-asr-1.7b-8bit"], "~2.3GB")
        XCTAssertEqual(sizes["qwen3-asr-1.7b-bf16"], "~3.8GB")
    }

    func testBuiltInModelCount() {
        XCTAssertEqual(MLXModelManager.builtInModels.count, 3)
    }

    func testBuiltInModelIDs() {
        let ids = MLXModelManager.builtInModels.map(\.id)
        XCTAssertTrue(ids.contains("qwen3-asr-0.6b-4bit"))
        XCTAssertTrue(ids.contains("qwen3-asr-1.7b-8bit"))
        XCTAssertTrue(ids.contains("qwen3-asr-1.7b-bf16"))
    }
}
