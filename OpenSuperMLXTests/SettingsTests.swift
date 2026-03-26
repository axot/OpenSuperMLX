// SettingsTests.swift
// OpenSuperMLXTests

import XCTest
@testable import OpenSuperMLX

final class SettingsTests: XCTestCase {

    // MARK: - shouldApplyChineseITN

    func testShouldApplyChineseITN_TrueWhenChinese() {
        let settings = Settings(selectedLanguage: "zh")
        XCTAssertTrue(settings.shouldApplyChineseITN)
    }

    func testShouldApplyChineseITN_FalseWhenEnglish() {
        let settings = Settings(selectedLanguage: "en")
        XCTAssertFalse(settings.shouldApplyChineseITN)
    }

    func testShouldApplyChineseITN_TrueWhenAutoDetect() {
        let settings = Settings(selectedLanguage: "auto")
        XCTAssertTrue(settings.shouldApplyChineseITN)
    }

    // MARK: - shouldApplyEnglishITN

    func testShouldApplyEnglishITN_TrueWhenEnglish() {
        let settings = Settings(selectedLanguage: "en")
        XCTAssertTrue(settings.shouldApplyEnglishITN)
    }

    func testShouldApplyEnglishITN_FalseWhenChinese() {
        let settings = Settings(selectedLanguage: "zh")
        XCTAssertFalse(settings.shouldApplyEnglishITN)
    }

    // MARK: - shouldApplyAsianAutocorrect

    func testShouldApplyAsianAutocorrect_CJKLanguages() {
        XCTAssertTrue(Settings(selectedLanguage: "zh", useAsianAutocorrect: true).shouldApplyAsianAutocorrect)
        XCTAssertTrue(Settings(selectedLanguage: "ja", useAsianAutocorrect: true).shouldApplyAsianAutocorrect)
        XCTAssertTrue(Settings(selectedLanguage: "ko", useAsianAutocorrect: true).shouldApplyAsianAutocorrect)
        XCTAssertFalse(Settings(selectedLanguage: "en", useAsianAutocorrect: true).shouldApplyAsianAutocorrect)
        XCTAssertFalse(Settings(selectedLanguage: "zh", useAsianAutocorrect: false).shouldApplyAsianAutocorrect)
    }
}
