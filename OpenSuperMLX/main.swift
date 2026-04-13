// main.swift
// OpenSuperMLX

import Foundation

let cliSubcommands: Set<String> = [
    "transcribe", "stream-simulate", "correct", "config",
    "recordings", "queue", "mic", "model", "benchmark", "diagnose",
]

let args = CommandLine.arguments.dropFirst()
if args.contains(where: { cliSubcommands.contains($0) }) || args.first == "--help" || args.first == "-h" {
    OpenSuperMLXCLI.main()
} else {
    OpenSuperMLXApp.main()
}
