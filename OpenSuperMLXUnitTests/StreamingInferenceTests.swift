//
//  StreamingInferenceTests.swift
//  OpenSuperMLXTests
//

import XCTest
@testable import MLXAudioSTT

final class StreamingInferenceTests: XCTestCase {

    // MARK: - StreamingConfig Defaults

    func testStreamingConfigDefaults() {
        let config = StreamingConfig()
        XCTAssertEqual(config.language, "English")
        XCTAssertEqual(config.temperature, 0.0)
        XCTAssertEqual(config.maxNewTokensPerChunk, 200)
        XCTAssertEqual(config.maxKVSize, 1024)
    }

    func testStreamingConfigCustomValues() {
        let config = StreamingConfig(
            language: "Chinese",
            temperature: 0.3,
            maxKVSize: 2048
        )
        XCTAssertEqual(config.language, "Chinese")
        XCTAssertEqual(config.temperature, 0.3, accuracy: 0.001)
        XCTAssertEqual(config.maxKVSize, 2048)
    }
}
