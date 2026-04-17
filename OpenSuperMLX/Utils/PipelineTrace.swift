// PipelineTrace.swift
// OpenSuperMLX

import Foundation

final class PipelineTrace: @unchecked Sendable {
    static let shared = PipelineTrace()

    private var handle: FileHandle?
    private let lock = NSLock()

    private init() {}

    func start(directory: URL) {
        lock.lock()
        defer { lock.unlock() }
        handle?.closeFile()
        let timestamp = Int(Date().timeIntervalSince1970)
        let fileURL = directory.appendingPathComponent("\(timestamp)_pipeline.log")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        handle = FileHandle(forWritingAtPath: fileURL.path)
        writeUnsafe("TRACE START")
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        writeUnsafe("TRACE END")
        handle?.closeFile()
        handle = nil
    }

    func log(_ tag: String, _ msg: String) {
        lock.lock()
        defer { lock.unlock() }
        guard handle != nil else { return }
        writeUnsafe("[\(tag)] \(msg)")
    }

    private func writeUnsafe(_ msg: String) {
        let ts = String(format: "%.3f", Date().timeIntervalSinceReferenceDate)
        handle?.write(Data("\(ts) \(msg)\n".utf8))
    }
}
