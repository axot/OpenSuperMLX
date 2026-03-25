// NemoTextProcessing.swift
// OpenSuperMLX

import Foundation
import os

private let logger = Logger(subsystem: "OpenSuperMLX", category: "NemoTextProcessing")

enum NemoTextProcessing {

    // MARK: - ITN (Spoken → Written)

    static func normalize(_ input: String) -> String {
        callNemo(input) { nemo_normalize($0) }
    }

    static func normalizeSentence(_ input: String) -> String {
        callNemo(input) { nemo_normalize_sentence($0) }
    }

    static func normalizeSentence(_ input: String, maxSpanTokens: UInt32) -> String {
        callNemo(input) { nemo_normalize_sentence_with_max_span($0, maxSpanTokens) }
    }

    // MARK: - Private

    private static func callNemo(_ input: String, _ fn: (UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?) -> String {
        guard let cString = input.cString(using: .utf8) else {
            logger.error("Failed to convert text to C string")
            return input
        }
        guard let resultPtr = cString.withUnsafeBufferPointer({ fn($0.baseAddress) }) else {
            logger.error("nemo FFI call returned null")
            return input
        }
        defer { nemo_free_string(resultPtr) }
        return String(cString: resultPtr)
    }

    // MARK: - Availability

    static func isAvailable() -> Bool {
        guard let ptr = nemo_normalize("one") else { return false }
        nemo_free_string(ptr)
        return true
    }

    // MARK: - Info

    static var version: String {
        guard let versionPtr = nemo_version() else {
            return "unknown"
        }
        return String(cString: versionPtr)
    }
}
