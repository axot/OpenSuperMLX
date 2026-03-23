// ITNProcessor.swift
// OpenSuperMLX

import Foundation
import os

private let logger = Logger(subsystem: "OpenSuperMLX", category: "ITNProcessor")

class ITNProcessor {

    /// Apply Inverse Text Normalization to Chinese text using WeTextProcessing
    /// - Parameter text: The text to process
    /// - Returns: The processed text, or original text if processing fails
    static func process(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        guard text.range(of: "\\p{Han}", options: .regularExpression) != nil else {
            return text
        }

        guard let binaryPath = findBinaryPath() else {
            logger.warning("processor_main binary not found, skipping ITN")
            return text
        }

        guard let taggerPath = findFSTPath(name: "zh_itn_tagger"),
              let verbalizerPath = findFSTPath(name: "zh_itn_verbalizer") else {
            logger.warning("ITN FST files not found, skipping ITN")
            return text
        }

        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binaryPath)
            process.arguments = [
                "--tagger", taggerPath,
                "--verbalizer", verbalizerPath,
                "--text", text
            ]

            let stdoutPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = FileHandle.nullDevice

            try process.run()
            let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                logger.warning("processor_main exited with status \(process.terminationStatus), returning original text")
                return text
            }

            guard let output = String(data: outputData, encoding: .utf8) else {
                logger.warning("Failed to decode processor_main output as UTF-8")
                return text
            }

            let result = output.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .last ?? ""

            return result.isEmpty ? text : result
        } catch {
            logger.error("Failed to run processor_main: \(error)")
            return text
        }
    }

    /// Check whether the ITN binary and FST files are all available
    /// - Returns: true if processor_main and both FST files can be found
    static func isAvailable() -> Bool {
        guard findBinaryPath() != nil else { return false }
        guard findFSTPath(name: "zh_itn_tagger") != nil else { return false }
        guard findFSTPath(name: "zh_itn_verbalizer") != nil else { return false }
        return true
    }

    // MARK: - Private helpers

    private static func findBinaryPath() -> String? {
        // processor_main is copied to Contents/MacOS/ via the "Copy Executables" build phase
        if let execDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            let path = execDir.appendingPathComponent("processor_main").path
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Fallback: check Resources in case build phase destination changes
        if let bundlePath = Bundle.main.path(forResource: "processor_main", ofType: nil),
           FileManager.default.isExecutableFile(atPath: bundlePath) {
            return bundlePath
        }

        let devPaths = [
            "build/processor_main",
            "WeTextProcessing/build/bin/processor_main"
        ]

        for path in devPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        return nil
    }

    private static func findFSTPath(name: String) -> String? {
        if let bundlePath = Bundle.main.path(forResource: name, ofType: "fst") {
            return bundlePath
        }

        let devPaths = [
            "Resources/ITN/\(name).fst",
            "build/\(name).fst"
        ]

        for path in devPaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        return nil
    }
}
