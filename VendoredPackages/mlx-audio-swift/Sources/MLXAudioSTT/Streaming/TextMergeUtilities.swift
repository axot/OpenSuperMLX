// TextMergeUtilities.swift
// MLXAudioSTT

import Foundation

enum TextMergeUtilities {

    static let cjkLanguageAliases: Set<String> = [
        "chinese", "zh", "zh-cn", "zh-tw", "cantonese", "yue",
        "japanese", "ja", "jp", "korean", "ko", "kr"
    ]

    private static func looksLikeCJK(_ text: String) -> Bool {
        let cjkCount = text.unicodeScalars.filter { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) ||
            (0x3040...0x30FF).contains(scalar.value) ||
            (0xAC00...0xD7AF).contains(scalar.value) ||
            (0x3400...0x4DBF).contains(scalar.value)
        }.count
        return cjkCount > text.count / 3
    }

    static func splitTextUnits(_ text: String, language: String) -> (units: [String], joiner: String) {
        let cleaned = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        let lang = language.trimmingCharacters(in: .whitespaces).lowercased()
        let isCJK = cjkLanguageAliases.contains(lang) || looksLikeCJK(cleaned)
        if isCJK {
            let chars = cleaned.replacingOccurrences(of: " ", with: "")
            return (chars.map(String.init), "")
        }
        if cleaned.contains(" ") {
            return (cleaned.split(separator: " ", omittingEmptySubsequences: true).map(String.init), " ")
        }
        return (cleaned.map(String.init), "")
    }

    static func splitStableUnstable(
        previousStable: String,
        newText: String,
        unfixedTokens: Int = 5,
        language: String = ""
    ) -> (stable: String, unstable: String) {
        let (units, joiner) = splitTextUnits(newText, language: language)
        if units.count <= unfixedTokens {
            return (previousStable, newText)
        }
        let stableUnits = Array(units.dropLast(unfixedTokens))
        let unstableUnits = Array(units.suffix(unfixedTokens))
        var stable = stableUnits.joined(separator: joiner)
        let unstable = unstableUnits.joined(separator: joiner)
        if stable.count < previousStable.count {
            stable = previousStable
        }
        return (stable, unstable)
    }

    private static func splitIntoUnits(_ text: String, joiner: String) -> [String] {
        if joiner == " " {
            return text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        }
        return text.map(String.init)
    }

    static func appendChunkText(
        current: String,
        addition: String,
        language: String
    ) -> String {
        let curr = current.trimmingCharacters(in: .whitespaces)
        let add = addition.trimmingCharacters(in: .whitespaces)
        if add.isEmpty { return curr }
        if curr.isEmpty { return add }
        if curr == add || curr.hasSuffix(add) { return curr }
        if add.hasPrefix(curr) { return add }

        let lang = language.trimmingCharacters(in: .whitespaces).lowercased()
        let joiner = cjkLanguageAliases.contains(lang) ? "" : " "

        let currUnits = splitIntoUnits(curr, joiner: joiner)
        let addUnits = splitIntoUnits(add, joiner: joiner)

        let prefixCheck = joiner == " " ? 3 : 6
        let prefN = min(prefixCheck, currUnits.count, addUnits.count)
        if prefN > 0 && Array(currUnits.prefix(prefN)) == Array(addUnits.prefix(prefN)) {
            if addUnits.count >= currUnits.count {
                return add
            }
        }

        let maxOverlap = min(currUnits.count, addUnits.count)
        var overlap = 0
        for k in stride(from: maxOverlap, through: 1, by: -1) {
            if Array(currUnits.suffix(k)) == Array(addUnits.prefix(k)) {
                overlap = k
                break
            }
        }

        if overlap > 0 {
            let mergedUnits = currUnits + addUnits.dropFirst(overlap)
            return mergedUnits.joined(separator: joiner)
        }

        return "\(curr)\(joiner)\(add)"
    }

    private static let cjkTerminalPunctuation: Set<Character> = ["。", "！", "？", "…"]

    /// Merge text from consecutive VAD segments — suffix dedup + overlap detection only.
    /// Unlike `appendChunkText`, does NOT perform prefix replacement.
    static func mergeChunkText(
        accumulated: String,
        newChunk: String,
        language: String
    ) -> String {
        let curr = accumulated.trimmingCharacters(in: .whitespaces)
        let add = newChunk.trimmingCharacters(in: .whitespaces)
        if add.isEmpty { return curr }
        if curr.isEmpty { return add }
        if curr == add || curr.hasSuffix(add) { return curr }

        let lang = language.trimmingCharacters(in: .whitespaces).lowercased()
        let isCJK = cjkLanguageAliases.contains(lang) || looksLikeCJK(curr + add)
        let joiner = isCJK ? "" : " "

        var currCleaned = curr
        if isCJK {
            while let last = currCleaned.last, cjkTerminalPunctuation.contains(last) {
                currCleaned = String(currCleaned.dropLast())
            }
        }

        let currUnits = splitIntoUnits(currCleaned, joiner: joiner)
        let addUnits = splitIntoUnits(add, joiner: joiner)

        let maxOverlap = min(currUnits.count, addUnits.count)
        for k in stride(from: maxOverlap, through: 1, by: -1) {
            if Array(currUnits.suffix(k)) == Array(addUnits.prefix(k)) {
                let mergedUnits = currUnits + addUnits.dropFirst(k)
                return mergedUnits.joined(separator: joiner)
            }
        }

        return "\(currCleaned)\(joiner)\(add)"
    }

    static func normalizeForDedup(_ text: String) -> String {
        String(text.filter { !$0.isPunctuation && !$0.isWhitespace })
    }

    static func parseASROutput(_ text: String) -> (language: String, text: String) {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return ("unknown", "") }

        var detectedLang = "unknown"
        var cleaned = s

        while let range = cleaned.range(of: "<asr_text>") {
            let langPart = cleaned[cleaned.startIndex..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            if langPart.hasSuffix("language ") || langPart.contains("language ") {
                if let langRange = langPart.range(of: "language ", options: .backwards) {
                    let lang = String(langPart[langRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if !lang.isEmpty && detectedLang == "unknown" { detectedLang = lang }
                }
            }
            let after = String(cleaned[range.upperBound...])
            let before = String(cleaned[cleaned.startIndex..<range.lowerBound])
            let beforeClean = before.replacingOccurrences(of: "language \\w+\\s*$", with: "", options: .regularExpression)
            cleaned = beforeClean + after
        }

        cleaned = stripTrailingSpecialTokens(cleaned)
        cleaned = cleaned.replacingOccurrences(
            of: "(language\\s*\\w*\\s*)+",
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)
        return (detectedLang, cleaned)
    }

    private static func stripTrailingSpecialTokens(_ text: String) -> String {
        var s = text
        let markers = ["<|im_end|>", "<|endoftext|>"]
        for marker in markers {
            if let range = s.range(of: marker) {
                s = String(s[s.startIndex..<range.lowerBound])
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
