// BenchmarkCommand.swift
// OpenSuperMLX

import Foundation

import ArgumentParser

struct BenchmarkCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "benchmark",
        abstract: "Run transcription benchmarks"
    )

    @OptionGroup var globalOptions: GlobalOptions

    @Argument var file: String?

    @Flag(name: .long, help: "Run the full benchmark suite")
    var suite = false

    func run() async throws {
    }
}
