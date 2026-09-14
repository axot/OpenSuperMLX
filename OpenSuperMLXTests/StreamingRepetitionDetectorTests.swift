// StreamingRepetitionDetectorTests.swift
// OpenSuperMLXTests

import XCTest

@testable import MLXAudioSTT

final class StreamingRepetitionDetectorTests: XCTestCase {
    private let cjk = "甲乙丙丁戊己庚辛壬癸子丑寅卯辰巳"

    func testAnyQualifiedCandidateWinsAcrossMixedScripts() {
        let ascii = "abcdefghijklmnopq"
        var detector = StreamingRepetitionDetector()
        let match = detector.update(history: cjk + ascii, query: ascii + cjk)
        XCTAssertNotNil(match)
        XCTAssertGreaterThanOrEqual(match?.utf8Bytes ?? 0, 48)
        XCTAssertNil(detector.update(history: ascii, query: ascii))
        XCTAssertNotNil(detector.update(history: cjk, query: cjk))
        XCTAssertNil(detector.update(history: "", query: cjk))
        XCTAssertNil(detector.update(history: cjk, query: ""))
    }

    func testByteAndEditBoundariesIncludeHistoryLengthBudget() {
        var detector = StreamingRepetitionDetector()
        let ascii = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUV"
        XCTAssertEqual(ascii.utf8.count, 48)
        XCTAssertNil(detector.update(history: ascii, query: String(ascii.dropLast())))
        XCTAssertNotNil(detector.update(history: ascii, query: ascii))
        let history = Array("甲乙丙丁戊己庚辛壬癸子丑寅卯辰巳午未申酉".unicodeScalars)
        let query = String(String.UnicodeScalarView(history.enumerated().compactMap {
            [4, 9, 14].contains($0.offset) ? nil : $0.element
        }))
        let match = detector.update(history: String(String.UnicodeScalarView(history)), query: query)
        XCTAssertEqual(match?.edits, 3)
        XCTAssertEqual(match?.historyRange.count, 20)
        XCTAssertNotNil(match)
        let queryBudgetMatch = detector.update(history: query, query: String(String.UnicodeScalarView(history)))
        XCTAssertEqual(queryBudgetMatch?.edits, 3)
        XCTAssertEqual(queryBudgetMatch?.queryRange.count, 20)
        let beyondBudget = "甲乙丙丁中己庚辛中癸子丑中卯辰巳中未申酉"
        XCTAssertNil(detector.update(history: String(String.UnicodeScalarView(history)), query: beyondBudget))
    }

    func testNormalizationPreservesMixedTextAndInvisibleCharacters() {
        for (source, expected) in [
            ("Straße ＡＢＣ ﬃ Σςσ", "strasse abc ffi σσσ"),
            ("İIı e\u{301} \u{200B}\t", "i\u{307}iı é \u{200B}\t"),
            ("\u{AB70}\u{13A0}\u{13F8}", "\u{13A0}\u{13A0}\u{13F0}"),
            ("\u{1C80}\u{1C81}\u{1C82}\u{1C83}\u{1C84}\u{1C85}\u{1C86}\u{1C87}\u{1C88}", "вдосттъѣꙋ"),
        ] {
            XCTAssertEqual(StreamingRepetitionDetector.normalize(source), expected)
        }
        var detector = StreamingRepetitionDetector(minimumBytes: 1)
        XCTAssertNotNil(detector.update(history: "Straße日本中文", query: "STRASSE日本中文"))
        XCTAssertNil(detector.update(history: "カナ", query: "かな"))
        XCTAssertNil(detector.update(history: "\u{200B}", query: " "))
    }

    func testPrefixReuseRollbackAndNormalizationRewriteMatchFreshScan() {
        var detector = StreamingRepetitionDetector(minimumBytes: 3)
        for (history, query) in [
            ("a中", "a"), ("a中", "a中"), ("a中b", "a中"),
            ("a中b", "a"), ("a中b", "a"), ("a中b", "a中b"),
            ("a中b", "e"), ("a中b", "e\u{301}"), ("中b", "中"),
        ] {
            var fresh = StreamingRepetitionDetector(minimumBytes: 3)
            XCTAssertEqual(detector.update(history: history, query: query), fresh.update(history: history, query: query))
        }
        _ = detector.update(history: "中b", query: "中")
        XCTAssertEqual(detector.computedCells, 0)
        _ = detector.update(history: "中b", query: "")
        XCTAssertEqual(detector.computedCells, 0)
    }

    func testBoundedFallbackPreservesWitnessAndReleasesRetainedCells() {
        var cached = StreamingRepetitionDetector(minimumBytes: 3)
        var bounded = StreamingRepetitionDetector(minimumBytes: 3, maximumCachedCells: 20)
        for query in ["a", "a中", "a中b甲乙", "a", cjk, "乙"] {
            XCTAssertEqual(bounded.update(history: "a中b" + cjk, query: query),
                           cached.update(history: "a中b" + cjk, query: query))
            XCTAssertLessThanOrEqual(bounded.retainedCells, 20)
        }
        bounded.reset()
        XCTAssertEqual(bounded.retainedCells, 0)
        _ = bounded.update(history: cjk, query: cjk)
        _ = bounded.update(history: cjk, query: cjk)
        XCTAssertEqual(bounded.computedCells, 0)
        _ = bounded.update(history: cjk, query: String(repeating: "x", count: 30))
        XCTAssertNil(bounded.update(history: cjk, query: String(repeating: "x", count: 30)))
        XCTAssertEqual(bounded.computedCells, 0)
        var frontier = StreamingRepetitionDetector(minimumBytes: 3, maximumCachedCells: 80)
        _ = frontier.update(history: "abc", query: "abcabc")
        _ = frontier.update(history: "abc", query: "abcab")
        XCTAssertEqual(frontier.computedCells, 0)
        _ = frontier.update(history: "abc", query: "a")
        XCTAssertGreaterThan(frontier.computedCells, 0)
        for (h, q) in [("abcd", "abcabc"), ("ab", "abcabc"), ("abcd", "abcabcd"), ("abcd", "abcab")] {
            var fresh = StreamingRepetitionDetector(minimumBytes: 3, maximumCachedCells: 0)
            XCTAssertEqual(frontier.update(history: h, query: q), fresh.update(history: h, query: q))
            XCTAssertLessThanOrEqual(frontier.retainedCells, 80)
        }
    }

    func testExhaustiveSmallInputsAgainstIndependentSubstringLevenshtein() {
        let words = ["", "a", "中", "aa", "a中", "中a", "中中",
                     "aaa", "aa中", "a中a", "a中中", "中aa", "中a中", "中中a", "中中中"]
        for minimum in [1, 3, 4, 6] {
            for budget in [0, 250_000] {
                var detector = StreamingRepetitionDetector(minimumBytes: minimum, maximumCachedCells: budget)
                for history in words {
                    for query in words {
                        let match = detector.update(history: history, query: query)
                        XCTAssertEqual(match != nil,
                                       reference(history: history, query: query, minimum: minimum),
                                       "\(history) / \(query) / \(minimum)")
                        if let match {
                            let h = Array(history.unicodeScalars)[match.historyRange]
                            let q = Array(query.unicodeScalars)[match.queryRange]
                            XCTAssertEqual(match.edits, distance(Array(h), Array(q)))
                            XCTAssertEqual(match.utf8Bytes, String(String.UnicodeScalarView(q)).utf8.count)
                        }
                    }
                }
            }
        }
    }

    func testMutatingSnapshotsMatchZeroCacheAndIndependentReference() {
        var cached = StreamingRepetitionDetector(minimumBytes: 3)
        var uncached = StreamingRepetitionDetector(minimumBytes: 3, maximumCachedCells: 0)
        var seed: UInt64 = 7
        var history = ""
        var query = ""
        let alphabet = ["a", "中", "A", "e", "\u{301}", "ß", "\u{200B}"]
        for _ in 0..<400 {
            seed = seed &* 6364136223846793005 &+ 1
            let scalar = alphabet[Int((seed >> 32) % UInt64(alphabet.count))]
            switch seed % 5 {
            case 0: history += scalar
            case 1: query += scalar
            case 2: query = history
            case 3: query = String(query.dropLast())
            default: history = String(history.dropFirst())
            }
            history = String(history.suffix(6))
            query = String(query.suffix(6))
            let match = cached.update(history: history, query: query)
            XCTAssertEqual(match, uncached.update(history: history, query: query))
            XCTAssertEqual(match != nil, reference(
                history: StreamingRepetitionDetector.normalize(history),
                query: StreamingRepetitionDetector.normalize(query), minimum: 3
            ))
        }
    }

    // MARK: - Independent Reference

    private func reference(history: String, query: String, minimum: Int) -> Bool {
        let h = Array(history.unicodeScalars)
        let q = Array(query.unicodeScalars)
        for a in h.indices {
            for i in (a + 1)...h.count {
                for b in q.indices {
                    for j in (b + 1)...q.count {
                        guard String(String.UnicodeScalarView(q[b..<j])).utf8.count >= minimum else { continue }
                        let left = Array(h[a..<i])
                        let right = Array(q[b..<j])
                        if 20 * distance(left, right) <= 3 * max(left.count, right.count) { return true }
                    }
                }
            }
        }
        return false
    }

    private func distance(_ left: [Unicode.Scalar], _ right: [Unicode.Scalar]) -> Int {
        var row = Array(0...right.count)
        for (index, scalar) in left.enumerated() {
            var next = [index + 1]
            for (offset, other) in right.enumerated() {
                next.append(min(row[offset] + (scalar == other ? 0 : 1),
                                row[offset + 1] + 1, next[offset] + 1))
            }
            row = next
        }
        return row.last!
    }
}
