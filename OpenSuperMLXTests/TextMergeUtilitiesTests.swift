// TextMergeUtilitiesTests.swift
// OpenSuperMLXTests

import XCTest

@testable import MLXAudioSTT

final class TextMergeUtilitiesTests: XCTestCase {

    // MARK: - extractTextTokenIds

    func testExtractTextTokenIdsNoMarker() {
        let tokens = [100, 200, 300]
        XCTAssertEqual(TextMergeUtilities.extractTextTokenIds(tokens), [100, 200, 300])
    }

    func testExtractTextTokenIdsWithMarker() {
        let tokens = [151704, 100, 200, 300]
        XCTAssertEqual(TextMergeUtilities.extractTextTokenIds(tokens), [100, 200, 300])
    }

    func testExtractTextTokenIdsMarkerOnly() {
        XCTAssertEqual(TextMergeUtilities.extractTextTokenIds([151704]), [])
    }

    func testExtractTextTokenIdsEmpty() {
        XCTAssertEqual(TextMergeUtilities.extractTextTokenIds([]), [])
    }

    // MARK: - mergeTokensWithOverlapRemoval

    func testMergeTokensExactOverlap() {
        let prefix = [1, 2, 3, 4, 5]
        let newTokens = [3, 4, 5, 6, 7]
        XCTAssertEqual(
            TextMergeUtilities.mergeTokensWithOverlapRemoval(prefix: prefix, newTokens: newTokens),
            [1, 2, 3, 4, 5, 6, 7])
    }

    func testMergeTokensNoOverlap() {
        let prefix = [1, 2, 3]
        let newTokens = [4, 5, 6]
        XCTAssertEqual(
            TextMergeUtilities.mergeTokensWithOverlapRemoval(prefix: prefix, newTokens: newTokens),
            [1, 2, 3, 4, 5, 6])
    }

    func testMergeTokensFullOverlap() {
        let prefix = [1, 2, 3, 4, 5]
        let newTokens = [1, 2, 3, 4, 5]
        XCTAssertEqual(
            TextMergeUtilities.mergeTokensWithOverlapRemoval(prefix: prefix, newTokens: newTokens),
            [1, 2, 3, 4, 5])
    }

    func testMergeTokensEmptyPrefix() {
        XCTAssertEqual(
            TextMergeUtilities.mergeTokensWithOverlapRemoval(prefix: [], newTokens: [1, 2]),
            [1, 2])
    }

    func testMergeTokensEmptyNew() {
        XCTAssertEqual(
            TextMergeUtilities.mergeTokensWithOverlapRemoval(prefix: [1, 2], newTokens: []),
            [1, 2])
    }

    func testMergeTokensCarryTokenScenario() {
        let accumulated = Array(1...100)
        let carryTokens = Array(77...100)
        let newTokens = carryTokens + [101, 102, 103]
        XCTAssertEqual(
            TextMergeUtilities.mergeTokensWithOverlapRemoval(prefix: accumulated, newTokens: newTokens),
            Array(1...103))
    }
}
