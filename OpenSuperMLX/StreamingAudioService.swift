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
    private var configChangeObserver: NSObjectProtocol?
    private var outputChangeObserver: NSObjectProtocol?
    private var configDebounceTask: Task<Void, Never>?
    private var outputDebounceTask: Task<Void, Never>?

    /// Thread-safe ring buffer: tap callback appends on CoreAudio thread, polling loop drains on Task.
    private let ringBuffer = OSAllocatedUnfairLock(initialState: [Float]())

    private let shouldStopFeeding = OSAllocatedUnfairLock(initialState: false)

    /// Read by the detached feedTask each iteration — so a mid-stream classification flip
    /// (popover chip on the current device) immediately changes whether sys samples are
    /// drained and mixed. Mirrors the `shouldStopFeeding` lock pattern.
    private let speakerCaptureActiveLock = OSAllocatedUnfairLock(initialState: false)

    /// Snapshot of input format + device ID right after the most recent successful
    /// engine.start(). The configChange handler compares the live values to these to
    /// distinguish three cases: (a) no real change (drop notification), (b) format-only
    /// change (re-tap on same engine — does NOT re-trigger configChange), (c) device
    /// change (full hot-swap). This eliminates the self-induced configChange loop
    /// caused by hotSwap → AUHAL property write → configChange → hotSwap …
    private var lastKnownInputFormat: AVAudioFormat?
    private var lastKnownInputDeviceID: AudioDeviceID?

    /// Synchronously gates re-entry into the configChange handler within a single
    /// dispatch — strict scope, no timer. Set true on entry, defer-cleared on exit.
    private var isHandlingConfigChange = false

    private var isEngineWarmed = false
    private var hasBeenWarmedOnce = false
    private var lastWarmUpTime: Date = .distantPast

    /// Output device classifier — testable seam (write at test setUp).
    var classifier: OutputDeviceClassifierProtocol = OutputDeviceClassifier.shared

    /// Classification class (.speaker / .headphone / nil-as-safe) snapshot at the
    /// most recent startStreaming. Used to detect class flips that warrant a tap-restart.
    private var sessionClassification: DeviceClassification?

    // MARK: - Routing decision (pure function, unit-testable)

    /// Pure routing decision based on current output classification + user toggle.
    /// Speaker output (or unclassified, treated as speaker for safety) forces mic-only
    /// to avoid the speaker→mic echo path; only headphones allow mic+sys mixing.
    static func effectiveSpeakerCaptureEnabled(
        classification: DeviceClassification?,
        userToggle: Bool
    ) -> Bool {
        userToggle && classification == .headphone
    }

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
                    self.warmUp(fromBackground: true)
                } else if self.hasBeenWarmedOnce {
                    self.warmUp(fromBackground: true)
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

        outputChangeObserver = NotificationCenter.default.addObserver(
            forName: .outputDeviceDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.outputDebounceTask?.cancel()
                self.outputDebounceTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(200))
                    guard !Task.isCancelled, let self else { return }
                    self.applyClassificationChange()
                }
            }
        }
    }

    // MARK: - Engine Pre-Warm

    func warmUp(fromBackground: Bool = false) {
        guard !isEngineWarmed, audioEngine == nil else { return }
        if fromBackground && Date().timeIntervalSince(lastWarmUpTime) < 1.0 {
            logger.info("Skipping warmUp — last warmUp was < 1s ago")
            return
        }

        let engine = AVAudioEngine()

        let activeMic = MicrophoneService.shared.activateForRecording()

        let inputNode = engine.inputNode

        // VPIO disabled — mic input goes through plain AVAudioEngine.inputNode with no
        // voice-processing pipeline, so other apps reading the same device (QuickTime, Zoom,
        // etc.) see unmodified levels. AEC for speaker-capture echo is now handled at the
        // routing layer via OutputDeviceClassifier (see startStreaming).
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
        logger.info("Warm-up: plain input for \(activeMic?.displayName ?? "default", privacy: .public)")

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
            lastWarmUpTime = Date()
            // Snapshot post-start state so the configChange handler can branch on what
            // actually changed instead of unconditionally hot-swapping (which would
            // self-trigger another configChange via the AUHAL property write below).
            lastKnownInputFormat = nativeFormat
            lastKnownInputDeviceID = MicrophoneService.shared.getCurrentSystemDefaultInputDevice()
            observeEngineConfigChange(engine)
            logger.info("Audio engine warmed up")
        } catch {
            logger.error("Warm-up failed: \(error, privacy: .public)")
        }
    }

    private func observeEngineConfigChange(_ engine: AVAudioEngine) {
        if let old = configChangeObserver {
            NotificationCenter.default.removeObserver(old)
        }
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.configDebounceTask?.cancel()
                self.configDebounceTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(200))
                    guard !Task.isCancelled, let self, self.isStreaming else { return }
                    self.handleConfigChange()
                }
            }
        }
    }

    /// Branches on what actually changed, so the recovery path does not re-trigger the
    /// trigger condition for `.AVAudioEngineConfigurationChange`. This eliminates the
    /// hot-swap feedback loop that bounded `feedAudio` to 500–1300ms.
    private func handleConfigChange() {
        guard !isHandlingConfigChange else {
            logger.info("Skipping nested configChange handler re-entry")
            return
        }
        isHandlingConfigChange = true
        defer { isHandlingConfigChange = false }

        guard let engine = audioEngine else { return }
        let liveFormat = engine.inputNode.outputFormat(forBus: 0)
        let liveDeviceID = MicrophoneService.shared.getCurrentSystemDefaultInputDevice()

        let formatChanged: Bool = {
            guard let cached = lastKnownInputFormat else { return true }
            return cached.sampleRate != liveFormat.sampleRate
                || cached.channelCount != liveFormat.channelCount
        }()
        let deviceChanged = liveDeviceID != lastKnownInputDeviceID

        switch (deviceChanged, formatChanged) {
        case (false, false):
            logger.info("configChange: nothing changed, dropping")
        case (false, true):
            logger.warning("configChange: format-only change — reinstalling tap on same engine")
            reinstallTap(format: liveFormat)
        case (true, _):
            logger.warning("configChange: input device changed — full hot-swap")
            hotSwapMicrophone()
            // Force the cache to reflect what we observed at handler entry, regardless of
            // whether warmUp succeeded inside hotSwap. If warm-up threw, the engine is
            // gone but the *system*'s default input is still `liveDeviceID`; without this
            // update we'd loop on the next configChange comparing stale cache vs the
            // already-swapped live state.
            lastKnownInputFormat = liveFormat
            lastKnownInputDeviceID = liveDeviceID
        }
    }

    /// Re-tap on the same engine without stopping it. Critically, this does NOT call
    /// `engine.stop()` and does NOT write `kAudioOutputUnitProperty_CurrentDevice`,
    /// so it does not satisfy the documented trigger condition for
    /// `.AVAudioEngineConfigurationChange` — the loop cannot form by construction.
    private func reinstallTap(format: AVAudioFormat) {
        guard let engine = audioEngine else { return }
        engine.inputNode.removeTap(onBus: 0)
        let ringBufferLock = self.ringBuffer
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard self?.isStreaming ?? false else { return }
            let floats = Array(UnsafeBufferPointer(
                start: buffer.floatChannelData![0],
                count: Int(buffer.frameLength)
            ))
            ringBufferLock.withLock { buf in
                buf.append(contentsOf: floats)
            }
        }
        nativeSampleRate = format.sampleRate
        // Self-update the cache so callers don't need to (matches warmUp's invariant
        // and prevents the next configChange from re-firing on the same format).
        lastKnownInputFormat = format
        logger.info("Tap reinstalled at \(format.sampleRate, privacy: .public)Hz x\(format.channelCount, privacy: .public)ch")
    }

    private var retiredEngines: [AVAudioEngine] = []

    func coolDown() {
        guard isEngineWarmed else { return }
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        configDebounceTask?.cancel()
        configDebounceTask = nil
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        retireEngine(audioEngine)
        audioEngine = nil
        isEngineWarmed = false
        sessionClassification = nil
        ringBuffer.withLock { $0.removeAll() }
        logger.info("Audio engine cooled down")
    }

    private func retireEngine(_ engine: AVAudioEngine?) {
        guard let engine else { return }
        retiredEngines.append(engine)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.retiredEngines.removeAll { $0 === engine }
        }
    }

    // MARK: - Mic Hot-Swap

    private func hotSwapMicrophone() {
        guard let engine = audioEngine else { return }
        configDebounceTask?.cancel()
        configDebounceTask = nil

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

        // Bypass the 1s warmUp debounce — this is a same-tick recreate.
        lastWarmUpTime = .distantPast
        warmUp(fromBackground: true)

        if !isEngineWarmed {
            logger.error("Hot-swap failed: audio engine did not start with new device")
        }

        ringBuffer.withLock { buffer in
            buffer.insert(contentsOf: preserved, at: 0)
        }

        logger.info("Hot-swapped microphone, preserved \(preserved.count) samples")
    }

    /// Re-evaluate routing for the current output device. A chip flip on the *current*
    /// device is a routing-policy change only — the physical mic is unchanged, so the
    /// AVAudioEngine and tap stay running. We only need to update the routing flag
    /// (read by the feedTask) and start/stop SystemAudioService for the new policy.
    ///
    /// Synchronously recreating the engine here was the original design but raced
    /// Core Audio's HAL I/O release window (~100-200ms after `engine.stop()`), leaving
    /// the new tap silent. See deep-resolve report 2026-05-12.
    func applyClassificationChange() {
        guard isStreaming else { return }
        let newClassification = MicrophoneService.shared.getCurrentOutputUID()
            .flatMap { classifier.classification(for: $0) }
        if newClassification == sessionClassification { return }

        logger.info("Output classification changed mid-stream — updating routing only")
        ErrorToastManager.shared.show("Audio configuration changed — recording continues")

        let userToggle = MicrophoneService.shared.speakerCaptureEnabled
        let newSpeakerEnabled = Self.effectiveSpeakerCaptureEnabled(
            classification: newClassification,
            userToggle: userToggle
        )
        let priorSpeakerEnabled = speakerCaptureActiveForSession

        sessionClassification = newClassification
        speakerCaptureActiveForSession = newSpeakerEnabled

        // Flip the lock BEFORE adjusting SystemAudioService — the feed loop reading the
        // new flag immediately reflects the new policy, and any small race during the
        // start/stop transition shows up as a few empty sys drains (mic-only output for
        // those iterations), not as wrong content.
        speakerCaptureActiveLock.withLock { $0 = newSpeakerEnabled }

        // Reset the mixer's carry-over buffers when crossing the sys/mic boundary so
        // stale samples from before the transition don't desynchronize the next mix.
        if newSpeakerEnabled != priorSpeakerEnabled {
            audioMixer?.reset()
        }

        if newSpeakerEnabled && !priorSpeakerEnabled {
            Task {
                do {
                    try await SystemAudioService.shared.startCapture(sampleRate: 48000)
                    logger.info("Routing change: speaker capture started")
                } catch {
                    logger.warning("Routing change: speaker capture failed: \(error, privacy: .public)")
                }
            }
        } else if !newSpeakerEnabled && priorSpeakerEnabled {
            Task {
                await SystemAudioService.shared.stopCapture()
                logger.info("Routing change: speaker capture stopped")
            }
        }
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

        if !isEngineWarmed || audioEngine?.isRunning != true {
            coolDown()
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

        let userSpeakerToggle = MicrophoneService.shared.speakerCaptureEnabled
        let outputUID = MicrophoneService.shared.getCurrentOutputUID()
        let outputName = MicrophoneService.shared.getCurrentOutputDisplayName() ?? (outputUID.map { String($0.prefix(16)) } ?? "Unknown")

        var classification: DeviceClassification? = nil
        if let uid = outputUID {
            if let known = classifier.classification(for: uid) {
                classification = known
            } else if userSpeakerToggle {
                // Only ask when sys-capture is on; otherwise mic-only is fine without classification.
                if let answer = classifier.askUser(uid: uid, displayName: outputName) {
                    classifier.set(answer, for: uid, displayName: outputName)
                    classification = answer
                }
            }
        }

        sessionClassification = classification

        let speakerEnabled = Self.effectiveSpeakerCaptureEnabled(
            classification: classification,
            userToggle: userSpeakerToggle
        )
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

        // Seed the lock with the initial routing decision so the feed loop sees
        // the same value as the synchronous setup above on its very first iteration.
        speakerCaptureActiveLock.withLock { $0 = speakerEnabled }

        let ringBufferRef = self.ringBuffer
        let shouldStopRef = self.shouldStopFeeding
        let speakerActiveRef = self.speakerCaptureActiveLock
        let sampleRate = self.nativeSampleRate
        feedTask = Task.detached {
            var consecutiveEmptyDrains = 0
            var feedIterationCount = 0
            var lastStatusLogTime = ContinuousClock.now

            while !shouldStopRef.withLock({ $0 }) {
                feedIterationCount += 1
                let micSamples = ringBufferRef.withLock { buffer -> [Float] in
                    guard !buffer.isEmpty else { return [] }
                    let drained = buffer
                    buffer.removeAll(keepingCapacity: true)
                    return drained
                }

                // Read routing flag fresh each iteration so popover chip flips on the
                // current device (and outputDeviceDidChange transitions) take effect
                // without restarting the streaming session.
                let speakerActiveNow = speakerActiveRef.withLock { $0 }

                let samples16k: [Float]
                if speakerActiveNow {
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
                    consecutiveEmptyDrains = 0

                    // Backpressure: if >5s of audio buffered, keep only last 1s
                    // Prevents cascading failure when inference falls behind real-time
                    let backpressureThreshold = 80000 // 5 seconds at 16kHz
                    let backpressureKeep = 16000       // 1 second at 16kHz
                    var feedSamples = samples16k
                    if feedSamples.count > backpressureThreshold {
                        let dropped = feedSamples.count - backpressureKeep
                        logger.warning("Backpressure: dropping \(dropped, privacy: .public) samples (\(String(format: "%.1f", Double(dropped) / 16000.0), privacy: .public)s), keeping last 1s")
                        feedSamples = Array(feedSamples.suffix(backpressureKeep))
                    }

                    let feedStart = ContinuousClock.now
                    session.feedAudio(samples: feedSamples)
                    let feedMs = feedStart.duration(to: .now).milliseconds
                    if feedMs > 500 {
                        logger.warning("feedAudio took \(feedMs, privacy: .public)ms for \(feedSamples.count, privacy: .public) samples — may be falling behind real-time")
                    }
                    do {
                        try writer.writeChunk(feedSamples)
                        PipelineTrace.shared.log("WAV", "wrote \(feedSamples.count) samples")
                    } catch {
                        PipelineTrace.shared.log("WAV", "write FAILED: \(error)")
                        logger.error("Failed to write WAV chunk: \(error, privacy: .public)")
                    }
                } else {
                    consecutiveEmptyDrains += 1
                    // Alert if ring buffer has been empty for >5 seconds — tap may have stopped
                    if consecutiveEmptyDrains == 50 {
                        logger.error("Ring buffer empty for ~5s — audio tap may have stopped delivering buffers")
                    } else if consecutiveEmptyDrains > 0 && consecutiveEmptyDrains % 300 == 0 {
                        logger.error("Ring buffer empty for ~\(consecutiveEmptyDrains / 10)s — audio tap appears dead")
                    }
                }

                // Periodic status log every 30 seconds
                let now = ContinuousClock.now
                if lastStatusLogTime.duration(to: now) > .seconds(30) {
                    let bufferSize = ringBufferRef.withLock { $0.count }
                    logger.info("Feed loop status: iteration=\(feedIterationCount, privacy: .public) ringBuf=\(bufferSize, privacy: .public) emptyDrains=\(consecutiveEmptyDrains, privacy: .public)")
                    lastStatusLogTime = now
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

        let chunkSize = max(1, Int(chunkDuration * 16000))
        let tailSilence = [Float](repeating: 0, count: 10560)
        let totalChunks = (samples.count + chunkSize - 1) / chunkSize

        let localFeedTask = Task.detached {
            var offset = 0
            while offset < samples.count {
                let end = min(offset + chunkSize, samples.count)
                let chunk = Array(samples[offset..<end])
                offset = end
                session.feedAudio(samples: chunk)
                try? await Task.sleep(for: .milliseconds(10))
            }
            session.feedAudio(samples: tailSilence)
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
            chunksFed: totalChunks,
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
