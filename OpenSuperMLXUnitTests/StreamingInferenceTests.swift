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
    }

    func testStreamingConfigCustomValues() {
        let config = StreamingConfig(
            language: "Chinese",
            temperature: 0.3
        )
        XCTAssertEqual(config.language, "Chinese")
        XCTAssertEqual(config.temperature, 0.3, accuracy: 0.001)
    }
}

// MARK: - resolveEffectiveLanguage

final class ResolveEffectiveLanguageTests: XCTestCase {

    func testAutoModeNeverOverridesWithDetectedLanguage() {
        let result = StreamingInferenceSession.resolveEffectiveLanguage(
            configLanguage: "auto",
            detectedLanguage: "English"
        )
        XCTAssertEqual(result, "auto")
    }

    func testAutoModeReturnsAutoWhenNothingDetected() {
        let result = StreamingInferenceSession.resolveEffectiveLanguage(
            configLanguage: "auto",
            detectedLanguage: ""
        )
        XCTAssertEqual(result, "auto")
    }

    func testExplicitLanguageIgnoresDetected() {
        let result = StreamingInferenceSession.resolveEffectiveLanguage(
            configLanguage: "Japanese",
            detectedLanguage: "English"
        )
        XCTAssertEqual(result, "Japanese")
    }

    func testExplicitLanguageUsedWhenNothingDetected() {
        let result = StreamingInferenceSession.resolveEffectiveLanguage(
            configLanguage: "Chinese",
            detectedLanguage: ""
        )
        XCTAssertEqual(result, "Chinese")
    }
}
