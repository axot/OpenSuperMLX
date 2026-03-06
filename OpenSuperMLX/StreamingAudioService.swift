// StreamingAudioService.swift
// OpenSuperMLX

import AppKit
@preconcurrency import AVFoundation
import Foundation
import os.log

import MLXAudioCore
import MLXAudioSTT

private let logger = Logger(subsystem: "OpenSuperMLX", category: "StreamingAudioService")

// MARK: - StreamingAudioService

@MainActor
class StreamingAudioService: ObservableObject {
    static let shared = StreamingAudioService()

    // MARK: - Published State

    @Published private(set) var confirmedText = ""
    @Published private(set) var provisionalText = ""
    @Published private(set) var isStreaming = false

    // MARK: - Private State

    private var audioEngine: AVAudioEngine?
    private var audioConverter: AVAudioConverter?
    private var streamingSession: StreamingInferenceSession?
    private var wavWriter: StreamingWAVWriter?
    private var currentWAVURL: URL?

    private var feedTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var recordingStartTime: Date?
    private var microphoneChangeObserver: NSObjectProtocol?

    /// Thread-safe ring buffer: tap callback appends on CoreAudio thread, polling loop drains on Task.
    private let ringBuffer = OSAllocatedUnfairLock(initialState: [Float]())

    // MARK: - Init

    private init() {
        microphoneChangeObserver = NotificationCenter.default.addObserver(
            forName: .microphoneDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isStreaming else { return }
                self.cancelStreaming()
                logger.info("Streaming cancelled due to microphone change")
            }
        }
    }

    // MARK: - Start Streaming

    func startStreaming() async throws {
        guard !isStreaming else {
            logger.warning("Already streaming, ignoring startStreaming()")
            return
        }

        guard let model = TranscriptionService.shared.streamingModel else {
            logger.error("No model available for streaming")
            throw StreamingAudioError.modelNotLoaded
        }

        confirmedText = ""
        provisionalText = ""

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("temp_recordings")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let timestamp = Int(Date().timeIntervalSince1970)
        let wavURL = tempDir.appendingPathComponent("\(timestamp)_streaming.wav")
        currentWAVURL = wavURL
        let writer = try StreamingWAVWriter(url: wavURL, sampleRate: 16000)
        wavWriter = writer

        let settings = Settings()
        let language = Self.mapLanguageCode(settings.selectedLanguage)
        let config = StreamingConfig(
            decodeIntervalSeconds: 1.0,
            delayPreset: .subtitle,
            language: language,
            temperature: Float(settings.temperature),
            finalizeCompletedWindows: true
        )
        let session = StreamingInferenceSession(model: model, config: config)
        streamingSession = session

        if let activeMic = MicrophoneService.shared.getActiveMicrophone() {
            _ = MicrophoneService.shared.setAsSystemDefaultInput(activeMic)
            logger.info("Set system default input to: \(activeMic.displayName)")
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)

        let targetSampleRate: Double = 16000
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw StreamingAudioError.audioFormatCreationFailed
        }

        let converter: AVAudioConverter?
        if nativeFormat.sampleRate != targetSampleRate || nativeFormat.channelCount != 1 {
            converter = AVAudioConverter(from: nativeFormat, to: targetFormat)
            logger.info("Audio converter: \(nativeFormat.sampleRate)Hz/\(nativeFormat.channelCount)ch → 16kHz/1ch")
        } else {
            converter = nil
            logger.info("Native format already 16kHz mono")
        }
        audioConverter = converter

        let nativeSampleRate = nativeFormat.sampleRate
        let ringBufferLock = self.ringBuffer

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) {
            buffer, _ in

            let floats: [Float]
            if let converter {
                let frameCapacity = AVAudioFrameCount(
                    Double(buffer.frameLength) * targetSampleRate / nativeSampleRate
                )
                guard let converted = AVAudioPCMBuffer(
                    pcmFormat: targetFormat, frameCapacity: frameCapacity
                ) else { return }

                var error: NSError?
                var consumed = false
                converter.convert(to: converted, error: &error) { _, outStatus in
                    if consumed {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    consumed = true
                    outStatus.pointee = .haveData
                    return buffer
                }
                if error != nil { return }

                floats = Array(UnsafeBufferPointer(
                    start: converted.floatChannelData![0],
                    count: Int(converted.frameLength)
                ))
            } else {
                floats = Array(UnsafeBufferPointer(
                    start: buffer.floatChannelData![0],
                    count: Int(buffer.frameLength)
                ))
            }

            ringBufferLock.withLock { buffer in
                buffer.append(contentsOf: floats)
            }
        }

        playNotificationSound()
        try await Task.sleep(for: .milliseconds(300))

        try engine.start()
        audioEngine = engine
        isStreaming = true
        recordingStartTime = Date()
        logger.info("Streaming started")

        eventTask = Task.detached { [weak self] in
            for await event in session.events {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.handleTranscriptionEvent(event)
                }
            }
            await MainActor.run { [weak self] in
                self?.streamingSession = nil
            }
        }

        let ringBufferRef = self.ringBuffer
        feedTask = Task.detached {
            while !Task.isCancelled {
                let samples = ringBufferRef.withLock { buffer -> [Float] in
                    guard !buffer.isEmpty else { return [] }
                    let drained = buffer
                    buffer.removeAll(keepingCapacity: true)
                    return drained
                }

                if !samples.isEmpty {
                    session.feedAudio(samples: samples)

                    do {
                        try writer.writeChunk(samples)
                    } catch {
                        logger.error("Failed to write WAV chunk: \(error)")
                    }
                }

                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    // MARK: - Stop Streaming

    func stopStreaming() async -> (text: String, url: URL)? {
        guard isStreaming else {
            logger.warning("Not streaming, ignoring stopStreaming()")
            return nil
        }

        isStreaming = false

        feedTask?.cancel()
        feedTask = nil

        let remainingSamples = ringBuffer.withLock { buffer -> [Float] in
            let drained = buffer
            buffer.removeAll()
            return drained
        }

        if let session = streamingSession, !remainingSamples.isEmpty {
            session.feedAudio(samples: remainingSamples)
        }

        if !remainingSamples.isEmpty, let writer = wavWriter {
            do {
                try writer.writeChunk(remainingSamples)
            } catch {
                logger.error("Failed to write final WAV chunk: \(error)")
            }
        }

        if let session = streamingSession {
            session.stop()

            if let eventTask {
                _ = await eventTask.value
            }
        }
        eventTask = nil

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioConverter = nil

        let finalURL = wavWriter?.finalize()
        wavWriter = nil

        if let startTime = recordingStartTime {
            let duration = Date().timeIntervalSince(startTime)
            if duration < 1.0 {
                logger.info("Recording too short (\(String(format: "%.1f", duration))s), discarding")
                if let url = finalURL {
                    try? FileManager.default.removeItem(at: url)
                }
                clearState()
                return nil
            }
        }

        let finalText = confirmedText
        confirmedText = ""
        provisionalText = ""
        streamingSession = nil
        recordingStartTime = nil
        let url = finalURL ?? currentWAVURL
        currentWAVURL = nil

        logger.info("Streaming stopped, WAV at: \(url?.lastPathComponent ?? "nil")")
        guard let url else { return nil }
        return (text: finalText, url: url)
    }

    // MARK: - Cancel Streaming

    func cancelStreaming() {
        guard isStreaming else { return }

        isStreaming = false

        feedTask?.cancel()
        feedTask = nil
        eventTask?.cancel()
        eventTask = nil

        streamingSession?.cancel()
        streamingSession = nil

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioConverter = nil

        wavWriter = nil
        if let url = currentWAVURL {
            try? FileManager.default.removeItem(at: url)
            logger.info("Cancelled streaming, deleted WAV: \(url.lastPathComponent)")
        }
        currentWAVURL = nil

        ringBuffer.withLock { $0.removeAll() }

        clearState()
    }

    // MARK: - Finalize Recording

    struct StreamingResult {
        let text: String
        let recording: Recording
    }

    func finalizeRecording(duration: TimeInterval = 0) async -> StreamingResult? {
        guard let result = await stopStreaming() else { return nil }

        var text = result.text
        if Settings().shouldApplyAsianAutocorrect && !text.isEmpty {
            text = AutocorrectWrapper.format(text)
        }

        // Apply Bedrock LLM correction (mirrors TranscriptionService line 142)
        text = await BedrockService.shared.correctTranscription(text)

        let timestamp = Date()
        let fileName = "\(Int(timestamp.timeIntervalSince1970)).wav"
        let recording = Recording(
            id: UUID(), timestamp: timestamp, fileName: fileName,
            transcription: text, duration: duration,
            status: .completed, progress: 1.0, sourceFileURL: nil
        )

        do {
            try AudioRecorder.shared.moveTemporaryRecording(from: result.url, to: recording.url)
        } catch {
            print("Error moving recording: \(error)")
        }

        return StreamingResult(text: text, recording: recording)
    }

    // MARK: - Event Handling

    private func handleTranscriptionEvent(_ event: TranscriptionEvent) {
        switch event {
        case .provisional(let text):
            provisionalText = text

        case .confirmed(let text):
            confirmedText = text

        case .displayUpdate(let confirmed, let provisional):
            confirmedText = confirmed
            provisionalText = provisional

        case .stats(let stats):
            logger.debug(
                "Stats: \(stats.tokensPerSecond, format: .fixed(precision: 1)) tok/s, \(stats.totalAudioSeconds, format: .fixed(precision: 1))s audio, \(stats.peakMemoryGB, format: .fixed(precision: 2)) GB"
            )

        case .ended(let fullText):
            confirmedText = fullText
            provisionalText = ""
            logger.info("Streaming ended, full text length: \(fullText.count)")
        }
    }

    // MARK: - Private Helpers

    private func playNotificationSound() {
        guard AppPreferences.shared.playSoundOnRecordStart else { return }
        guard let soundURL = Bundle.main.url(forResource: "notification", withExtension: "mp3") else {
            NSSound.beep()
            return
        }
        if let sound = NSSound(contentsOf: soundURL, byReference: false) {
            sound.volume = 0.3
            sound.play()
        } else {
            NSSound.beep()
        }
    }

    private func clearState() {
        confirmedText = ""
        provisionalText = ""
        recordingStartTime = nil
    }

    // MARK: - Language Mapping

    private static let supplementalLanguageNames: [String: String] = [
        "cs": "Czech",
        "hu": "Hungarian",
        "da": "Danish",
        "el": "Greek",
        "hr": "Croatian",
        "sk": "Slovak",
        "uk": "Ukrainian",
    ]

    private static func mapLanguageCode(_ code: String) -> String {
        if code == "auto" {
            return "auto"
        }
        return LanguageUtil.languageNames[code]
            ?? supplementalLanguageNames[code]
            ?? code
    }
}

// MARK: - Errors

enum StreamingAudioError: LocalizedError {
    case modelNotLoaded
    case audioFormatCreationFailed

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "No transcription model loaded. Please wait for the model to finish loading."
        case .audioFormatCreationFailed:
            return "Failed to create the target audio format for streaming."
        }
    }
}
