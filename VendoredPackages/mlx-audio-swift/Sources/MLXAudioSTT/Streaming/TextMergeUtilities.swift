// TextMergeUtilities.swift
// MLXAudioSTT

import Foundation

enum TextMergeUtilities {

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
            of: "^(language\\s*\\w*\\s*)+",
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

    // MARK: - Overlap Merge

    static func mergeWithOverlapRemoval(
        prefix: String,
        newText: String,
        maxOverlap: Int = 200
    ) -> String {
        guard !prefix.isEmpty, !newText.isEmpty else { return prefix + newText }
        let maxCheck = min(maxOverlap, prefix.count, newText.count)
        for len in stride(from: maxCheck, through: 1, by: -1) {
            if prefix.hasSuffix(String(newText.prefix(len))) {
                return prefix + newText.dropFirst(len)
            }
        }
        return prefix + newText
    }
}
