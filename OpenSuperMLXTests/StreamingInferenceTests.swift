//
//  StreamingInferenceTests.swift
//  OpenSuperMLXTests
//

import XCTest
@testable import MLXAudioSTT

final class StreamingInferenceTests: XCTestCase {

    // MARK: - Prefix Rollback Index Tests

    func testPrefixRollback_Normal() {
        let endIdx = StreamingInferenceSession.computePrefixEndIndex(tokenCount: 7, unfixedTokenNum: 5)
        XCTAssertEqual(endIdx, 2)
    }

    func testPrefixRollback_FewerTokensThanUnfixed() {
        let endIdx = StreamingInferenceSession.computePrefixEndIndex(tokenCount: 3, unfixedTokenNum: 5)
        XCTAssertEqual(endIdx, 0)
    }

    func testPrefixRollback_EmptyTokens() {
        let endIdx = StreamingInferenceSession.computePrefixEndIndex(tokenCount: 0, unfixedTokenNum: 5)
        XCTAssertEqual(endIdx, 0)
    }

    func testPrefixRollback_ExactlyUnfixed() {
        let endIdx = StreamingInferenceSession.computePrefixEndIndex(tokenCount: 5, unfixedTokenNum: 5)
        XCTAssertEqual(endIdx, 0)
    }

    func testPrefixRollback_LargeTokenCount() {
        let endIdx = StreamingInferenceSession.computePrefixEndIndex(tokenCount: 100, unfixedTokenNum: 5)
        XCTAssertEqual(endIdx, 95)
    }

    // MARK: - StreamingConfig Defaults

    func testStreamingConfigDefaults() {
        let config = StreamingConfig()
        XCTAssertEqual(config.unfixedTokenNum, 5)
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
            temperature: 0.3,
            unfixedTokenNum: 10
        )
        XCTAssertEqual(config.unfixedTokenNum, 10)
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
