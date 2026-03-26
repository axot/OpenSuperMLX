// WERCalculator.swift
// OpenSuperMLX

import Foundation

enum WERCalculator {

    // MARK: - Public API

    static func computeWER(reference: String, hypothesis: String) -> Double {
        let refWords = normalizeForWER(reference).split(separator: " ").map(String.init)
        let hypWords = normalizeForWER(hypothesis).split(separator: " ").map(String.init)
        return computeErrorRate(reference: refWords, hypothesis: hypWords)
    }

    static func computeCER(reference: String, hypothesis: String) -> Double {
        let refChars = Array(normalizeForWER(reference).filter { !$0.isWhitespace })
        let hypChars = Array(normalizeForWER(hypothesis).filter { !$0.isWhitespace })
        return computeErrorRate(reference: refChars, hypothesis: hypChars)
    }

    static func normalizeForWER(_ text: String) -> String {
        let nfkc = text.precomposedStringWithCompatibilityMapping
        let lowered = nfkc.lowercased()
        // Strip punctuation, keeping letters, digits, whitespace
        let stripped = lowered.components(separatedBy: CharacterSet.letters.union(.decimalDigits).union(.whitespaces).inverted).joined(separator: " ")
        let collapsed = stripped.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
        return collapsed
    }

    static func isCJKDominant(_ text: String) -> Bool {
        let scalars = text.unicodeScalars
        let cjkCount = scalars.filter { isCJKScalar($0) }.count
        let alphanumericCount = scalars.filter { $0.properties.isAlphabetic || CharacterSet.decimalDigits.contains($0) }.count
        guard alphanumericCount > 0 else { return false }
        return Double(cjkCount) / Double(alphanumericCount) > 0.5
    }

    // MARK: - Private Helpers

    private static func computeErrorRate<T: Equatable>(reference: [T], hypothesis: [T]) -> Double {
        if reference.isEmpty && hypothesis.isEmpty { return 0.0 }
        if reference.isEmpty { return 1.0 }
        let distance = editDistance(reference, hypothesis)
        return Double(distance) / Double(reference.count)
    }

    private static func isCJKScalar(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (v >= 0x4E00 && v <= 0x9FFF)   // CJK Unified Ideographs
            || (v >= 0x3040 && v <= 0x30FF)   // Hiragana + Katakana
            || (v >= 0xAC00 && v <= 0xD7AF)   // Hangul syllables
    }

    private static func editDistance<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        let m = a.count, n = b.count
        var dp = Array(0 ... n)
        for i in 1 ... m {
            var prev = dp[0]
            dp[0] = i
            for j in 1 ... n {
                let temp = dp[j]
                if a[i - 1] == b[j - 1] {
                    dp[j] = prev
                } else {
                    dp[j] = 1 + Swift.min(prev, dp[j], dp[j - 1])
                }
                prev = temp
            }
        }
        return dp[n]
    }
}
