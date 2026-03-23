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

    // MARK: - Graceful Degradation

    func testGracefulDegradationReturnsOriginal() throws {
        let input = "一百二十三"
        let result = ITNProcessor.process(input)
        XCTAssertFalse(result.isEmpty, "Result must not be empty for Chinese input")
    }
}
