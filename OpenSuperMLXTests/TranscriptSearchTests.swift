// TranscriptSearchTests.swift
// OpenSuperMLXTests

import Combine
import XCTest

@testable import OpenSuperMLX

final class TranscriptSearchTests: XCTestCase {
    func testLiteralCaseInsensitiveMatches() {
        var search = TranscriptSearch()
        search.update(text: "A.B [x] a.b", query: "a.b")
        XCTAssertEqual(search.ranges, [NSRange(location: 0, length: 3), NSRange(location: 8, length: 3)])
        search.update(text: "A.B [x] a.b", query: "[x]")
        XCTAssertEqual(search.ranges, [NSRange(location: 4, length: 3)])
    }

    func testUnicodeRangesUseTextStorageOffsets() {
        var search = TranscriptSearch()
        search.update(text: "🎙录音 🎙录音", query: "录音")
        XCTAssertEqual(search.ranges, [NSRange(location: 2, length: 2), NSRange(location: 7, length: 2)])
    }

    func testEmptyAndMissingQueriesHaveNoSelection() {
        var search = TranscriptSearch()
        for query in ["", " \n ", "missing"] {
            search.update(text: "录音", query: query)
            XCTAssertTrue(search.ranges.isEmpty)
            XCTAssertNil(search.selectedRange)
            search.move(by: -1)
            XCTAssertNil(search.selectedRange)
        }
    }

    func testNavigationWrapsInBothDirections() {
        var search = TranscriptSearch()
        search.update(text: "录音和录音", query: "录音")
        XCTAssertEqual(search.selectedIndex, 0)
        search.move(by: -1)
        XCTAssertEqual(search.selectedIndex, 1)
        search.move(by: 1)
        XCTAssertEqual(search.selectedIndex, 0)
        search.move(by: 1)
        XCTAssertEqual(search.selectedRange, NSRange(location: 3, length: 2))
    }

    func testAppendingLiveTextPreservesSelectedMatch() {
        var search = TranscriptSearch()
        search.update(text: "录音和录音", query: "录音")
        search.move(by: 1)
        search.update(text: "录音和录音以及录音", query: "录音")
        XCTAssertEqual(search.selectedIndex, 1)
        XCTAssertEqual(search.ranges.count, 3)
        search.update(text: "录音", query: "录音")
        XCTAssertEqual(search.selectedIndex, 0)
    }

    func testChangingQueryOrDocumentResetsSelection() {
        var search = TranscriptSearch()
        search.update(text: "one ONE two", query: "one")
        search.move(by: 1)
        search.update(text: "one ONE two", query: "two")
        XCTAssertEqual(search.selectedIndex, 0)
        XCTAssertEqual(search.selectedRange, NSRange(location: 8, length: 3))
        search.update(text: "two two", query: "two", resetSelection: true)
        XCTAssertEqual(search.selectedIndex, 0)
    }

    func testWhitespaceInLiteralQueryIsPreserved() {
        var search = TranscriptSearch()
        search.update(text: "someone one anyone", query: " one ")
        XCTAssertEqual(search.ranges, [NSRange(location: 7, length: 5)])
        search.update(text: "a  b", query: " ")
        XCTAssertEqual(search.ranges, [NSRange(location: 1, length: 1), NSRange(location: 2, length: 1)])
    }

    func testCanonicallyEquivalentLiteralQueryResetsSelection() {
        var search = TranscriptSearch()
        search.update(text: "e\u{301} e\u{301} é é", query: "e\u{301}")
        search.move(by: 1)
        search.update(text: "e\u{301} e\u{301} é é", query: "é")
        XCTAssertEqual(search.selectedIndex, 0)
        XCTAssertEqual(search.selectedRange, NSRange(location: 6, length: 1))
    }
}

final class TranscriptSearchInputTests: XCTestCase {
    func testInputEqualityPreservesExactUnicodeRepresentation() {
        XCTAssertEqual(TranscriptSearch.Input(text: "e\u{301}"), TranscriptSearch.Input(text: "e\u{301}"))
        XCTAssertNotEqual(TranscriptSearch.Input(text: "e\u{301}"), TranscriptSearch.Input(text: "é"))
    }

    func testCanonicalDocumentReplacementRecalculatesLiteralRanges() {
        let input = CurrentValueSubject<TranscriptSearch.Input, Never>(.init(text: "e\u{301}"))
        var search = TranscriptSearch()
        let subscription = input.removeDuplicates().sink {
            search.update(text: $0.text, query: "e\u{301}")
        }
        XCTAssertEqual(search.selectedRange, NSRange(location: 0, length: 2))
        input.send(.init(text: "é"))
        XCTAssertTrue(search.ranges.isEmpty)
        XCTAssertNil(search.selectedRange)
        withExtendedLifetime(subscription) {}
    }

    func testCanonicalQueryReplacementRecalculatesLiteralRanges() {
        let input = CurrentValueSubject<TranscriptSearch.Input, Never>(.init(text: "e\u{301}"))
        var search = TranscriptSearch()
        let subscription = input.removeDuplicates().sink {
            search.update(text: "e\u{301} e\u{301} é é", query: $0.text, resetSelection: true)
        }
        search.move(by: 1)
        input.send(.init(text: "é"))
        XCTAssertEqual(search.ranges, [NSRange(location: 6, length: 1), NSRange(location: 8, length: 1)])
        XCTAssertEqual(search.selectedIndex, 0)
        withExtendedLifetime(subscription) {}
    }
}
