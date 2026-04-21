// StreamingAudioService.swift
// OpenSuperMLX

import AppKit
@preconcurrency import AVFoundation
import Foundation
import os.log

import MLX
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

    private var feedTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var recordingStartTime: Date?
    private var microphoneChangeObserver: NSObjectProtocol?
    private var microphoneDisconnectObserver: NSObjectProtocol?

    /// Thread-safe ring buffer: tap callback appends on CoreAudio thread, polling loop drains on Task.
    private let ringBuffer = OSAllocatedUnfairLock(initialState: [Float]())

    private let shouldStopFeeding = OSAllocatedUnfairLock(initialState: false)

    private var isEngineWarmed = false
    private var hasBeenWarmedOnce = false

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
                } else if self.hasBeenWarmedOnce {
                    self.warmUp()
                }
            }
        }

        microphoneDisconnectObserver = NotificationCenter.default.addObserver(
            forName: .microphoneDisconnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.isStreaming {
                    logger.info("Active microphone disconnected during streaming — deferring to IndicatorViewModel")
                } else if self.isEngineWarmed {
                    logger.info("Active microphone disconnected — stopping engine (no fallback)")
                    self.coolDown()
                }
            }
        }
    }

    // MARK: - Engine Pre-Warm

    func warmUp() {
        guard !isEngineWarmed, audioEngine == nil else { return }

        let engine = AVAudioEngine()

        let activeMic = MicrophoneService.shared.activateForRecording()

        let inputNode = engine.inputNode
        let isVirtual = activeMic.map { MicrophoneService.shared.isVirtualDevice($0) } ?? false

        if !isVirtual {
            // VPIO reads kAudioHardwarePropertyDefaultInputDevice at aggregate creation time.
            // Temporarily set system default to our target device so VPIO's aggregate includes it.
            var savedDefaultInput: AudioDeviceID?
            if let activeMic,
               let coreAudioID = MicrophoneService.shared.getCoreAudioDeviceID(for: activeMic) {
                let current = getSystemDefaultInputDevice()
                if current != coreAudioID {
                    savedDefaultInput = current
                    setSystemDefaultInputDevice(coreAudioID)
                    usleep(50_000)
                }
            }

            do {
                try inputNode.setVoiceProcessingEnabled(true)

                var duckingConfig = AUVoiceIOOtherAudioDuckingConfiguration(
                    mEnableAdvancedDucking: DarwinBoolean(false),
                    mDuckingLevel: .min
                )
                let duckStatus = AudioUnitSetProperty(
                    inputNode.audioUnit!,
                    kAUVoiceIOProperty_OtherAudioDuckingConfiguration,
                    kAudioUnitScope_Global,
                    0,
                    &duckingConfig,
                    UInt32(MemoryLayout<AUVoiceIOOtherAudioDuckingConfiguration>.size)
                )
                if duckStatus != noErr {
                    logger.warning("Warm-up: failed to disable VPIO ducking (status \(duckStatus, privacy: .public))")
                }

                var disableAGC: UInt32 = 0
                let agcStatus = AudioUnitSetProperty(
                    inputNode.audioUnit!,
                    kAUVoiceIOProperty_VoiceProcessingEnableAGC,
                    kAudioUnitScope_Global,
                    1,
                    &disableAGC,
                    UInt32(MemoryLayout<UInt32>.size)
                )
                if agcStatus != noErr {
                    logger.warning("Warm-up: failed to disable VPIO AGC (status \(agcStatus, privacy: .public))")
                }

                logger.info("Warm-up: VoiceProcessingIO enabled for \(activeMic?.displayName ?? "default", privacy: .public)")
            } catch {
                logger.warning("Warm-up: VoiceProcessingIO not available: \(error, privacy: .public)")
            }

            if let savedDefaultInput {
                setSystemDefaultInputDevice(savedDefaultInput)
            }
        } else {
            if let activeMic,
               let coreAudioID = MicrophoneService.shared.getCoreAudioDeviceID(for: activeMic) {
                var deviceID = coreAudioID
                AudioUnitSetProperty(
                    inputNode.audioUnit!,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global, 0,
                    &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)
                )
            }
            logger.info("Warm-up: VoiceProcessingIO skipped for virtual device \(activeMic?.displayName ?? "unknown", privacy: .public)")
        }

        let nativeFormat = inputNode.outputFormat(forBus: 0)
        self.nativeSampleRate = nativeFormat.sampleRate

        let ringBufferLock = self.ringBuffer

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) {
            [weak self] buffer, _ in
            guard self?.isStreaming ?? false else { return }
            let floats = Array(UnsafeBufferPointer(
                start: buffer.floatChannelData![0],
                count: Int(buffer.frameLength)
            ))
            ringBufferLock.withLock { buf in
                buf.append(contentsOf: floats)
            }
        }

        do {
            try engine.start()
            audioEngine = engine
            isEngineWarmed = true
            hasBeenWarmedOnce = true
            logger.info("Audio engine warmed up")
        } catch {
            logger.error("Warm-up failed: \(error, privacy: .public)")
        }
    }

    private func getSystemDefaultInputDevice() -> AudioDeviceID {
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return deviceID
    }

    private func setSystemDefaultInputDevice(_ deviceID: AudioDeviceID) {
        var mutableID = deviceID
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &mutableID
        )
        if status != noErr {
            logger.warning("Failed to set system default input device (status \(status, privacy: .public))")
        }
    }

    private var retiredEngines: [AVAudioEngine] = []

    func coolDown() {
        guard isEngineWarmed else { return }
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        retireEngine(audioEngine)
        audioEngine = nil
        isEngineWarmed = false
        ringBuffer.withLock { $0.removeAll() }
        logger.info("Audio engine cooled down")
    }

    private func retireEngine(_ engine: AVAudioEngine?) {
        guard let engine else { return }
        retiredEngines.append(engine)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.retiredEngines.removeAll { $0 === engine }
        }
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
        retireEngine(engine)
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
        PipelineTrace.shared.log("STREAM", "startStreaming() called")

        guard !isStreaming else {
            PipelineTrace.shared.log("STREAM", "already streaming, skipped")
            logger.warning("Already streaming, ignoring startStreaming()")
            return
        }

        guard let model = TranscriptionService.shared.streamingModel else {
            PipelineTrace.shared.log("STREAM", "no model available")
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
        logger.info("Streaming started (engine pre-warmed)")

        let speakerEnabled = MicrophoneService.shared.speakerCaptureEnabled
        speakerCaptureActiveForSession = speakerEnabled
        let mixer = AudioMixer(inputSampleRate: nativeSampleRate)
        self.audioMixer = mixer
        let systemCaptureRate: Double = 48000

        PipelineTrace.shared.log("STREAM", "streaming started speakerEnabled=\(speakerEnabled) sampleRate=\(nativeSampleRate)")

        if speakerEnabled {
            if AppPreferences.shared.debugMode {
                let traceURL = tempDir.appendingPathComponent("\(timestamp)_mix_trace.log")
                mixer.startTrace(url: traceURL)
            }
            Task {
                do {
                    try await SystemAudioService.shared.startCapture(sampleRate: systemCaptureRate)
                    PipelineTrace.shared.log("STREAM", "speaker capture started")
                    logger.info("Speaker capture started")
                } catch {
                    PipelineTrace.shared.log("STREAM", "speaker capture FAILED: \(error)")
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
                    samples16k = mixer.mix(mic: micSamples, micSampleRate: sampleRate, sys: sysSamples, sysSampleRate: systemCaptureRate)
                    PipelineTrace.shared.log("FEED", "mic=\(micSamples.count) sys=\(sysSamples.count) out=\(samples16k.count)")
                } else if !micSamples.isEmpty {
                    samples16k = mixer.micOnly(micSamples, inputSampleRate: sampleRate)
                    PipelineTrace.shared.log("FEED", "micOnly=\(micSamples.count) out=\(samples16k.count)")
                } else {
                    samples16k = []
                }

                if !samples16k.isEmpty {
                    session.feedAudio(samples: samples16k)
                    do {
                        try writer.writeChunk(samples16k)
                        PipelineTrace.shared.log("WAV", "wrote \(samples16k.count) samples")
                    } catch {
                        PipelineTrace.shared.log("WAV", "write FAILED: \(error)")
                        logger.error("Failed to write WAV chunk: \(error, privacy: .public)")
                    }
                }

                let speechActive = session.isSpeechActive
                Task { @MainActor [weak self] in
                    self?.isSpeechDetected = speechActive
                }

                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    // MARK: - Stop Streaming

    func stopStreaming() async -> (text: String, url: URL)? {
        PipelineTrace.shared.log("STREAM", "stopStreaming() called")
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
        audioMixer?.stopTrace()
        PipelineTrace.shared.log("STREAM", "feed loop stopped")

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
        PipelineTrace.shared.stop()
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
        PipelineTrace.shared.stop()

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

    // MARK: - File Injection (CLI stream-simulate)

    struct FileInjectionResult {
        let text: String
        let chunksFed: Int
        let intermediateUpdates: Int
        let audioDurationS: Double
    }

    var ringBufferSampleCount: Int {
        ringBuffer.withLock { $0.count }
    }

    var isAudioEngineInitialized: Bool {
        audioEngine != nil
    }

    func clearRingBuffer() {
        ringBuffer.withLock { $0.removeAll() }
    }

    func writeRawSamplesToRingBuffer(_ samples: [Float], chunkDuration: Double) -> Int {
        let chunkSize = max(1, Int(chunkDuration * 16000))
        var offset = 0
        var chunksFed = 0
        while offset < samples.count {
            let end = min(offset + chunkSize, samples.count)
            ringBuffer.withLock { $0.append(contentsOf: Array(samples[offset..<end])) }
            offset = end
            chunksFed += 1
        }
        ringBuffer.withLock { $0.append(contentsOf: [Float](repeating: 0, count: 10560)) }
        return chunksFed
    }

    func injectAudioFromFile(
        url: URL,
        language: String = "auto",
        temperature: Float = 0.0,
        chunkDuration: Double = 0.5,
        onEvent: @escaping @Sendable (TranscriptionEvent) -> Void
    ) async throws -> FileInjectionResult {
        guard let model = TranscriptionService.shared.streamingModel else {
            throw StreamingAudioError.modelNotLoaded
        }

        let (_, audio) = try loadAudioArray(from: url, sampleRate: 16000)
        let samples = audio.asArray(Float.self)
        let audioDurationS = Double(samples.count) / 16000.0

        let mappedLanguage = Self.mapLanguageCode(language)
        let config = StreamingConfig(language: mappedLanguage, temperature: temperature)
        let session = StreamingInferenceSession(model: model, config: config)

        shouldStopFeeding.withLock { $0 = false }

        let intermediateCount = OSAllocatedUnfairLock(initialState: 0)
        let collectedFinalText = OSAllocatedUnfairLock(initialState: "")
        let collectedConfirmedText = OSAllocatedUnfairLock(initialState: "")

        let eventTask = Task.detached {
            for await event in session.events {
                onEvent(event)
                switch event {
                case .displayUpdate(let confirmed, _):
                    intermediateCount.withLock { $0 += 1 }
                    collectedConfirmedText.withLock { $0 = confirmed }
                case .ended(let text):
                    collectedFinalText.withLock { $0 = text }
                default:
                    break
                }
            }
        }

        let chunksFed = writeRawSamplesToRingBuffer(samples, chunkDuration: chunkDuration)

        let ringBufferRef = self.ringBuffer
        let localFeedTask = Task.detached {
            while true {
                let drained = ringBufferRef.withLock { buffer -> [Float] in
                    guard !buffer.isEmpty else { return [] }
                    let d = buffer
                    buffer.removeAll(keepingCapacity: true)
                    return d
                }

                if drained.isEmpty {
                    break
                }

                session.feedAudio(samples: drained)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        await localFeedTask.value
        session.stop()

        let completed = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await eventTask.value; return true }
            group.addTask {
                try? await Task.sleep(for: .seconds(60))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }

        ringBuffer.withLock { $0.removeAll() }

        guard completed else {
            throw StreamingAudioError.streamTimeout
        }

        let finalText = collectedFinalText.withLock { $0 }
        let confirmedFallback = collectedConfirmedText.withLock { $0 }
        let resultText = finalText.isEmpty ? confirmedFallback : finalText

        return FileInjectionResult(
            text: resultText,
            chunksFed: chunksFed,
            intermediateUpdates: intermediateCount.withLock { $0 },
            audioDurationS: audioDurationS
        )
    }
}

// MARK: - Errors

enum StreamingAudioError: LocalizedError {
    case modelNotLoaded
    case audioFormatCreationFailed
    case streamTimeout

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "No transcription model loaded. Please wait for the model to finish loading."
        case .audioFormatCreationFailed:
            return "Failed to create the target audio format for streaming."
        case .streamTimeout:
            return "Stream simulation timed out waiting for completion."
        }
    }
}
