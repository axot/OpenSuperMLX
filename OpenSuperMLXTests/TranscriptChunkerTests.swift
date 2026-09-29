// TranscriptChunkerTests.swift
// OpenSuperMLXTests

import XCTest

@testable import OpenSuperMLX

final class TranscriptChunkerTests: XCTestCase {

    // MARK: - Token Estimate

    func testEstimatedTokens_CountsCJKPerCharacterOtherNonASCIIAtHalfAndASCIIAtQuarter() {
        XCTAssertEqual(TranscriptChunker.estimatedTokens(""), 0)
        XCTAssertEqual(TranscriptChunker.estimatedTokens("abcd"), 1)
        XCTAssertEqual(TranscriptChunker.estimatedTokens("abcde"), 2)
        XCTAssertEqual(TranscriptChunker.estimatedTokens("日本語です"), 5)
        XCTAssertEqual(TranscriptChunker.estimatedTokens("한국어"), 3)
        XCTAssertEqual(TranscriptChunker.estimatedTokens("Привет"), 3)
        XCTAssertEqual(TranscriptChunker.estimatedTokens("AI です"), 3)
    }

    // MARK: - Capacity

    func testRequestCapacity_OutputBoundWithThinkingReserve() {
        let capacity = TranscriptChunker.requestCapacity(
            options: LLMRequestOptions(
                contextTokens: 131_072, maxOutputTokens: 32_768, thinkingEnabled: true, thinkingEffort: .medium
            ),
            promptTokens: 1000
        )
        XCTAssertEqual(capacity.tokens, 17_873)
        XCTAssertEqual(capacity.limitedBy, .output)
    }

    func testRequestCapacity_ContextBoundAndImpossibleSettings() {
        let small = TranscriptChunker.requestCapacity(
            options: LLMRequestOptions(
                contextTokens: 8192, maxOutputTokens: 4096, thinkingEnabled: false, thinkingEffort: .medium
            ),
            promptTokens: 1000
        )
        XCTAssertEqual(small.tokens, 2739)
        XCTAssertEqual(small.limitedBy, .context)

        let impossible = TranscriptChunker.requestCapacity(
            options: LLMRequestOptions(
                contextTokens: 2048, maxOutputTokens: 4096, thinkingEnabled: true, thinkingEffort: .medium
            ),
            promptTokens: 2100
        )
        XCTAssertLessThanOrEqual(impossible.tokens, 0)
        XCTAssertEqual(impossible.limitedBy, .context)
    }

    // MARK: - Sentences

    func testSentences_SplitsCJKTerminatorsAndKeepsClosingBrackets() {
        let text = "「はい。」そうです。明日は雨！本当？"
        let sentences = TranscriptChunker.sentences(text)
        XCTAssertEqual(sentences, ["「はい。」", "そうです。", "明日は雨！", "本当？"])
        XCTAssertEqual(sentences.joined(), text)
    }

    func testSentences_LatinPeriodNeedsSpaceAndCapitalToEndASentence() {
        let text = "It costs 3.5 dollars, e.g. the base fee. Next one! done"
        let sentences = TranscriptChunker.sentences(text)
        XCTAssertEqual(sentences, ["It costs 3.5 dollars, e.g. the base fee.", " Next one! done"])
        XCTAssertEqual(sentences.joined(), text)
    }

    // MARK: - Chunks

    func testChunks_FitsInOneWhenSmallOtherwiseBalancedWithinCapacity() {
        let sentence = "あいうえおかきくけこ。"
        let text = String(repeating: sentence, count: 10)
        XCTAssertEqual(TranscriptChunker.chunks(text, capacity: 500), [text])

        let chunks = TranscriptChunker.chunks(text, capacity: 60)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks.joined(), text)
        XCTAssertTrue(chunks.allSatisfy { TranscriptChunker.estimatedTokens($0) <= 60 })
        XCTAssertEqual(TranscriptChunker.estimatedTokens(chunks[0]), TranscriptChunker.estimatedTokens(chunks[1]))
        XCTAssertEqual(TranscriptChunker.join([" 一。 ", "", "二。\n"]), "一。二。")
        XCTAssertEqual(TranscriptChunker.join(["First part.", "second part."]), "First part. second part.")
        XCTAssertEqual(TranscriptChunker.join(["Para one.\n\nPara two.", "続き。"]), "Para one.\n\nPara two.続き。")
    }

    func testChunks_UnpunctuatedCJKRunIsCutAtCapacity() {
        let text = String(repeating: "あ", count: 250)
        let chunks = TranscriptChunker.chunks(text, capacity: 100)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks.joined(), text)
        XCTAssertTrue(chunks.allSatisfy { TranscriptChunker.estimatedTokens($0) <= 100 })
    }

    func testChunks_LongLatinRunIsCutAtWhitespaceNotInsideWords() {
        let text = String(repeating: "word ", count: 100)
        let chunks = TranscriptChunker.chunks(text, capacity: 30)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.joined(), text)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(TranscriptChunker.estimatedTokens(chunk), 30)
            XCTAssertTrue(chunk.split(separator: " ").allSatisfy { $0 == "word" }, chunk)
        }
    }
}
