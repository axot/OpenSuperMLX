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

// MARK: - mergeWithOverlapRemoval

final class TextMergeOverlapTests: XCTestCase {

    func testNoOverlap() {
        let result = TextMergeUtilities.mergeWithOverlapRemoval(prefix: "Hello world", newText: "foo bar")
        XCTAssertEqual(result, "Hello worldfoo bar")
    }

    func testFullOverlap() {
        let result = TextMergeUtilities.mergeWithOverlapRemoval(prefix: "Hello world the quick", newText: "the quick brown fox")
        XCTAssertEqual(result, "Hello world the quick brown fox")
    }

    func testPartialOverlap() {
        let result = TextMergeUtilities.mergeWithOverlapRemoval(prefix: "abcdef", newText: "defghi")
        XCTAssertEqual(result, "abcdefghi")
    }

    func testEmptyPrefix() {
        let result = TextMergeUtilities.mergeWithOverlapRemoval(prefix: "", newText: "hello")
        XCTAssertEqual(result, "hello")
    }

    func testEmptyNewText() {
        let result = TextMergeUtilities.mergeWithOverlapRemoval(prefix: "hello", newText: "")
        XCTAssertEqual(result, "hello")
    }

    func testBothEmpty() {
        let result = TextMergeUtilities.mergeWithOverlapRemoval(prefix: "", newText: "")
        XCTAssertEqual(result, "")
    }

    func testCJKOverlap() {
        let result = TextMergeUtilities.mergeWithOverlapRemoval(prefix: "你好世界这是测试", newText: "这是测试新的文本")
        XCTAssertEqual(result, "你好世界这是测试新的文本")
    }

    func testSingleCharOverlap() {
        let result = TextMergeUtilities.mergeWithOverlapRemoval(prefix: "abc", newText: "cde")
        XCTAssertEqual(result, "abcde")
    }

    func testNewTextIsSubsetOfPrefix() {
        let result = TextMergeUtilities.mergeWithOverlapRemoval(prefix: "Hello world the quick brown fox", newText: "the quick brown fox")
        XCTAssertEqual(result, "Hello world the quick brown fox")
    }
}
