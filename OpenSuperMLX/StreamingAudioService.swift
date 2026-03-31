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
    @Published private(set) var isSpeechDetected = false
    @Published private(set) var isDualTrackMode = false

    // MARK: - Private State

    private var audioEngine: AVAudioEngine?
    private var audioConverter: AVAudioConverter?
    private var streamingSession: StreamingInferenceSession?
    private var wavWriter: StreamingWAVWriter?
    private var currentWAVURL: URL?
    private var currentSystemAudioURL: URL?

    private var feedTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var recordingStartTime: Date?
    private var microphoneChangeObserver: NSObjectProtocol?

    /// Thread-safe ring buffer: tap callback appends on CoreAudio thread, polling loop drains on Task.
    private let ringBuffer = OSAllocatedUnfairLock(initialState: [Float]())

    private let shouldStopFeeding = OSAllocatedUnfairLock(initialState: false)

    /// When not recording, cap ring buffer at 500ms (8000 samples at 16kHz) as pre-buffer.
    private let preBufferCapacity = 8000
    private var isEngineWarmed = false

    // MARK: - Init

    private init() {
        microphoneChangeObserver = NotificationCenter.default.addObserver(
            forName: .microphoneDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.isStreaming {
                    self.cancelStreaming()
                    logger.info("Streaming cancelled due to microphone change")
                } else if self.isEngineWarmed {
                    self.coolDown()
                    self.warmUp()
                }
            }
        }
    }

    // MARK: - Engine Pre-Warm

    func warmUp() {
        guard !isEngineWarmed, audioEngine == nil else { return }

        if let activeMic = MicrophoneService.shared.activateForRecording() {
            logger.info("Warm-up: set input to \(activeMic.displayName, privacy: .public)")
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
            logger.error("Warm-up: failed to create target format")
            return
        }

        let converter: AVAudioConverter?
        if nativeFormat.sampleRate != targetSampleRate || nativeFormat.channelCount != 1 {
            converter = AVAudioConverter(from: nativeFormat, to: targetFormat)
        } else {
            converter = nil
        }
        audioConverter = converter

        let nativeSampleRate = nativeFormat.sampleRate
        let ringBufferLock = self.ringBuffer
        let preCapacity = self.preBufferCapacity

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) {
            [weak self] buffer, _ in

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

            ringBufferLock.withLock { buf in
                buf.append(contentsOf: floats)
                let isCurrentlyStreaming = self?.isStreaming ?? false
                if !isCurrentlyStreaming && buf.count > preCapacity {
                    buf.removeFirst(buf.count - preCapacity)
                }
            }
        }

        do {
            try engine.start()
            audioEngine = engine
            isEngineWarmed = true
            logger.info("Audio engine warmed up")
        } catch {
            logger.error("Warm-up failed: \(error, privacy: .public)")
        }
    }

    func coolDown() {
        guard isEngineWarmed else { return }
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioConverter = nil
        isEngineWarmed = false
        ringBuffer.withLock { $0.removeAll() }
        logger.info("Audio engine cooled down")
    }

    // MARK: - Start Streaming

    func startStreaming() throws {
        guard !isStreaming else {
            logger.warning("Already streaming, ignoring startStreaming()")
            return
        }

        guard let model = TranscriptionService.shared.streamingModel else {
            logger.error("No model available for streaming")
            throw StreamingAudioError.modelNotLoaded
        }

        if !isEngineWarmed {
            warmUp()
        }

        guard audioEngine != nil else {
            throw StreamingAudioError.audioFormatCreationFailed
        }

        shouldStopFeeding.withLock { $0 = false }
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
            language: language,
            temperature: Float(settings.temperature)
        )
        let session = StreamingInferenceSession(model: model, config: config)
        streamingSession = session
        if AppPreferences.shared.debugMode {
            logger.debug("[DEBUG] Streaming config: language=\(language, privacy: .public), temperature=\(settings.temperature, privacy: .public)")
        }

        isStreaming = true
        recordingStartTime = Date()
        playNotificationSound()
        logger.info("Streaming started (engine pre-warmed, pre-buffer available)")

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
        let shouldStopRef = self.shouldStopFeeding
        feedTask = Task.detached {
            while !shouldStopRef.withLock({ $0 }) {
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
                        logger.error("Failed to write WAV chunk: \(error, privacy: .public)")
                    }
                }

                let speechActive = session.isSpeechActive
                await MainActor.run { [weak self] in
                    self?.isSpeechDetected = speechActive
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

        defer {
            isStreaming = false
            isDualTrackMode = false
        }

        shouldStopFeeding.withLock { $0 = true }
        if let feedTask {
            _ = await feedTask.value
        }
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
                logger.error("Failed to write final WAV chunk: \(error, privacy: .public)")
            }
        }

        if let session = streamingSession {
            session.stop()

            if let eventTask {
                _ = await eventTask.value
            }
        }
        eventTask = nil

        let finalURL = wavWriter?.finalize()
        wavWriter = nil

        if let startTime = recordingStartTime {
            let duration = Date().timeIntervalSince(startTime)
            if duration < 1.0 {
                logger.info("Recording too short (\(String(format: "%.1f", duration), privacy: .public)s), discarding")
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

        logger.info("Streaming stopped, WAV at: \(url?.lastPathComponent ?? "nil", privacy: .public)")
        ringBuffer.withLock { $0.removeAll() }
        guard let url else { return nil }
        return (text: finalText, url: url)
    }

    // MARK: - Cancel Streaming

    func cancelStreaming() {
        guard isStreaming else { return }

        isStreaming = false
        isDualTrackMode = false

        feedTask?.cancel()
        feedTask = nil
        eventTask?.cancel()
        eventTask = nil

        streamingSession?.cancel()
        streamingSession = nil

        wavWriter = nil
        if let url = currentWAVURL {
            try? FileManager.default.removeItem(at: url)
            logger.info("Cancelled streaming, deleted WAV: \(url.lastPathComponent, privacy: .public)")
        }
        currentWAVURL = nil

        ringBuffer.withLock { $0.removeAll() }

        clearState()
    }

    // MARK: - Dual-Track Capture

    func startDualTrackCapture(bundleID: String?) async throws {
        do {
            try await SystemAudioService.shared.startCapture(bundleID: bundleID)
        } catch {
            logger.warning("System audio capture failed, falling back to mic-only: \(error, privacy: .public)")
        }

        try startStreaming()
        isDualTrackMode = true
    }

    func stopDualTrackCapture() async -> (micAudioURL: URL?, systemAudioURL: URL?) {
        let systemURL = await SystemAudioService.shared.stopCapture()
        currentSystemAudioURL = systemURL

        let micResult = await stopStreaming()
        isDualTrackMode = false

        return (micAudioURL: micResult?.url, systemAudioURL: systemURL)
    }

    // MARK: - Finalize Recording

    struct StreamingResult {
        let text: String
        let recording: Recording
    }

    func finalizeRecording(duration: TimeInterval = 0, applyCorrection: Bool = true, forceLLM: Bool = false) async -> StreamingResult? {
        guard let result = await stopStreaming() else { return nil }

        var text = result.text
        let settings = Settings()
        if !text.isEmpty && (settings.shouldApplyChineseITN || settings.shouldApplyEnglishITN || settings.shouldApplyAsianAutocorrect) {
            let applyITN = settings.shouldApplyChineseITN
            let applyEnglishITN = settings.shouldApplyEnglishITN
            let applyAutocorrect = settings.shouldApplyAsianAutocorrect
            text = await Task.detached(priority: .userInitiated) {
                var t = text
                if applyITN {
                    t = ITNProcessor.process(t)
                }
                if applyEnglishITN {
                    t = NemoTextProcessing.normalizeSentence(t)
                }
                if applyAutocorrect {
                    t = AutocorrectWrapper.format(t)
                }
                return t
            }.value
        }

        // Apply Bedrock LLM correction (conditional — caller controls this for indicator state)
        if applyCorrection {
            text = await BedrockService.shared.correctTranscription(text, forceEnabled: forceLLM)
        }

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
            logger.error("Error moving recording: \(error, privacy: .public)")
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
            if AppPreferences.shared.debugMode {
                logger.debug(
                    "Stats: \(stats.tokensPerSecond, format: .fixed(precision: 1), privacy: .public) tok/s, \(stats.totalAudioSeconds, format: .fixed(precision: 1), privacy: .public)s audio, \(stats.peakMemoryGB, format: .fixed(precision: 2), privacy: .public) GB"
                )
            }

        case .ended(let fullText):
            let cleaned = RepetitionCleaner.clean(fullText)
            confirmedText = cleaned
            provisionalText = ""
            logger.info("Streaming ended, full text length: \(fullText.count, privacy: .public) → cleaned: \(cleaned.count, privacy: .public)")
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
        isSpeechDetected = false
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
