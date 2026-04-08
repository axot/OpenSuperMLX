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
}
