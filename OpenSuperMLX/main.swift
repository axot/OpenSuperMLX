//
//  main.swift
//  OpenSuperMLX
//

import Foundation

let args = CommandLine.arguments
if let idx = args.firstIndex(of: "--transcribe"), idx + 1 < args.count {
    let audioPath = args[idx + 1]
    let langIdx = args.firstIndex(of: "--language")
    let language = (langIdx != nil && langIdx! + 1 < args.count) ? args[langIdx! + 1] : "auto"
    Task { await CLITranscribe.run(audioPath: audioPath, language: language) }
    RunLoop.main.run()
} else {
    OpenSuperMLXApp.main()
}
