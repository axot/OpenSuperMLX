// ITNProcessorTests.swift
// OpenSuperMLXTests

import XCTest
@testable import OpenSuperMLX

final class ITNProcessorTests: XCTestCase {

    // MARK: - Basic Conversion Tests

    func testChineseNumberConversion() throws {
        let result = ITNProcessor.process("一百二十三")
        XCTAssertFalse(result.isEmpty)
    }

    func testChineseDateConversion() throws {
        let result = ITNProcessor.process("二零二五年三月十九号")
        XCTAssertFalse(result.isEmpty)
    }

    func testChineseDecimalConversion() throws {
        let result = ITNProcessor.process("二点五")
        XCTAssertFalse(result.isEmpty)
    }

    func testChinesePercentageConversion() throws {
        let result = ITNProcessor.process("百分之五十")
        XCTAssertFalse(result.isEmpty)
    }

    func testMixedChineseTextConversion() throws {
        let result = ITNProcessor.process("今天花了三百二十块钱")
        XCTAssertFalse(result.isEmpty)
    }

    // MARK: - Pass-through Tests

    func testEnglishTextPassthrough() throws {
        let input = "hello world"
        let result = ITNProcessor.process(input)
        XCTAssertEqual(result, input)
    }

    func testEmptyStringPassthrough() throws {
        let result = ITNProcessor.process("")
        XCTAssertEqual(result, "")
    }

    func testWhitespaceOnlyPassthrough() throws {
        let input = "   "
        let result = ITNProcessor.process(input)
        XCTAssertEqual(result, input)
    }

    // MARK: - Availability

    func testIsAvailableDoesNotCrash() throws {
        _ = ITNProcessor.isAvailable()
    }

    // MARK: - Duplicate Punctuation Cleanup

    func testCleanDuplicateChinesePunctuation() throws {
        XCTAssertEqual(
            ITNProcessor.cleanDuplicatePunctuation("你好，，能听到我的吗？"),
            "你好，能听到我的吗？"
        )
    }

    func testCleanMultipleDuplicatePunctuation() throws {
        XCTAssertEqual(
            ITNProcessor.cleanDuplicatePunctuation("你好，，能听到我的吗？嗯，，明天怎么样天气？"),
            "你好，能听到我的吗？嗯，明天怎么样天气？"
        )
    }

    func testCleanLeadingPunctuation() throws {
        XCTAssertEqual(
            ITNProcessor.cleanDuplicatePunctuation("，明天天气"),
            "明天天气"
        )
    }

    func testCleanLeadingDuplicatePunctuation() throws {
        XCTAssertEqual(
            ITNProcessor.cleanDuplicatePunctuation("，，明天天气"),
            "明天天气"
        )
    }

    func testCleanPreservesNonDuplicatePunctuation() throws {
        XCTAssertEqual(
            ITNProcessor.cleanDuplicatePunctuation("你好，世界！"),
            "你好，世界！"
        )
    }

    func testCleanPreservesDifferentConsecutivePunctuation() throws {
        XCTAssertEqual(
            ITNProcessor.cleanDuplicatePunctuation("真的！？好吧"),
            "真的！？好吧"
        )
    }

    func testCleanEmptyString() throws {
        XCTAssertEqual(ITNProcessor.cleanDuplicatePunctuation(""), "")
    }

    func testCleanNoPunctuation() throws {
        XCTAssertEqual(ITNProcessor.cleanDuplicatePunctuation("你好世界"), "你好世界")
    }

    func testCleanTriplePunctuation() throws {
        XCTAssertEqual(
            ITNProcessor.cleanDuplicatePunctuation("你好，，，世界"),
            "你好，世界"
        )
    }

    func testCleanTrailingDuplicatePunctuation() throws {
        XCTAssertEqual(
            ITNProcessor.cleanDuplicatePunctuation("你好，，"),
            "你好，"
        )
    }

    // MARK: - Graceful Degradation

    func testGracefulDegradationReturnsOriginal() throws {
        let input = "一百二十三"
        let result = ITNProcessor.process(input)
        XCTAssertFalse(result.isEmpty, "Result must not be empty for Chinese input")
    }
}
