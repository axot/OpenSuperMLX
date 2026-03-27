// RepetitionCleaner.swift
// OpenSuperMLX

import Foundation

enum RepetitionCleaner {
    static func fixCharRepeats(_ text: String, threshold: Int) -> String {
        let chars = Array(text)
        let n = chars.count
        var result: [Character] = []
        var i = 0
        while i < n {
            var count = 1
            while i + count < n && chars[i + count] == chars[i] {
                count += 1
            }
            if count > threshold {
                result.append(chars[i])
            } else {
                result.append(contentsOf: chars[i..<i + count])
            }
            i += count
        }
        return String(result)
    }

    static func fixPatternRepeats(_ text: String, threshold: Int, maxLen: Int) -> String {
        let chars = Array(text)
        let n = chars.count
        let minRepeatChars = threshold * 2
        guard n >= minRepeatChars else { return text }
        var i = 0
        var result: [Character] = []
        var foundRepeat = false
        outer: while i <= n - minRepeatChars {
            for k in 1...maxLen {
                if i + k * threshold > n { break }
                let pattern = Array(chars[i..<i + k])
                let valid = (1..<threshold).allSatisfy { rep in
                    let startIdx = i + rep * k
                    return Array(chars[startIdx..<startIdx + k]) == pattern
                }
                if valid {
                    var endIndex = i + threshold * k
                    while endIndex + k <= n && Array(chars[endIndex..<endIndex + k]) == pattern {
                        endIndex += k
                    }
                    result.append(contentsOf: pattern)
                    let remaining = String(chars[endIndex..<n])
                    result.append(contentsOf: Array(fixPatternRepeats(remaining, threshold: threshold, maxLen: maxLen)))
                    foundRepeat = true
                    break outer
                }
            }
            result.append(chars[i])
            i += 1
        }
        if !foundRepeat {
            result.append(contentsOf: chars[i..<n])
        }
        return String(result)
    }

    static func clean(_ text: String, threshold: Int = 20, maxLen: Int = 20) -> String {
        let step1 = fixCharRepeats(text, threshold: threshold)
        let step2 = fixPatternRepeats(step1, threshold: threshold, maxLen: maxLen)
        return deduplicateSentences(step2)
    }

    // MARK: - Sentence-Level Dedup

    private static let sentenceDelimiters = CharacterSet(charactersIn: "。！？!?")

    static func deduplicateSentences(_ text: String, maxOccurrences: Int = 2) -> String {
        let sentences = splitSentences(text)
        guard sentences.count > maxOccurrences else { return text }

        var counts: [String: Int] = [:]
        var result: [String] = []

        for sentence in sentences {
            let key = sentence.filter { !$0.isWhitespace }
            guard !key.isEmpty else {
                result.append(sentence)
                continue
            }
            counts[key, default: 0] += 1
            if counts[key]! <= maxOccurrences {
                result.append(sentence)
            }
        }

        return result.joined()
    }

    private static func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""

        for char in text {
            current.append(char)
            if char.unicodeScalars.allSatisfy({ sentenceDelimiters.contains($0) }) {
                sentences.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            sentences.append(current)
        }
        return sentences
    }
}
