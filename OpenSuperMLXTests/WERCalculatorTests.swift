// WERCalculatorTests.swift
// OpenSuperMLXTests

import XCTest
@testable import OpenSuperMLX

final class WERCalculatorTests: XCTestCase {

    // MARK: - WER Tests

    func testWER_IdenticalStrings_ReturnsZero() {
        XCTAssertEqual(WERCalculator.computeWER(reference: "hello world", hypothesis: "hello world"), 0.0)
    }

    func testWER_CompletelyDifferent_ReturnsOne() {
        XCTAssertEqual(WERCalculator.computeWER(reference: "hello", hypothesis: "goodbye"), 1.0)
    }

    func testWER_OneDeletion_ReturnsHalf() {
        XCTAssertEqual(WERCalculator.computeWER(reference: "hello world", hypothesis: "hello"), 0.5)
    }

    func testWER_OneInsertion() {
        XCTAssertEqual(WERCalculator.computeWER(reference: "hello", hypothesis: "hello world"), 1.0)
    }

    func testWER_OneSubstitution() {
        XCTAssertEqual(WERCalculator.computeWER(reference: "hello world", hypothesis: "hello earth"), 0.5)
    }

    func testWERKnownExample() {
        let wer = WERCalculator.computeWER(reference: "the cat sat", hypothesis: "the bat sat")
        XCTAssertEqual(wer, 1.0 / 3.0, accuracy: 0.001)
    }

    func testWERPerfectMatch() {
        XCTAssertEqual(WERCalculator.computeWER(reference: "hello world foo", hypothesis: "hello world foo"), 0.0)
    }

    // MARK: - CER Tests

    func testCER_IdenticalStrings_ReturnsZero() {
        XCTAssertEqual(WERCalculator.computeCER(reference: "hello", hypothesis: "hello"), 0.0)
    }

    func testCER_ChinesePartialMatch() {
        XCTAssertEqual(WERCalculator.computeCER(reference: "你好世界", hypothesis: "你好"), 0.5)
    }

    func testCERChineseCharacters() {
        let cer = WERCalculator.computeCER(reference: "你好世界欢迎", hypothesis: "你好世界")
        XCTAssertEqual(cer, 2.0 / 6.0, accuracy: 0.001)
    }

    func testCERJapaneseCharacters() {
        let cer = WERCalculator.computeCER(reference: "こんにちは", hypothesis: "こんにちわ")
        XCTAssertEqual(cer, 1.0 / 5.0, accuracy: 0.001)
    }

    // MARK: - RTF Calculation

    func testRTFCalculation() {
        let audioDuration = 10.0
        let processingTime = 1.5
        let rtf = processingTime / audioDuration
        XCTAssertEqual(rtf, 0.15, accuracy: 0.001)
    }

    // MARK: - Threshold Tests

    func testWERThresholdPassFail() {
        let threshold = 0.2
        let passingScore = WERCalculator.computeWER(reference: "the cat sat on the mat", hypothesis: "the cat sat on the mat")
        XCTAssertTrue(passingScore <= threshold)

        let failingScore = WERCalculator.computeWER(reference: "the cat", hypothesis: "a dog")
        XCTAssertTrue(failingScore > threshold)
    }

    // MARK: - Detailed Results

    func testWERDetailed_SubstitutionCount() {
        let result = WERCalculator.computeWERDetailed(reference: "the cat sat", hypothesis: "the bat sat")
        XCTAssertEqual(result.metric, "WER")
        XCTAssertEqual(result.substitutions, 1)
        XCTAssertEqual(result.insertions, 0)
        XCTAssertEqual(result.deletions, 0)
        XCTAssertEqual(result.score, 1.0 / 3.0, accuracy: 0.001)
    }

    func testCERDetailed_DeletionCount() {
        let result = WERCalculator.computeCERDetailed(reference: "abcd", hypothesis: "ab")
        XCTAssertEqual(result.metric, "CER")
        XCTAssertEqual(result.deletions, 2)
        XCTAssertEqual(result.score, 0.5, accuracy: 0.001)
    }

    // MARK: - Normalization Tests

    func testNormalization_LowercasesAndStripsPunctuation() {
        XCTAssertEqual(WERCalculator.normalizeForWER("Hello, World!"), "hello world")
    }

    func testNormalization_NFKC() {
        XCTAssertEqual(WERCalculator.normalizeForWER("Ｈｅｌｌｏ"), "hello")
    }

    // MARK: - CJK Detection Tests

    func testCJKDetection_ChineseIsDominant() {
        XCTAssertTrue(WERCalculator.isCJKDominant("你好世界"))
    }

    func testCJKDetection_EnglishIsNotDominant() {
        XCTAssertFalse(WERCalculator.isCJKDominant("hello"))
    }

    // MARK: - Edge Cases

    func testEmptyReference_BothEmpty_ReturnsZero() {
        XCTAssertEqual(WERCalculator.computeWER(reference: "", hypothesis: ""), 0.0)
        XCTAssertEqual(WERCalculator.computeCER(reference: "", hypothesis: ""), 0.0)
    }

    func testEmptyReference_NonEmptyHypothesis_ReturnsOne() {
        XCTAssertEqual(WERCalculator.computeWER(reference: "", hypothesis: "hello"), 1.0)
        XCTAssertEqual(WERCalculator.computeCER(reference: "", hypothesis: "hello"), 1.0)
    }
}
