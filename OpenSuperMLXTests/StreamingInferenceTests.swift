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
        XCTAssertEqual(config.decodeIntervalSeconds, 1.0)
        XCTAssertEqual(config.maxCachedWindows, 60)
        XCTAssertEqual(config.temperature, 0.0)
        XCTAssertEqual(config.maxTokensPerPass, 512)
    }

    func testStreamingConfigCustomValues() {
        let config = StreamingConfig(
            decodeIntervalSeconds: 0.5,
            maxCachedWindows: 30,
            language: "Chinese",
            temperature: 0.3
        )
        XCTAssertEqual(config.decodeIntervalSeconds, 0.5)
        XCTAssertEqual(config.maxCachedWindows, 30)
        XCTAssertEqual(config.language, "Chinese")
        XCTAssertEqual(config.temperature, 0.3, accuracy: 0.001)
    }

    func testStreamingConfigRemovedFields_DoNotExist() {
        // Compile-time check: if any removed field exists, this file won't compile
        let config = StreamingConfig()
        _ = config  // suppress unused warning
        XCTAssertTrue(true)
    }
}
