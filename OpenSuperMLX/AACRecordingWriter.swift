// AACRecordingWriter.swift
// OpenSuperMLX

import AVFoundation
import Foundation

enum AACRecordingWriterError: Error {
    case finalized
    case bufferCreationFailed
}

protocol AACRecordingWriting: AnyObject {
    var framesWritten: Int { get }
    func writeChunk(_ samples: [Float]) throws
    func finalize() throws -> URL
    func cancel()
}

final class AACRecordingWriter: @unchecked Sendable {
    private let url: URL
    private let inputFormat: AVAudioFormat
    private let lock = NSLock()
    private var audioFile: AVAudioFile?
    private var writtenFrameCount = 0

    var framesWritten: Int {
        lock.lock()
        defer { lock.unlock() }
        return writtenFrameCount
    }

    init(url: URL, settings: [String: Any] = RecordingAudioFormat.aacSettings) throws {
        self.url = url
        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: RecordingAudioFormat.sampleRate,
            channels: AVAudioChannelCount(RecordingAudioFormat.channelCount),
            interleaved: false
        ) else {
            throw AACRecordingWriterError.bufferCreationFailed
        }
        self.inputFormat = inputFormat
        audioFile = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
    }

    func writeChunk(_ samples: [Float]) throws {
        guard !samples.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let audioFile else {
            throw AACRecordingWriterError.finalized
        }

        let frameCount = AVAudioFrameCount(samples.count)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: frameCount
        ) else {
            throw AACRecordingWriterError.bufferCreationFailed
        }
        buffer.frameLength = frameCount
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        try audioFile.write(from: buffer)
        writtenFrameCount += samples.count
    }

    func finalize() throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        audioFile = nil
        _ = try AVAudioFile(forReading: url)
        return url
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        audioFile = nil
        try? FileManager.default.removeItem(at: url)
    }
}

extension AACRecordingWriter: AACRecordingWriting {}

final class StreamingAACArchive: @unchecked Sendable {
    typealias WriterFactory = (URL) throws -> any AACRecordingWriting

    private enum State {
        case writing(any AACRecordingWriting)
        case failed(Error)
        case finalized(URL)
        case cancelled
    }

    private let lock = NSLock()
    private var state: State

    init(
        url: URL,
        writerFactory: WriterFactory = { try AACRecordingWriter(url: $0) }
    ) {
        do {
            state = .writing(try writerFactory(url))
        } catch {
            state = .failed(error)
        }
    }

    var failure: Error? {
        lock.lock()
        defer { lock.unlock() }
        guard case .failed(let error) = state else { return nil }
        return error
    }

    func write(_ samples: [Float]) -> Error? {
        lock.lock()
        defer { lock.unlock() }
        guard case .writing(let writer) = state else { return nil }
        do {
            try writer.writeChunk(samples)
            return nil
        } catch {
            writer.cancel()
            state = .failed(error)
            return error
        }
    }

    func finalize() -> Result<URL, Error> {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .writing(let writer):
            do {
                let url = try writer.finalize()
                state = .finalized(url)
                return .success(url)
            } catch {
                writer.cancel()
                state = .failed(error)
                return .failure(error)
            }
        case .failed(let error):
            return .failure(error)
        case .finalized(let url):
            return .success(url)
        case .cancelled:
            return .failure(AACRecordingWriterError.finalized)
        }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        if case .writing(let writer) = state {
            writer.cancel()
        }
        state = .cancelled
    }
}
