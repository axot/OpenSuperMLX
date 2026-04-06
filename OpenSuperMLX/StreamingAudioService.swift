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

    // MARK: - Private State

    private var audioEngine: AVAudioEngine?
    private var audioMixer: AudioMixer?
    private var nativeSampleRate: Double = 44100
    private var speakerCaptureActiveForSession = false
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

    private let preBufferCapacity = 22050
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
                    self.hotSwapMicrophone()
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

        let engine = AVAudioEngine()

        let activeMic = MicrophoneService.shared.activateForRecording()

        if let activeMic,
           let coreAudioID = MicrophoneService.shared.getCoreAudioDeviceID(for: activeMic) {
            var deviceID = coreAudioID
            let status = AudioUnitSetProperty(
                engine.inputNode.audioUnit!,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0,
                &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if status == noErr {
                logger.info("Warm-up: bound input to \(activeMic.displayName, privacy: .public)")
            } else {
                logger.error("Warm-up: failed to bind input device (status \(status, privacy: .public))")
            }
        }

        let inputNode = engine.inputNode

        let isVirtual = activeMic.map { MicrophoneService.shared.isVirtualDevice($0) } ?? false
        if !isVirtual {
            do {
                try inputNode.setVoiceProcessingEnabled(true)
                logger.info("Warm-up: VoiceProcessingIO enabled for \(activeMic?.displayName ?? "default", privacy: .public)")
            } catch {
                logger.warning("Warm-up: VoiceProcessingIO not available: \(error, privacy: .public)")
            }
        } else {
            logger.info("Warm-up: VoiceProcessingIO skipped for virtual device \(activeMic?.displayName ?? "unknown", privacy: .public)")
        }

        let nativeFormat = inputNode.outputFormat(forBus: 0)
        self.nativeSampleRate = nativeFormat.sampleRate

        let ringBufferLock = self.ringBuffer
        let preCapacity = self.preBufferCapacity

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) {
            [weak self] buffer, _ in
            let floats = Array(UnsafeBufferPointer(
                start: buffer.floatChannelData![0],
                count: Int(buffer.frameLength)
            ))
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
        isEngineWarmed = false
        ringBuffer.withLock { $0.removeAll() }
        logger.info("Audio engine cooled down")
    }

    // MARK: - Mic Hot-Swap

    private func hotSwapMicrophone() {
        guard let engine = audioEngine else { return }

        let preserved = ringBuffer.withLock { buffer -> [Float] in
            let saved = buffer
            buffer.removeAll(keepingCapacity: true)
            return saved
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioEngine = nil
        isEngineWarmed = false

        warmUp()

        if !isEngineWarmed {
            logger.error("Hot-swap failed: audio engine did not start with new device")
        }

        ringBuffer.withLock { buffer in
            buffer.insert(contentsOf: preserved, at: 0)
        }

        logger.info("Hot-swapped microphone, preserved \(preserved.count) samples")
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

        let speakerEnabled = MicrophoneService.shared.speakerCaptureEnabled
        speakerCaptureActiveForSession = speakerEnabled
        let mixer = AudioMixer(inputSampleRate: nativeSampleRate)
        self.audioMixer = mixer

        if speakerEnabled {
            Task {
                do {
                    try await SystemAudioService.shared.startCapture()
                    logger.info("Speaker capture started")
                } catch {
                    logger.warning("Speaker capture failed: \(error, privacy: .public)")
                }
            }
        }

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
        let sampleRate = self.nativeSampleRate
        feedTask = Task.detached {
            while !shouldStopRef.withLock({ $0 }) {
                let micSamples = ringBufferRef.withLock { buffer -> [Float] in
                    guard !buffer.isEmpty else { return [] }
                    let drained = buffer
                    buffer.removeAll(keepingCapacity: true)
                    return drained
                }

                let samples16k: [Float]
                if speakerEnabled {
                    let sysSamples = await SystemAudioService.shared.drainAccumulatedSamples()
                    samples16k = mixer.mix(mic: micSamples, sys: sysSamples, inputSampleRate: sampleRate)
                } else if !micSamples.isEmpty {
                    samples16k = mixer.micOnly(micSamples, inputSampleRate: sampleRate)
                } else {
                    samples16k = []
                }

                if !samples16k.isEmpty {
                    session.feedAudio(samples: samples16k)
                    do {
                        try writer.writeChunk(samples16k)
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
        }

        shouldStopFeeding.withLock { $0 = true }
        if let feedTask {
            _ = await feedTask.value
        }
        feedTask = nil

        if speakerCaptureActiveForSession {
            _ = await SystemAudioService.shared.stopCapture()
        }

        let remainingSamples = ringBuffer.withLock { buffer -> [Float] in
            let drained = buffer
            buffer.removeAll()
            return drained
        }

        if !remainingSamples.isEmpty, let mixer = audioMixer {
            let remaining16k = mixer.micOnly(remainingSamples, inputSampleRate: nativeSampleRate)
            if let session = streamingSession {
                session.feedAudio(samples: remaining16k)
            }
            if let writer = wavWriter {
                do { try writer.writeChunk(remaining16k) } catch {
                    logger.error("Failed to write final WAV chunk: \(error, privacy: .public)")
                }
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
        audioMixer = nil
        speakerCaptureActiveForSession = false
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

        if speakerCaptureActiveForSession {
            Task { _ = await SystemAudioService.shared.stopCapture() }
        }
        speakerCaptureActiveForSession = false

        wavWriter = nil
        if let url = currentWAVURL {
            try? FileManager.default.removeItem(at: url)
            logger.info("Cancelled streaming, deleted WAV: \(url.lastPathComponent, privacy: .public)")
        }
        currentWAVURL = nil

        ringBuffer.withLock { $0.removeAll() }
        audioMixer = nil

        clearState()
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

        if applyCorrection {
            text = await LLMCorrectionService.shared.correctTranscription(text, forceEnabled: forceLLM)
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
