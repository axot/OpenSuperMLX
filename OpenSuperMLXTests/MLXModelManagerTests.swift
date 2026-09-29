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
}
