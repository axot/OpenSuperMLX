// ITNIntegrationTests.swift
// OpenSuperMLXTests
// Created by OpenSuperMLX

import XCTest
@testable import OpenSuperMLX

final class ITNIntegrationTests: XCTestCase {

    // MARK: - Pipeline Order Tests

    func testPipelineOrder_ITNThenAutocorrect() throws {
        let input = "我买了一百二十三个apple"
        let itnResult = ITNProcessor.process(input)
        let finalResult = AutocorrectWrapper.format(itnResult)
        XCTAssertFalse(finalResult.isEmpty, "Pipeline result should not be empty")
    }

    // MARK: - Chinese Number Conversions (Pipeline)

    func testPipeline_ChineseNumberInSentence() throws {
        let input = "今天花了三百二十块钱"
        let itnResult = ITNProcessor.process(input)
        let finalResult = AutocorrectWrapper.format(itnResult)
        XCTAssertFalse(finalResult.isEmpty, "Pipeline result for Chinese number sentence should not be empty")
    }

    func testPipeline_ChineseDateConversion() throws {
        let input = "二零二五年三月十九号"
        let itnResult = ITNProcessor.process(input)
        let finalResult = AutocorrectWrapper.format(itnResult)
        XCTAssertFalse(finalResult.isEmpty, "Pipeline result for Chinese date should not be empty")
    }

    func testPipeline_ChineseDecimalConversion() throws {
        let input = "温度是二十三点五度"
        let itnResult = ITNProcessor.process(input)
        let finalResult = AutocorrectWrapper.format(itnResult)
        XCTAssertFalse(finalResult.isEmpty, "Pipeline result for Chinese decimal should not be empty")
    }

    func testPipeline_ChinesePercentage() throws {
        let input = "增长了百分之五十"
        let itnResult = ITNProcessor.process(input)
        let finalResult = AutocorrectWrapper.format(itnResult)
        XCTAssertFalse(finalResult.isEmpty, "Pipeline result for Chinese percentage should not be empty")
    }

    // MARK: - Pass-through Tests

    func testPipeline_EnglishTextUnchanged() throws {
        let input = "hello world one two three"
        let itnResult = ITNProcessor.process(input)
        let finalResult = AutocorrectWrapper.format(itnResult)
        XCTAssertEqual(finalResult, input, "English text should pass through pipeline unchanged")
    }

    func testPipeline_EmptyStringUnchanged() throws {
        let input = ""
        let itnResult = ITNProcessor.process(input)
        let finalResult = AutocorrectWrapper.format(itnResult)
        XCTAssertEqual(finalResult, "", "Empty string should remain empty through pipeline")
    }

    // MARK: - Settings Integration

    func testSettings_ChineseITNPropertyExists() throws {
        let settings = Settings()
        let _ = settings.useChineseITN
        let _ = settings.shouldApplyChineseITN
    }

    func testSettings_ShouldApplyChineseITN_WhenLanguageIsChinese() throws {
        let prefs = AppPreferences.shared
        let originalUseChineseITN = prefs.useChineseITN
        let originalLanguage = prefs.mlxLanguage
        defer {
            prefs.useChineseITN = originalUseChineseITN
            prefs.mlxLanguage = originalLanguage
        }

        prefs.useChineseITN = true
        prefs.mlxLanguage = "zh"
        let settings = Settings()
        XCTAssertTrue(settings.shouldApplyChineseITN, "shouldApplyChineseITN should be true when language is zh and toggle is on")
    }

    func testSettings_ShouldNotApplyChineseITN_WhenLanguageIsEnglish() throws {
        let prefs = AppPreferences.shared
        let originalUseChineseITN = prefs.useChineseITN
        let originalLanguage = prefs.mlxLanguage
        defer {
            prefs.useChineseITN = originalUseChineseITN
            prefs.mlxLanguage = originalLanguage
        }

        prefs.useChineseITN = true
        prefs.mlxLanguage = "en"
        let settings = Settings()
        XCTAssertFalse(settings.shouldApplyChineseITN, "shouldApplyChineseITN should be false when language is en")
    }

    func testSettings_ShouldNotApplyChineseITN_WhenToggleOff() throws {
        let prefs = AppPreferences.shared
        let originalUseChineseITN = prefs.useChineseITN
        let originalLanguage = prefs.mlxLanguage
        defer {
            prefs.useChineseITN = originalUseChineseITN
            prefs.mlxLanguage = originalLanguage
        }

        prefs.useChineseITN = false
        prefs.mlxLanguage = "zh"
        let settings = Settings()
        XCTAssertFalse(settings.shouldApplyChineseITN, "shouldApplyChineseITN should be false when toggle is off")
    }

    // MARK: - Graceful Degradation

    func testGracefulDegradation_NeverCrashes() throws {
        let inputs: [String] = [
            "",
            "hello world",
            "今天天气很好",
            "一二三四五六七八九十",
            "mixed 混合 text 文字",
            "😀🎉🔥",
            "   ",
            String(repeating: "这是一个很长的中文句子", count: 100),
            "1234567890",
            "!@#$%^&*()",
            "日本語テスト",
            "한국어 테스트"
        ]

        for input in inputs {
            let itnResult = ITNProcessor.process(input)
            let finalResult = AutocorrectWrapper.format(itnResult)
            XCTAssertNotNil(finalResult, "Result should not be nil for input: \(input.prefix(20))")
        }
    }
}
