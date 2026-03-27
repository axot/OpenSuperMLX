// RepetitionDetector.swift
// MLXAudioSTT

enum RepetitionDetector {
    static func detectTokenRepetition(_ tokens: [Int], threshold: Int = 20) -> Bool {
        guard tokens.count >= threshold else { return false }

        let last = tokens[tokens.count - 1]
        if tokens.suffix(threshold).allSatisfy({ $0 == last }) {
            return true
        }

        for patternLen in 2...10 {
            let requiredReps = max(2, threshold / patternLen)
            let requiredTokens = patternLen * requiredReps
            guard tokens.count >= requiredTokens else { continue }

            let tail = Array(tokens.suffix(requiredTokens))
            let pattern = Array(tail.prefix(patternLen))
            let allMatch = (1..<requiredReps).allSatisfy { rep in
                let start = rep * patternLen
                return Array(tail[start..<start + patternLen]) == pattern
            }
            if allMatch { return true }
        }

        return false
    }
}
