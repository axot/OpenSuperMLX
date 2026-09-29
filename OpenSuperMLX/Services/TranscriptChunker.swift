// TranscriptChunker.swift
// OpenSuperMLX

import Foundation

enum TranscriptChunker {

    struct Capacity: Equatable {
        enum Limit: Equatable {
            case output
            case context
        }

        // Largest transcript (in estimated tokens) one request can correct; ≤ 0 means none fits.
        let tokens: Int
        let limitedBy: Limit
    }

    private static let cjkTerminators: Set<Character> = ["。", "！", "？", "…"]
    private static let latinTerminators: Set<Character> = [".", "!", "?"]
    private static let closers: Set<Character> = ["”", "」", "』", "）", ")", "\"", "'", "’"]
    private static let clauseDelimiters: Set<Character> = ["、", "，", ",", "；", ";"]

    // MARK: - Estimates

    // Rough, deliberately conservative: CJK ≈ 1 token per character, other non-ASCII ≈ ½, ASCII ≈ ¼.
    static func estimatedTokens(_ text: String) -> Int {
        Int(weight(text).rounded(.up))
    }

    static func requestCapacity(options: LLMRequestOptions, promptTokens: Int) -> Capacity {
        let context = Double(options.contextTokens)
        let prompt = Double(promptTokens)
        let reserve = min(Double(options.reservedThinkingTokens), max(0, (context - prompt) / 4))
        // Corrected text is about as long as the input, and both share the context window.
        let outputBound = (Double(options.maxOutputTokens) - reserve) / 1.1
        let contextBound = (context - prompt - reserve) / 2.1
        let bound = min(outputBound, contextBound)
        return Capacity(
            tokens: Int((bound * 0.8).rounded(.down)),
            limitedBy: outputBound <= contextBound ? .output : .context
        )
    }

    // MARK: - Splitting

    static func sentences(_ text: String) -> [String] {
        let characters = Array(text)
        var sentences: [String] = []
        var start = 0
        var index = 0

        while index < characters.count {
            if isSentenceEnd(characters, at: index) {
                var end = index + 1
                while end < characters.count,
                      closers.contains(characters[end]) || cjkTerminators.contains(characters[end]) {
                    end += 1
                }
                sentences.append(String(characters[start..<end]))
                start = end
                index = end
            } else {
                index += 1
            }
        }
        if start < characters.count {
            sentences.append(String(characters[start...]))
        }
        return sentences
    }

    // Splits into the fewest chunks that each fit `capacity`, balanced in size, cut at sentence ends
    // where possible. `chunks(text).joined() == text`.
    static func chunks(_ text: String, capacity: Int) -> [String] {
        guard capacity > 0, weight(text) > Double(capacity) else { return [text] }

        let pieces = sentences(text).flatMap { sentence in
            weight(sentence) > Double(capacity) ? splitOversized(sentence, capacity: capacity) : [sentence]
        }
        let weights = pieces.map(weight)
        var remaining = weights.reduce(0, +)
        var chunks: [String] = []
        var index = 0

        while index < pieces.count {
            let target = remaining / (remaining / Double(capacity)).rounded(.up)
            var chunk = ""
            var chunkWeight = 0.0
            while index < pieces.count {
                let next = chunkWeight + weights[index]
                if chunkWeight > 0, next > Double(capacity) || chunkWeight >= target { break }
                if chunkWeight > 0, next > target, next - target > target - chunkWeight { break }
                chunk += pieces[index]
                chunkWeight = next
                index += 1
            }
            chunks.append(chunk)
            remaining -= chunkWeight
        }
        return chunks
    }

    // Rejoins corrected chunks as continuous text: paragraph breaks come only from the model's output.
    static func join(_ chunks: [String]) -> String {
        chunks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: "") { result, chunk in
                if let last = result.unicodeScalars.last, let first = chunk.unicodeScalars.first,
                   !isCJK(last), !isCJK(first) {
                    result += " "
                }
                result += chunk
            }
    }

    // MARK: - Private

    private static func weight(_ text: String) -> Double {
        text.unicodeScalars.reduce(0) { total, scalar in
            if scalar.isASCII { return total + 0.25 }
            return total + (isCJK(scalar) ? 1 : 0.5)
        }
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x11FF, 0x2E80...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF00...0xFFEF, 0x20000...0x3FFFF:
            return true
        default:
            return false
        }
    }

    private static func isSentenceEnd(_ characters: [Character], at index: Int) -> Bool {
        let character = characters[index]
        if cjkTerminators.contains(character) { return true }
        guard latinTerminators.contains(character) else { return false }

        // Latin punctuation ends a sentence only before whitespace followed by a capital, digit,
        // CJK text or the end — so "3.5", "e.g. the" and "v1.2" stay intact.
        var next = index + 1
        while next < characters.count, closers.contains(characters[next]) { next += 1 }
        guard next < characters.count else { return true }
        guard characters[next].isWhitespace else { return false }
        while next < characters.count, characters[next].isWhitespace { next += 1 }
        guard next < characters.count else { return true }
        let following = characters[next]
        return following.isUppercase || following.isNumber
            || following.unicodeScalars.first.map(isCJK) == true
    }

    private static func splitOversized(_ sentence: String, capacity: Int) -> [String] {
        let limit = Double(capacity)
        return split(sentence, after: clauseDelimiters.contains)
            .flatMap { weight($0) > limit ? split($0, after: \.isWhitespace) : [$0] }
            .flatMap { weight($0) > limit ? $0.map(String.init) : [$0] }
    }

    private static func split(_ text: String, after isBoundary: (Character) -> Bool) -> [String] {
        var parts: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if isBoundary(character) {
                parts.append(current)
                current = ""
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }
}
