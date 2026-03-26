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

    // MARK: - CER Tests

    func testCER_IdenticalStrings_ReturnsZero() {
        XCTAssertEqual(WERCalculator.computeCER(reference: "hello", hypothesis: "hello"), 0.0)
    }

    func testCER_ChinesePartialMatch() {
        XCTAssertEqual(WERCalculator.computeCER(reference: "你好世界", hypothesis: "你好"), 0.5)
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
