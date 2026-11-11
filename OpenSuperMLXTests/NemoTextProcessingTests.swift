// NemoTextProcessingTests.swift
// OpenSuperMLXTests

import XCTest

@testable import OpenSuperMLX

final class NemoTextProcessingTests: XCTestCase {
    func testNormalizeSentenceWithMaxSpanNormalizesMultiwordNumbers() {
        XCTAssertEqual(
            NemoTextProcessing.normalizeSentence("I have twenty one apples", maxSpanTokens: 4),
            "I have 21 apples"
        )
    }

    func testNormalizeSentenceWithZeroMaxSpanUsesSingleTokenSpans() {
        let input = "I have twenty one apples"
        let singleTokenResult = NemoTextProcessing.normalizeSentence(input, maxSpanTokens: 1)
        XCTAssertEqual(NemoTextProcessing.normalizeSentence(input, maxSpanTokens: 0), singleTokenResult)
        XCTAssertNotEqual(singleTokenResult, NemoTextProcessing.normalizeSentence(input, maxSpanTokens: 4))
    }

    func testNormalizeSentenceWithMaxSpanHandlesEmptyAndWrittenText() {
        for input in ["", "I have 21 apples and $5"] {
            XCTAssertEqual(NemoTextProcessing.normalizeSentence(input, maxSpanTokens: 4), input)
        }
    }
}
