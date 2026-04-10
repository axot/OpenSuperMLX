// WERCalculator.swift
// OpenSuperMLX

import Foundation

// MARK: - Result Types

struct WERResult: Encodable {
    let metric: String
    let score: Double
    let substitutions: Int
    let insertions: Int
    let deletions: Int

    enum CodingKeys: String, CodingKey {
        case metric, score, substitutions, insertions, deletions
    }
}

// MARK: - Calculator

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

    static func computeWERDetailed(reference: String, hypothesis: String) -> WERResult {
        let refWords = normalizeForWER(reference).split(separator: " ").map(String.init)
        let hypWords = normalizeForWER(hypothesis).split(separator: " ").map(String.init)
        return computeDetailedResult(reference: refWords, hypothesis: hypWords, metric: "WER")
    }

    static func computeCERDetailed(reference: String, hypothesis: String) -> WERResult {
        let refChars = Array(normalizeForWER(reference).filter { !$0.isWhitespace })
        let hypChars = Array(normalizeForWER(hypothesis).filter { !$0.isWhitespace })
        return computeDetailedResult(reference: refChars, hypothesis: hypChars, metric: "CER")
    }

    static func normalizeForWER(_ text: String) -> String {
        let nfkc = text.precomposedStringWithCompatibilityMapping
        let lowered = nfkc.lowercased()
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

    private static func computeDetailedResult<T: Equatable>(reference: [T], hypothesis: [T], metric: String) -> WERResult {
        if reference.isEmpty && hypothesis.isEmpty {
            return WERResult(metric: metric, score: 0.0, substitutions: 0, insertions: 0, deletions: 0)
        }
        if reference.isEmpty {
            return WERResult(metric: metric, score: 1.0, substitutions: 0, insertions: hypothesis.count, deletions: 0)
        }

        let (subs, ins, dels) = editOperations(reference, hypothesis)
        let score = Double(subs + ins + dels) / Double(reference.count)
        return WERResult(metric: metric, score: score, substitutions: subs, insertions: ins, deletions: dels)
    }

    private static func isCJKScalar(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (v >= 0x4E00 && v <= 0x9FFF)
            || (v >= 0x3040 && v <= 0x30FF)
            || (v >= 0xAC00 && v <= 0xD7AF)
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

    // Backtrace through DP matrix to classify edits as substitution/insertion/deletion
    private static func editOperations<T: Equatable>(_ a: [T], _ b: [T]) -> (substitutions: Int, insertions: Int, deletions: Int) {
        let m = a.count, n = b.count
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)

        for i in 0 ... m { dp[i][0] = i }
        for j in 0 ... n { dp[0][j] = j }

        for i in 1 ... m {
            for j in 1 ... n {
                if a[i - 1] == b[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1]
                } else {
                    dp[i][j] = 1 + Swift.min(dp[i - 1][j - 1], dp[i][j - 1], dp[i - 1][j])
                }
            }
        }

        var subs = 0, ins = 0, dels = 0
        var i = m, j = n
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && a[i - 1] == b[j - 1] {
                i -= 1; j -= 1
            } else if i > 0 && j > 0 && dp[i][j] == dp[i - 1][j - 1] + 1 {
                subs += 1; i -= 1; j -= 1
            } else if j > 0 && dp[i][j] == dp[i][j - 1] + 1 {
                ins += 1; j -= 1
            } else {
                dels += 1; i -= 1
            }
        }

        return (subs, ins, dels)
    }
}
