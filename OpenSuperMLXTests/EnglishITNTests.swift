// EnglishITNTests.swift
// OpenSuperMLXTests

import XCTest
@testable import OpenSuperMLX

final class EnglishITNTests: XCTestCase {

    // MARK: - Cardinal Numbers

    func testCardinalNumber() throws {
        XCTAssertEqual(NemoTextProcessing.normalize("twenty one"), "21")
    }

    func testLargeCardinal() throws {
        XCTAssertEqual(NemoTextProcessing.normalize("two hundred thirty two"), "232")
    }

    // MARK: - Ordinal Numbers

    func testOrdinal() throws {
        XCTAssertEqual(NemoTextProcessing.normalize("twenty first"), "21st")
    }

    // MARK: - Money

    func testDollars() throws {
        XCTAssertEqual(NemoTextProcessing.normalize("five dollars"), "$5")
    }

    func testDollarsAndCents() throws {
        XCTAssertEqual(NemoTextProcessing.normalize("five dollars and fifty cents"), "$5.50")
    }

    // MARK: - Decimals

    func testDecimal() throws {
        XCTAssertEqual(NemoTextProcessing.normalize("three point five"), "3.5")
    }

    // MARK: - Sentence Normalization

    func testSentence() throws {
        XCTAssertEqual(
            NemoTextProcessing.normalizeSentence("I have twenty one apples"),
            "I have 21 apples"
        )
    }

    func testMixedSentence() throws {
        XCTAssertEqual(
            NemoTextProcessing.normalizeSentence("it costs five dollars and thirty cents"),
            "it costs $5.30"
        )
    }

    // MARK: - Pass-through

    func testChinesePassthrough() throws {
        XCTAssertEqual(NemoTextProcessing.normalize("你好世界"), "你好世界")
    }

    func testEmptyString() throws {
        XCTAssertEqual(NemoTextProcessing.normalize(""), "")
    }

    func testAlreadyNormalized() throws {
        XCTAssertEqual(
            NemoTextProcessing.normalizeSentence("I have 21 apples"),
            "I have 21 apples"
        )
    }

    // MARK: - Availability

    func testIsAvailable() throws {
        XCTAssertTrue(NemoTextProcessing.isAvailable())
    }

    func testVersionNotEmpty() throws {
        XCTAssertFalse(NemoTextProcessing.version.isEmpty)
    }

    // MARK: - Bilingual Pipeline Tests

    func testBilingualPipeline_MixedTextDoesNotCrash() throws {
        let input = "我花了twenty five元买了three个苹果"
        let afterChineseITN = ITNProcessor.process(input)
        let afterEnglishITN = NemoTextProcessing.normalizeSentence(afterChineseITN)
        XCTAssertFalse(afterEnglishITN.isEmpty, "Mixed text pipeline should produce non-empty output")
    }

    func testFullPipeline_EnglishTextWithProperBoundaries() throws {
        let input = "I spent twenty five dollars on three items"
        let afterEnglishITN = NemoTextProcessing.normalizeSentence(input)
        XCTAssertTrue(afterEnglishITN.contains("25"), "twenty five should become 25, got: \(afterEnglishITN)")
        XCTAssertTrue(afterEnglishITN.contains("3"), "three should become 3, got: \(afterEnglishITN)")
    }

    func testFullPipeline_ITNThenAutocorrect() throws {
        let input = "I have twenty one apples"
        let afterEnglishITN = NemoTextProcessing.normalizeSentence(input)
        let afterAutocorrect = AutocorrectWrapper.format(afterEnglishITN)
        XCTAssertTrue(afterAutocorrect.contains("21"), "Pipeline should normalize twenty one to 21")
    }

    // MARK: - Graceful Degradation

    func testAlreadyNormalizedPassthrough() throws {
        let input = "I have 21 apples and $5"
        let result = NemoTextProcessing.normalizeSentence(input)
        XCTAssertEqual(result, input)
    }

    func testGracefulDegradation_NeverCrashes() throws {
        let inputs: [String] = [
            "",
            "hello world",
            "今天天气很好",
            "mixed 混合 text 文字",
            "😀🎉🔥",
            "   ",
            String(repeating: "twenty one ", count: 50),
            "1234567890",
            "!@#$%^&*()",
            "日本語テスト",
            "한국어 테스트"
        ]

        for input in inputs {
            let result = NemoTextProcessing.normalizeSentence(input)
            XCTAssertNotNil(result)
        }
    }
}
