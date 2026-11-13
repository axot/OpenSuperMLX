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

struct StreamingCaptureHealth: Equatable {
    var samplesCaptured = 0

    var hasCapturedSamples: Bool {
        samplesCaptured > 0
    }

    mutating func recordSamplesCaptured(_ count: Int) {
        samplesCaptured += max(0, count)
    }
}

struct MicrophoneCaptureSource {
    var buffer: MicrophoneCaptureBuffer?
    var sampleRate: Double = 44100
    var pendingDrops = 0

    mutating func beginRequest() {
        pendingDrops = 0
    }

    mutating func discard() {
        buffer = nil
        pendingDrops = 0
    }
}

struct StreamingFeedState: Sendable {
    let archive: StreamingAACArchive
    private(set) var retryBuffer = PCMRetryBuffer()
    private var didReportArchiveFailure = false

    init(archive: StreamingAACArchive) {
        self.archive = archive
    }

    mutating func append(_ samples: [Float]) -> Error? {
        retryBuffer.append(samples)
        if let error = archive.failure {
            guard !didReportArchiveFailure else { return nil }
            didReportArchiveFailure = true
            return error
        }
        if let error = archive.write(samples) {
            didReportArchiveFailure = true
            return error
        }
        return nil
    }
}

struct StreamingCaptureOutcome {
    let text: String
    let duration: TimeInterval
    let audioURL: URL?
    let storageError: RecordingStorageError?
    let retryBuffer: PCMRetryBuffer
    let recordingID: UUID
    let timestamp: Date
    let fileName: String
}

// MARK: - StreamingAudioService

@MainActor
class StreamingAudioService: ObservableObject {
    static let shared = StreamingAudioService()

    // MARK: - Published State

    @Published private(set) var confirmedText = ""
    @Published private(set) var provisionalText = ""
    @Published private(set) var transcriptDisplayUpdate: LiveTranscriptSnapshot?
    @Published private(set) var isStreaming = false
    @Published private(set) var isCaptureReady = false
    @Published private(set) var currentRMSLevel: Float = 0

    // MARK: - Private State

    private var microphoneInput: PreparedMicrophoneInput?
    private var audioMixer: AudioMixer?
    private var nativeSampleRate: Double = 44100
    /// True iff the current streaming session is mixing system audio with mic.
    /// Reads through `speakerCaptureActiveLock` so all consumers see the same value
    /// the feedTask is using.
    private var speakerCaptureActiveForSession: Bool {
        get { speakerCaptureActiveLock.withLock { $0 } }
        set { speakerCaptureActiveLock.withLock { $0 = newValue } }
    }
    private var streamingSession: StreamingInferenceSession?
    private var aacArchive: StreamingAACArchive?
    private var currentRecordingID: UUID?
    private var currentRecordingFileName: String?
    private var hasTranscriptionGaps = false
    private var hasReportedUnavailableEncoder = false
    var transcriptSessionStore: TranscriptSessionStore = .shared
    private(set) var currentTranscriptSessionID: String?

    private var feedTask: Task<StreamingFeedState, Never>?
    private var eventTask: Task<Void, Never>?
    private var inputHealthTask: Task<Void, Never>?
    private var recordingStartTime: Date?
    private var microphoneChangeObserver: NSObjectProtocol?
    private var microphoneDisconnectObserver: NSObjectProtocol?
    private var configChangeObserver: NSObjectProtocol?
    private var outputChangeObserver: NSObjectProtocol?
    private var configDebounceTask: Task<Void, Never>?
    private var outputDebounceTask: Task<Void, Never>?

    /// Retained samples from file injection or a microphone handoff.
    private let ringBuffer = OSAllocatedUnfairLock(initialState: [Float]())
    private let microphoneSource = OSAllocatedUnfairLock(initialState: MicrophoneCaptureSource())
    private let captureState = OSAllocatedUnfairLock(initialState: StreamingCaptureHealth())

    private var rmsTimer: Timer?

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
    private var lastKnownInputFormat: EngineInitFormat?
    private var lastKnownInputDeviceID: AudioDeviceID?

    /// Synchronously gates re-entry into the configChange handler within a single
    /// dispatch — strict scope, no timer. Set true on entry, defer-cleared on exit.
    private var isHandlingConfigChange = false

    private var isEnginePrepared = false
    private var captureIsRequested = false
    private var captureRequestGeneration: Int?
    private var captureStartedAt: Date?
    private var lastWarmUpTime: Date = .distantPast
    private var inputRecoveryAttempts = 0

    /// Serializes one engine-init transaction at a time. Native calls run here so a
    /// slow device handoff never blocks the main thread; the commit decision stays on
    /// the main actor, gated by the generation counter.
    private static let engineInitQueue = DispatchQueue(label: "OpenSuperMLX.engineInit", qos: .userInitiated)
    private let initGate = EngineInitGate()
    private let captureStartGate = EngineInitGate()
    private var engineInitTask: Task<EngineInitVerdict, Never>?
    private var engineInitTargetUID: String?
    /// Identity token for the currently tracked init transaction; lets the launching
    /// caller know it — and not a superseding request — still owns the cleanup.
    private var engineInitEpoch = UUID()
    /// Bumped by `abortPendingStart` so a start that was cancelled during engine
    /// init cannot later flip `isStreaming` on.
    private var startGeneration = 0

    /// Output device classifier — testable seam (write at test setUp).
    var classifier: OutputDeviceClassifierProtocol = OutputDeviceClassifier.shared

    /// Classification class (.speaker / .headphone / nil-as-safe) snapshot at the
    /// most recent startStreaming. Used to detect class flips that warrant a tap-restart.
    private var sessionClassification: DeviceClassification?

    // MARK: - Routing Decision

    /// Pure routing decision based on current output classification + user toggle.
    /// Speaker output (or unclassified, treated as speaker for safety) forces mic-only
    /// to avoid the speaker→mic echo path; only headphones allow mic+sys mixing.
    static func effectiveSpeakerCaptureEnabled(
        classification: DeviceClassification?,
        userToggle: Bool
    ) -> Bool {
        userToggle && classification == .headphone
    }

    // MARK: - Feed Loop Helpers

    nonisolated static func shouldContinueFeedLoop(isCancelled: Bool, shouldStop: Bool) -> Bool {
        !isCancelled && !shouldStop
    }

    nonisolated static func waitForNextFeedIteration() async -> Bool {
        do {
            try await Task.sleep(for: .milliseconds(100))
            return true
        } catch {
            return false
        }
    }

    nonisolated static func splitArchiveAndInferenceSamples(
        _ samples: [Float]
    ) -> (archive: [Float], inference: [Float]) {
        let threshold = Int(AudioSampleRates.transcription * 5)
        guard samples.count > threshold else {
            return (samples, samples)
        }
        let keepCount = Int(AudioSampleRates.transcription)
        return (samples, Array(samples.suffix(keepCount)))
    }

    nonisolated static func makeFinalMixedSamples(
        mixer: AudioMixer,
        microphone: [Float],
        microphoneSampleRate: Double,
        system: [Float],
        systemSampleRate: Double,
        speakerCaptureActive: Bool
    ) -> [Float] {
        var samples = speakerCaptureActive
            ? mixer.mix(
                mic: microphone,
                micSampleRate: microphoneSampleRate,
                sys: system,
                sysSampleRate: systemSampleRate
            )
            : mixer.micOnly(
                microphone,
                inputSampleRate: microphoneSampleRate
            )
        samples.append(contentsOf: mixer.drainCarryOver())
        return samples
    }

    // MARK: - RMS Metering

    /// Root-mean-square amplitude of channel 0, clamped to [0, 1]. Microphone input is
    /// mono so channel 0 carries the signal; multi-channel aggregate devices still keep
    /// primary audio on channel 0. Pure + nonisolated for unit testing and tap-thread use.
    nonisolated static func computeRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count { sum += data[i] * data[i] }
        let rms = sqrt(sum / Float(count))
        // A denormal/corrupt buffer can make `rms` NaN; that would flow into a
        // SwiftUI `.frame(height:)` and corrupt layout. Clamp non-finite to 0.
        guard rms.isFinite else { return 0 }
        return min(1.0, rms)
    }

    /// Resolve the recording duration to persist. The session-measured value is
    /// authoritative; a caller-supplied wall-clock is only a fallback for when the
    /// session had no start time. Prevents the duration=0 rows that broke stats.
    nonisolated static func resolveDuration(measured: TimeInterval, caller: TimeInterval) -> TimeInterval {
        measured > 0 ? measured : max(0, caller)
    }

    private func startRMSTimer() {
        rmsTimer?.invalidate()
        rmsTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentRMSLevel = self.microphoneInput?.buffer.rmsLevel ?? 0
            }
        }
    }

    private func stopRMSTimer() {
        rmsTimer?.invalidate()
        rmsTimer = nil
        currentRMSLevel = 0
    }

    // MARK: - Idle Metering (popover VU)

    /// True while the mic-picker popover is open and wants a live level. Read by
    /// `resumeIdleMeteringIfNeeded()` so that a recording ending while the popover
    /// is still open restarts the metering timer the stop path tore down.
    private var popoverWantsMetering = false

    /// Starts awaiting engine init own the engine before `isStreaming` flips, so idle
    /// release must not cool it down underneath them.
    private var pendingStreamStarts = 0

    /// Prepare the selected input without enabling idle microphone I/O.
    func startIdleMetering() {
        popoverWantsMetering = true
        guard !isStreaming else { return }
        if !isEnginePrepared {
            Task { await self.warmUp() }
        }
    }

    /// Close the picker without interrupting a requested capture.
    func stopIdleMetering() {
        popoverWantsMetering = false
        releaseEngineIfIdle()
    }

    /// Idle input I/O stops even when the picker is open; prepared resources stay cached.
    nonisolated static func shouldReleaseEngine(
        isStreaming: Bool,
        hasPendingStart: Bool,
        popoverWantsMetering: Bool
    ) -> Bool {
        !isStreaming && !hasPendingStart
    }

    private func releaseEngineIfIdle() {
        guard Self.shouldReleaseEngine(
            isStreaming: isStreaming,
            hasPendingStart: pendingStreamStarts > 0 || captureIsRequested,
            popoverWantsMetering: popoverWantsMetering
        ) else { return }
        microphoneInput?.pause()
        stopRMSTimer()
        isCaptureReady = false
    }

    /// Restart idle metering after a recording ends if the picker popover is still
    /// open. The popover's `.onAppear` only fires once, so without this its VU would
    /// sit dead at 0 (the stop path invalidated the timer) until reopened.
    private func resumeIdleMeteringIfNeeded() {
        guard popoverWantsMetering, !isStreaming else { return }
        startIdleMetering()
    }

    // MARK: - Device Classification

    /// Look up the current default output's classification, optionally prompting the
    /// user via `classifier.askUser` if it's never been seen before. Returns `nil` if
    /// there's no UID or the user cancels — both cases route as safe-default speaker.
    private func resolveCurrentClassification(askIfNeeded: Bool) -> DeviceClassification? {
        guard let uid = MicrophoneService.shared.getCurrentOutputUID() else { return nil }
        if let known = classifier.classification(for: uid) { return known }
        guard askIfNeeded else { return nil }
        // Only ask when sys-capture is on; otherwise mic-only is fine without classification.
        let displayName = MicrophoneService.shared.getCurrentOutputDisplayName()
            ?? fallbackDisplayName(forUID: uid)
        guard let answer = classifier.askUser(uid: uid, displayName: displayName) else { return nil }
        classifier.set(answer, for: uid, displayName: displayName)
        return answer
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
                    if self.activeTargetDiffersFromBoundEngine() {
                        await self.hotSwapMicrophone()
                    }
                } else if self.isEnginePrepared {
                    if self.activeTargetDiffersFromBoundEngine() {
                        self.coolDown()
                        await self.warmUp(fromBackground: true)
                    }
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
                } else if self.isEnginePrepared {
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

    func warmUp(fromBackground: Bool = false) async {
        guard !isEnginePrepared, microphoneInput == nil else { return }
        if fromBackground && Date().timeIntervalSince(lastWarmUpTime) < 1.0 {
            logger.info("Skipping warmUp — last warmUp was < 1s ago")
            return
        }

        await beginEngineInit()
    }

    /// Resolve the active mic and run (or join) one pinned-device init transaction for
    /// it. Concurrent requests for the same device share the in-flight transaction; a
    /// different target supersedes it.
    private func beginEngineInit() async -> EngineInitVerdict {
        let activeMic = MicrophoneService.shared.activateForRecording()
        guard let target = activeMic,
              MicrophoneService.shared.getCoreAudioDeviceID(for: target) != nil else {
            logger.error("No CoreAudio device for active microphone: \(activeMic?.displayName ?? "nil", privacy: .public)")
            return .failExplicit(.deviceUnresolvable)
        }

        if EngineInitTransaction.shouldJoinInFlight(
            hasInFlightTask: engineInitTask != nil,
            sameTarget: engineInitTargetUID == target.id,
            isCancelled: engineInitTask?.isCancelled ?? true
        ), let task = engineInitTask {
            return await task.value
        }
        engineInitTask?.cancel()

        let generation = initGate.beginRequest(targetUID: target.id)
        let epoch = UUID()
        let task = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return EngineInitVerdict.abandon }
            return await self.runInitTransaction(target: target, generation: generation)
        }
        engineInitTask = task
        engineInitTargetUID = target.id
        engineInitEpoch = epoch

        let verdict = await task.value
        if engineInitEpoch == epoch {
            engineInitTask = nil
            engineInitTargetUID = nil
            initGate.endRequest(generation: generation)
        }
        return verdict
    }

    private struct NativeEngineInitResult {
        let input: PreparedMicrophoneInput?
        let verdict: EngineInitVerdict
    }

    private func runInitTransaction(target: MicrophoneService.AudioDevice, generation: Int) async -> EngineInitVerdict {
        let result: NativeEngineInitResult = await withCheckedContinuation { continuation in
            Self.engineInitQueue.async { [weak self] in
                guard let self else { return }
                continuation.resume(returning: self.performNativeInit(target: target))
            }
        }
        guard !Task.isCancelled,
              initGate.shouldCommit(generation: generation, targetUID: target.id) else {
            result.input?.stop()
            return .abandon
        }
        guard let input = result.input else { return result.verdict }
        let verdict = input.preparedVerdict
        guard case .commit(let rate) = verdict else {
            input.stop()
            return verdict
        }
        microphoneInput = input
        nativeSampleRate = rate
        isEnginePrepared = true
        lastWarmUpTime = Date()
        lastKnownInputFormat = input.format
        lastKnownInputDeviceID = input.boundDeviceID
        let preserveCapturedAudio = isStreaming || captureIsRequested
        microphoneSource.withLock { source in
            let retained = ringBuffer.withLock { buffer in
                let samples = buffer
                buffer.removeAll()
                return samples
            }
            let transferred = Self.makeMicrophoneHandoffSamples(
                retained: retained, captured: source.buffer?.drain() ?? [],
                inputSampleRate: source.sampleRate, outputSampleRate: rate,
                preserve: preserveCapturedAudio
            )
            ringBuffer.withLock { $0.append(contentsOf: transferred) }
            source.pendingDrops = preserveCapturedAudio
                ? source.pendingDrops + (source.buffer?.droppedSampleCount ?? 0) : 0
            source.buffer = input.buffer
            source.sampleRate = rate
        }
        observeEngineConfigChange(input)
        logger.info("Microphone engine prepared without I/O: device=\(target.displayName, privacy: .public) rate=\(Int(rate), privacy: .public)Hz")
        return verdict
    }

    nonisolated private func performNativeInit(target: MicrophoneService.AudioDevice) -> NativeEngineInitResult {
        guard let deviceID = MicrophoneService.shared.getCoreAudioDeviceID(for: target) else {
            return NativeEngineInitResult(input: nil, verdict: .failExplicit(.deviceUnresolvable))
        }
        do {
            let input = try PreparedMicrophoneInput(targetDeviceID: deviceID)
            let verdict = input.prepare()
            return NativeEngineInitResult(input: input, verdict: verdict)
        } catch let failure as EngineInitFailure {
            logger.error("Microphone preparation failed: \(String(describing: failure), privacy: .public)")
            return NativeEngineInitResult(input: nil, verdict: .failExplicit(failure))
        } catch {
            return NativeEngineInitResult(input: nil, verdict: .failExplicit(.engineStartFailed(String(describing: error))))
        }
    }

    /// Read back the device the engine's input AU is actually bound to — the verify
    /// primitive for the pinned-device transaction and the engine-scoped comparison
    /// used by the configChange handler.
    nonisolated static func boundInputDeviceID(of engine: AVAudioEngine) -> AudioDeviceID? {
        guard let audioUnit = engine.inputNode.audioUnit else { return nil }
        var deviceID = AudioDeviceID()
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0,
            &deviceID, &size
        )
        return status == noErr ? deviceID : nil
    }

    private func observeEngineConfigChange(_ engine: PreparedMicrophoneInput) {
        if let old = configChangeObserver {
            NotificationCenter.default.removeObserver(old)
        }
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine.configurationObject,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.configDebounceTask?.cancel()
                self.configDebounceTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(200))
                    guard !Task.isCancelled, let self else { return }
                    await self.handleConfigChange()
                }
            }
        }
    }

    /// Branches on what actually changed, so the recovery path does not re-trigger the
    /// trigger condition for `.AVAudioEngineConfigurationChange`. This eliminates the
    /// hot-swap feedback loop that bounded `feedAudio` to 500–1300ms.
    private func handleConfigChange() async {
        guard !isHandlingConfigChange, let input = microphoneInput else { return }
        isHandlingConfigChange = true
        defer { isHandlingConfigChange = false }

        let changed = input.boundDeviceID != lastKnownInputDeviceID || input.format != lastKnownInputFormat
        if changed {
            if isStreaming {
                await hotSwapMicrophone()
            } else if !isStreaming && pendingStreamStarts == 0 {
                coolDown()
                await warmUp()
            }
        } else if captureIsRequested && !input.isRunning {
            logger.warning("Microphone configuration stopped the engine; resuming the existing input")
            let verdict = await resumeInput(input)
            if case .commit = verdict { return }
            logger.error("Microphone resume failed: \(String(describing: verdict), privacy: .public)")
        }
    }

    private func resumeInput(_ input: PreparedMicrophoneInput, restart: Bool = false) async -> EngineInitVerdict {
        guard captureIsRequested, let generation = captureRequestGeneration else { return .abandon }
        let gate = captureStartGate
        let source = microphoneSource
        let priorDelivery = input.buffer.lastBufferDeliveryHostTime
        isCaptureReady = false
        let verdict: EngineInitVerdict = await withCheckedContinuation { continuation in
            Self.engineInitQueue.async {
                guard gate.shouldCommit(generation: generation, targetUID: "recording"),
                      source.withLock({ $0.buffer === input.buffer }) else {
                    continuation.resume(returning: .abandon)
                    return
                }
                let resumed = restart ? input.restart() : input.resume()
                if !gate.shouldCommit(generation: generation, targetUID: "recording")
                    || !source.withLock({ $0.buffer === input.buffer }) {
                    input.pause()
                    continuation.resume(returning: .abandon)
                } else {
                    continuation.resume(returning: resumed)
                }
            }
        }
        guard case .commit = verdict else { return verdict }
        let deadline = ContinuousClock.now + .milliseconds(900)
        while input.buffer.lastBufferDeliveryHostTime <= priorDelivery && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
            guard captureIsRequested, captureRequestGeneration == generation,
                  microphoneInput === input, !Task.isCancelled else { return .abandon }
        }
        guard input.isRunning, input.buffer.lastBufferDeliveryHostTime > priorDelivery else {
            return .failExplicit(.engineStartFailed("Microphone delivery did not resume"))
        }
        isCaptureReady = true
        return verdict
    }

    private func drainMicrophoneSamples() -> [Float] {
        microphoneSource.withLock { $0.buffer?.drain() ?? [] }
    }

    nonisolated static func makeMicrophoneHandoffSamples(
        retained: [Float], captured: [Float],
        inputSampleRate: Double, outputSampleRate: Double,
        preserve: Bool
    ) -> [Float] {
        guard preserve else { return [] }
        return AudioMixer(inputSampleRate: inputSampleRate).micOnly(
            retained + captured, inputSampleRate: inputSampleRate, outputSampleRate: outputSampleRate
        )
    }

    struct PlainMicGraphStatus: Equatable {
        let unexpectedNodeTypes: [String]
        let outputConnectionCount: Int

        var isPlainMicGraph: Bool {
            unexpectedNodeTypes.isEmpty && outputConnectionCount == 0
        }
    }

    nonisolated static func plainMicGraphStatus(engine: AVAudioEngine, inputNode: AVAudioInputNode) -> PlainMicGraphStatus {
        let unexpectedNodeTypes = engine.attachedNodes
            .filter { $0 !== inputNode }
            .map { String(describing: type(of: $0)) }
            .sorted()
        let outputConnectionCount = engine.outputConnectionPoints(for: inputNode, outputBus: 0).count
        return PlainMicGraphStatus(
            unexpectedNodeTypes: unexpectedNodeTypes,
            outputConnectionCount: outputConnectionCount
        )
    }

    private func resetCaptureHealth() {
        captureState.withLock { $0 = StreamingCaptureHealth() }
    }

    private func cancelInputHealthCheck() {
        inputHealthTask?.cancel()
        inputHealthTask = nil
    }

    private func resetHealthForNewRecording() {
        cancelInputHealthCheck()
        inputRecoveryAttempts = 0
        resetCaptureHealth()
    }

    private func scheduleInputHealthCheck(afterMilliseconds delay: Int = 900) {
        cancelInputHealthCheck()
        inputHealthTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled, let self, self.isStreaming else { return }
                guard let input = self.microphoneInput else { return }
                let last = input.buffer.lastBufferDeliveryHostTime
                let now = DispatchTime.now().uptimeNanoseconds
                if !input.isRunning || last == 0 || now - last > 900_000_000 {
                    await self.recoverInputStall()
                } else {
                    self.inputRecoveryAttempts = 0
                }
            }
        }
    }

    private func recoverInputStall() async {
        guard isStreaming, captureIsRequested, let input = microphoneInput else { return }
        guard inputRecoveryAttempts < 2 else {
            cancelInputHealthCheck()
            isCaptureReady = false
            logger.error("Microphone input did not resume after retry")
            ErrorToastManager.shared.show("Microphone audio stopped. Try recording again.")
            return
        }
        inputRecoveryAttempts += 1
        let verdict = await resumeInput(input, restart: input.isRunning)
        if case .commit = verdict { return }
        await hotSwapMicrophone()
    }

    private var retiredInputs: [PreparedMicrophoneInput] = []

    func coolDown(preservingCapturedAudio: Bool = false) {
        stopRMSTimer()
        if !preservingCapturedAudio {
            cancelInputHealthCheck()
            inputRecoveryAttempts = 0
            microphoneSource.withLock { $0.discard() }
            ringBuffer.withLock { $0.removeAll() }
        }
        invalidatePendingEngineInit()
        guard isEnginePrepared else { return }
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        if !preservingCapturedAudio {
            configDebounceTask?.cancel()
            configDebounceTask = nil
        }
        microphoneInput?.stop()
        retireInput(microphoneInput)
        microphoneInput = nil
        isCaptureReady = false
        isEnginePrepared = false
        sessionClassification = nil
        logger.info("Audio engine cooled down")
    }

    private func invalidatePendingEngineInit() {
        initGate.cancelInFlight()
        engineInitTask?.cancel()
        engineInitTask = nil
        engineInitTargetUID = nil
        engineInitEpoch = UUID()
    }

    /// Invalidate an in-flight `startStreaming` so it cannot later flip `isStreaming`
    /// on after the caller already stopped or cancelled.
    func abortPendingStart() {
        startGeneration += 1
        captureIsRequested = false
        captureStartGate.cancelInFlight()
        captureRequestGeneration = nil
        invalidatePendingEngineInit()
        if let input = microphoneInput {
            input.buffer.close()
            Self.engineInitQueue.async { input.pause() }
        }
        isCaptureReady = false
    }

    private func throwIfStartAborted(_ generation: Int, reason: String) throws {
        guard startGeneration == generation, !Task.isCancelled else {
            PipelineTrace.shared.log("STREAM", reason)
            throw StreamingAudioError.startAborted
        }
    }

    private func retireInput(_ engine: PreparedMicrophoneInput?) {
        guard let engine else { return }
        retiredInputs.append(engine)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.retiredInputs.removeAll { $0 === engine }
        }
    }

    // MARK: - Mic Hot-Swap

    private func hotSwapMicrophone() async {
        guard let input = microphoneInput, captureIsRequested,
              let generation = captureRequestGeneration else { return }
        let gate = captureStartGate
        let source = microphoneSource
        isCaptureReady = false
        input.pause()
        coolDown(preservingCapturedAudio: true)
        lastWarmUpTime = .distantPast
        let verdict = await beginEngineInit()
        guard case .commit = verdict, let replacement = microphoneInput,
              isStreaming, captureIsRequested, captureRequestGeneration == generation else { return }
        let started: EngineInitVerdict = await withCheckedContinuation { continuation in
            Self.engineInitQueue.async {
                guard gate.shouldCommit(generation: generation, targetUID: "recording"),
                      source.withLock({ $0.buffer === replacement.buffer }) else {
                    continuation.resume(returning: .abandon)
                    return
                }
                let result = replacement.start(at: DispatchTime.now().uptimeNanoseconds)
                if !gate.shouldCommit(generation: generation, targetUID: "recording")
                    || !source.withLock({ $0.buffer === replacement.buffer }) {
                    replacement.pause()
                    continuation.resume(returning: .abandon)
                } else {
                    continuation.resume(returning: result)
                }
            }
        }
        if case .commit = started {
            let deadline = ContinuousClock.now + .milliseconds(900)
            while !replacement.buffer.hasReceivedAudio && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
                guard captureIsRequested, captureRequestGeneration == generation,
                      microphoneInput === replacement, !Task.isCancelled else { return }
            }
            isCaptureReady = captureIsRequested && replacement.isRunning && replacement.buffer.hasReceivedAudio
            if isCaptureReady {
                scheduleInputHealthCheck()
                startRMSTimer()
            } else {
                replacement.pause()
            }
        } else {
            logger.error("Hot-swap failed: \(String(describing: started), privacy: .public)")
        }
    }

    /// True when the mic that should be recording now differs from the device the warm
    /// engine is actually bound to. Default-input churn with a saved (pinned) mic
    /// resolves to the same target and must not tear down a healthy engine.
    private func activeTargetDiffersFromBoundEngine() -> Bool {
        guard let engine = microphoneInput else { return true }
        let bound = engine.boundDeviceID
        guard let active = MicrophoneService.shared.activateForRecording(),
              let activeID = MicrophoneService.shared.getCoreAudioDeviceID(for: active) else { return true }
        return bound != activeID
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
        // Setter writes through the lock; feedTask sees the new value before
        // SystemAudioService start/stop races below. A few empty sys drains during
        // the transition produce mic-only output, not wrong content.
        speakerCaptureActiveForSession = newSpeakerEnabled

        // Reset the mixer's carry-over buffers when crossing the sys/mic boundary so
        // stale samples from before the transition don't desynchronize the next mix.
        if newSpeakerEnabled != priorSpeakerEnabled {
            audioMixer?.reset()
        }

        if newSpeakerEnabled && !priorSpeakerEnabled {
            Task {
                do {
                    try await SystemAudioService.shared.startCapture(sampleRate: AudioSampleRates.systemCapture)
                    logger.info("Routing change: speaker capture started")
                } catch {
                    logger.warning("Routing change: speaker capture failed: \(error, privacy: .public)")
                }
            }
        } else if !newSpeakerEnabled && priorSpeakerEnabled {
            Task {
                _ = await SystemAudioService.shared.stopAndDrain()
                logger.info("Routing change: speaker capture stopped")
            }
        }
    }

    // MARK: - Start Streaming

    func beginMicrophoneCapture(requestedAt: UInt64 = DispatchTime.now().uptimeNanoseconds) async throws {
        if captureIsRequested && isCaptureReady { return }
        guard !captureIsRequested else { throw StreamingAudioError.startAborted }
        _ = resolveCurrentClassification(askIfNeeded: MicrophoneService.shared.speakerCaptureEnabled)
        let generation = startGeneration
        let captureGeneration = captureStartGate.beginRequest(targetUID: "recording")
        let startGate = captureStartGate
        let source = microphoneSource
        source.withLock { $0.beginRequest() }
        captureRequestGeneration = captureGeneration
        captureIsRequested = true
        do {
            if !isEnginePrepared || activeTargetDiffersFromBoundEngine()
                || microphoneInput?.format != lastKnownInputFormat {
                coolDown()
                let verdict = await beginEngineInit()
                try throwIfStartAborted(generation, reason: "start cancelled during engine init")
                guard case .commit = verdict else {
                    PipelineTrace.shared.log("STREAM", "engine init failed: \(verdict)")
                    throw StreamingAudioError.engineInitFailed(
                        failure: verdict.failureDescription ?? "Engine initialization failed."
                    )
                }
            }

            try throwIfStartAborted(generation, reason: "start cancelled after engine init")

            guard let input = microphoneInput else {
                throw StreamingAudioError.audioFormatCreationFailed
            }
            let started: EngineInitVerdict = await withCheckedContinuation { continuation in
                Self.engineInitQueue.async {
                    guard startGate.shouldCommit(generation: captureGeneration, targetUID: "recording"),
                          source.withLock({ $0.buffer === input.buffer }) else {
                        continuation.resume(returning: .abandon)
                        return
                    }
                    let result = input.start(at: requestedAt)
                    if !startGate.shouldCommit(generation: captureGeneration, targetUID: "recording")
                        || !source.withLock({ $0.buffer === input.buffer }) {
                        input.pause()
                        continuation.resume(returning: .abandon)
                    } else {
                        continuation.resume(returning: result)
                    }
                }
            }
            try throwIfStartAborted(generation, reason: "start cancelled while enabling microphone")
            guard case .commit = started else {
                throw StreamingAudioError.engineInitFailed(failure: started.failureDescription ?? "Microphone failed to start.")
            }
            let deadline = ContinuousClock.now + .milliseconds(900)
            while !input.buffer.hasReceivedAudio && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
                try throwIfStartAborted(generation, reason: "start cancelled before microphone audio arrived")
                if !input.isRunning {
                    let resumed = await resumeInput(input)
                    guard case .commit = resumed else { break }
                }
            }
            guard input.isRunning, input.buffer.hasReceivedAudio,
                  microphoneInput === input,
                  startGate.shouldCommit(generation: captureGeneration, targetUID: "recording") else {
                input.pause()
                throw StreamingAudioError.engineInitFailed(failure: "Microphone audio did not start. Try recording again.")
            }
            isCaptureReady = true
            captureStartedAt = Date()
            if let latency = input.buffer.firstBufferLatencyMilliseconds {
                logger.info("Microphone audio ready: first_delivery_ms=\(latency, privacy: .public)")
                PipelineTrace.shared.log("MIC_READY", "first_delivery_ms=\(latency)")
            }
            playNotificationSound()
        } catch {
            if captureRequestGeneration == captureGeneration {
                captureIsRequested = false
                captureRequestGeneration = nil
                captureStartGate.endRequest(generation: captureGeneration)
                releaseEngineIfIdle()
            }
            throw error
        }
    }


    func startStreaming() async throws {
        let requestedAt = DispatchTime.now().uptimeNanoseconds
        PipelineTrace.shared.log("STREAM", "startStreaming() called")

        guard !isStreaming else {
            PipelineTrace.shared.log("STREAM", "already streaming, skipped")
            logger.warning("Already streaming, ignoring startStreaming()")
            return
        }
        guard pendingStreamStarts == 0 else { throw StreamingAudioError.startAborted }

        let generation = startGeneration
        pendingStreamStarts += 1
        defer {
            if !isStreaming, startGeneration == generation, let captureGeneration = captureRequestGeneration {
                captureStartGate.endRequest(generation: captureGeneration)
                captureRequestGeneration = nil
                captureIsRequested = false
            }
            pendingStreamStarts -= 1
            releaseEngineIfIdle()
        }

        guard let model = TranscriptionService.shared.streamingModel else {
            PipelineTrace.shared.log("STREAM", "no model available")
            logger.error("No model available for streaming")
            throw StreamingAudioError.modelNotLoaded
        }

        try await beginMicrophoneCapture(requestedAt: requestedAt)
        shouldStopFeeding.withLock { $0 = false }
        resetHealthForNewRecording()
        confirmedText = ""
        provisionalText = ""
        transcriptDisplayUpdate = nil

        let startTime = captureStartedAt ?? Date()
        let recordingID = UUID()
        let pendingDirectory = Recording.pendingRecordingsDirectory
        let fileName = RecordingAudioFormat.makeFileName(
            timestamp: startTime,
            id: recordingID,
            isTaken: { candidate in
                FileManager.default.fileExists(
                    atPath: Recording.recordingsDirectory.appendingPathComponent(candidate).path
                ) || FileManager.default.fileExists(
                    atPath: pendingDirectory.appendingPathComponent(candidate).path
                )
            }
        )
        let aacURL = pendingDirectory.appendingPathComponent(fileName)
        currentRecordingID = recordingID
        currentRecordingFileName = fileName

        let archive: StreamingAACArchive
        do {
            try FileManager.default.createDirectory(
                at: pendingDirectory,
                withIntermediateDirectories: true
            )
            archive = StreamingAACArchive(url: aacURL)
        } catch {
            archive = StreamingAACArchive(
                url: aacURL,
                writerFactory: { _ in throw error }
            )
        }
        if let error = archive.failure {
            try? FileManager.default.removeItem(at: aacURL)
            logger.error("Failed to initialize AAC archive: \(error, privacy: .public)")
        }
        aacArchive = archive

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

        if startGeneration != generation {
            PipelineTrace.shared.log("STREAM", "start cancelled before going live")
            session.cancel()
            archive.cancel()
            aacArchive = nil
            currentRecordingID = nil
            currentRecordingFileName = nil
            streamingSession = nil
            throw StreamingAudioError.startAborted
        }

        isStreaming = true
        recordingStartTime = startTime
        beginTranscriptSession(startedAt: startTime)
        logger.info("Streaming started")

        let userSpeakerToggle = MicrophoneService.shared.speakerCaptureEnabled
        let classification = resolveCurrentClassification(askIfNeeded: false)
        sessionClassification = classification

        let speakerEnabled = Self.effectiveSpeakerCaptureEnabled(
            classification: classification,
            userToggle: userSpeakerToggle
        )
        speakerCaptureActiveForSession = speakerEnabled
        let mixer = AudioMixer(inputSampleRate: nativeSampleRate)
        self.audioMixer = mixer
        PipelineTrace.shared.log("STREAM", "streaming started speakerEnabled=\(speakerEnabled) sampleRate=\(nativeSampleRate)")

        if speakerEnabled {
            if AppPreferences.shared.debugMode {
                let traceDirectory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("temp_recordings")
                try? FileManager.default.createDirectory(
                    at: traceDirectory,
                    withIntermediateDirectories: true
                )
                let timestamp = Int(startTime.timeIntervalSince1970)
                let traceURL = traceDirectory.appendingPathComponent("\(timestamp)_mix_trace.log")
                mixer.startTrace(url: traceURL)
            }
            Task {
                do {
                    try await SystemAudioService.shared.startCapture(sampleRate: AudioSampleRates.systemCapture)
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
        let microphoneSourceRef = self.microphoneSource
        let shouldStopRef = self.shouldStopFeeding
        let speakerActiveRef = self.speakerCaptureActiveLock
        let captureStateRef = self.captureState
        feedTask = Task.detached { [weak self] in
            var reportedDrops = 0
            var feedState = StreamingFeedState(archive: archive)
            var consecutiveEmptyDrains = 0
            var feedIterationCount = 0
            var lastStatusLogTime = ContinuousClock.now

            while Self.shouldContinueFeedLoop(
                isCancelled: Task.isCancelled,
                shouldStop: shouldStopRef.withLock({ $0 })
            ) {
                feedIterationCount += 1
                let microphone = microphoneSourceRef.withLock { source in
                    let retained = ringBufferRef.withLock { buffer -> [Float] in
                        let drained = buffer
                        buffer.removeAll(keepingCapacity: true)
                        return drained
                    }
                    return (
                        retained + (source.buffer?.drain() ?? []), source.sampleRate,
                        source.pendingDrops + (source.buffer?.droppedSampleCount ?? 0)
                    )
                }
                if microphone.2 > reportedDrops {
                    reportedDrops = microphone.2
                    logger.error("Microphone capture overflow: dropped_samples=\(reportedDrops, privacy: .public)")
                    Task { @MainActor [weak self] in
                        guard let self, self.currentRecordingID == recordingID else { return }
                        self.hasTranscriptionGaps = true
                        ErrorToastManager.shared.show("Some microphone audio was lost while recording was delayed.")
                    }
                }
                let sampleRate = microphone.1
                let micSamples = microphone.0

                // Read routing flag fresh each iteration so popover chip flips on the
                // current device (and outputDeviceDidChange transitions) take effect
                // without restarting the streaming session.
                let speakerActiveNow = speakerActiveRef.withLock { $0 }

                let samples16k: [Float]
                if speakerActiveNow {
                    let sysSamples = await SystemAudioService.shared.drainAccumulatedSamples()
                    let sysSampleRate = await SystemAudioService.shared.activeSampleRate
                    samples16k = mixer.mix(mic: micSamples, micSampleRate: sampleRate, sys: sysSamples, sysSampleRate: sysSampleRate)
                    PipelineTrace.shared.log("FEED", "mic=\(micSamples.count) sys=\(sysSamples.count) out=\(samples16k.count)")
                } else if !micSamples.isEmpty {
                    samples16k = mixer.micOnly(micSamples, inputSampleRate: sampleRate)
                    PipelineTrace.shared.log("FEED", "micOnly=\(micSamples.count) out=\(samples16k.count)")
                } else {
                    samples16k = []
                }

                if !samples16k.isEmpty {
                    consecutiveEmptyDrains = 0
                    let split = Self.splitArchiveAndInferenceSamples(samples16k)
                    captureStateRef.withLock { $0.recordSamplesCaptured(split.archive.count) }

                    if let error = feedState.append(split.archive) {
                        PipelineTrace.shared.log("ARCHIVE", "write FAILED: \(error)")
                        logger.error("Failed to write AAC chunk: \(error, privacy: .public)")
                    } else if archive.failure == nil {
                        PipelineTrace.shared.log("ARCHIVE", "wrote \(split.archive.count) samples")
                    }

                    let feedSamples = split.inference
                    if feedSamples.count < split.archive.count {
                        let dropped = split.archive.count - feedSamples.count
                        logger.warning("Backpressure: dropping \(dropped, privacy: .public) samples (\(String(format: "%.1f", Double(dropped) / AudioSampleRates.transcription), privacy: .public)s), keeping last 1s")
                    }

                    let feedStart = ContinuousClock.now
                    session.feedAudio(
                        samples: feedSamples, skippedSamples: split.archive.count - feedSamples.count
                    )
                    let feedMs = feedStart.duration(to: .now).milliseconds
                    if feedMs > 500 {
                        logger.warning("feedAudio took \(feedMs, privacy: .public)ms for \(feedSamples.count, privacy: .public) samples — may be falling behind real-time")
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

                guard await Self.waitForNextFeedIteration() else { break }
            }
            return feedState
        }
        scheduleInputHealthCheck()
        startRMSTimer()
    }

    // MARK: - Stop Streaming

    struct StreamingStopResult {
        let text: String
        let url: URL?
        let duration: TimeInterval
        let recordingID: UUID
        let timestamp: Date
        let fileName: String
        let storageError: Error?
        let retryBuffer: PCMRetryBuffer
    }

    func stopStreaming() async -> StreamingStopResult? {
        let stoppedAt = Date()
        PipelineTrace.shared.log("STREAM", "stopStreaming() called")
        if !isStreaming {
            abortPendingStart()
            logger.warning("Not streaming, ignoring stopStreaming()")
            return nil
        }

        defer {
            isStreaming = false
            // If the mic-picker popover is still open, restart its metering timer —
            // the teardown below invalidated it but the popover won't re-fire onAppear.
            resumeIdleMeteringIfNeeded()
            releaseEngineIfIdle()
        }

        captureIsRequested = false
        captureStartGate.cancelInFlight()
        captureRequestGeneration = nil
        microphoneInput?.pause()
        isCaptureReady = false
        stopRMSTimer()
        cancelInputHealthCheck()
        shouldStopFeeding.withLock { $0 = true }
        let completedFeedState: StreamingFeedState?
        if let feedTask {
            completedFeedState = await feedTask.value
        } else {
            completedFeedState = aacArchive.map { StreamingFeedState(archive: $0) }
        }
        feedTask = nil
        guard var feedState = completedFeedState else {
            logger.error("Missing feed state while stopping streaming")
            clearState()
            return nil
        }
        audioMixer?.stopTrace()
        if microphoneSource.withLock({ $0.pendingDrops + ($0.buffer?.droppedSampleCount ?? 0) }) > 0 {
            hasTranscriptionGaps = true
            logger.error("Microphone capture lost samples before final drain")
            ErrorToastManager.shared.show("Some microphone audio was lost while recording was delayed.")
        }
        PipelineTrace.shared.log("STREAM", "feed loop stopped")

        let remainingSystemSamples: [Float]
        let systemSampleRate = SystemAudioService.shared.activeSampleRate
        if speakerCaptureActiveForSession {
            remainingSystemSamples = await SystemAudioService.shared.stopAndDrain()
        } else {
            remainingSystemSamples = []
        }

        let remainingSamples = ringBuffer.withLock { buffer -> [Float] in
            let drained = buffer
            buffer.removeAll()
            return drained
        } + drainMicrophoneSamples()

        if let mixer = audioMixer {
            let remaining16k = Self.makeFinalMixedSamples(
                mixer: mixer,
                microphone: remainingSamples,
                microphoneSampleRate: nativeSampleRate,
                system: remainingSystemSamples,
                systemSampleRate: systemSampleRate,
                speakerCaptureActive: speakerCaptureActiveForSession
            )
            if !remaining16k.isEmpty {
                if let session = streamingSession {
                    session.feedAudio(samples: remaining16k)
                }
                captureState.withLock { $0.recordSamplesCaptured(remaining16k.count) }
                if let error = feedState.append(remaining16k) {
                    logger.error("Failed to write final AAC chunk: \(error, privacy: .public)")
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

        let finalURL: URL?
        var archiveError = feedState.archive.failure
        switch feedState.archive.finalize() {
        case .success(let url):
            finalURL = url
        case .failure(let error):
            archiveError = error
            finalURL = nil
            logger.error("Failed to finalize AAC archive: \(error, privacy: .public)")
        }
        aacArchive = nil

        if !captureState.withLock({ $0.hasCapturedSamples }) {
            logger.error("No audio samples captured during streaming, discarding empty recording")
            if let url = finalURL {
                try? FileManager.default.removeItem(at: url)
            }
            ErrorToastManager.shared.show("No microphone audio received. Try recording again.")
            endCurrentTranscriptSession(elapsedMs: currentTranscriptElapsedMs())
            clearState()
            return nil
        }

        let elapsed = recordingStartTime.map { stoppedAt.timeIntervalSince($0) } ?? 0
        if recordingStartTime != nil, elapsed < 1.0 {
            logger.info("Recording too short (\(String(format: "%.1f", elapsed), privacy: .public)s), discarding")
            if let url = finalURL {
                try? FileManager.default.removeItem(at: url)
            }
            endCurrentTranscriptSession(elapsedMs: currentTranscriptElapsedMs())
            clearState()
            return nil
        }

        let finalText = confirmedText
        let timestamp = recordingStartTime ?? Date()
        guard let recordingID = currentRecordingID,
              let fileName = currentRecordingFileName else {
            if let url = finalURL {
                try? FileManager.default.removeItem(at: url)
            }
            logger.error("Missing recording identity while stopping streaming")
            endCurrentTranscriptSession(elapsedMs: currentTranscriptElapsedMs())
            clearState()
            return nil
        }
        endCurrentTranscriptSession(finalText: finalText, elapsedMs: currentTranscriptElapsedMs())
        confirmedText = ""
        provisionalText = ""
        transcriptDisplayUpdate = nil
        streamingSession = nil
        recordingStartTime = nil
        currentRecordingID = nil
        currentRecordingFileName = nil

        logger.info("Streaming stopped, M4A at: \(finalURL?.lastPathComponent ?? "nil", privacy: .public)")
        ringBuffer.withLock { $0.removeAll() }
        audioMixer = nil
        speakerCaptureActiveForSession = false
        PipelineTrace.shared.stop()
        return StreamingStopResult(
            text: finalText,
            url: finalURL,
            duration: elapsed,
            recordingID: recordingID,
            timestamp: timestamp,
            fileName: fileName,
            storageError: archiveError,
            retryBuffer: feedState.retryBuffer
        )
    }

    // MARK: - Cancel Streaming

    func cancelStreaming() async {
        if !isStreaming {
            abortPendingStart()
            return
        }
        defer {
            isStreaming = false
            resumeIdleMeteringIfNeeded()
            releaseEngineIfIdle()
        }

        captureIsRequested = false
        captureStartGate.cancelInFlight()
        captureRequestGeneration = nil
        microphoneInput?.pause()
        isCaptureReady = false
        stopRMSTimer()
        cancelInputHealthCheck()
        inputRecoveryAttempts = 0
        shouldStopFeeding.withLock { $0 = true }
        feedTask?.cancel()
        let completedFeedState: StreamingFeedState?
        if let feedTask {
            completedFeedState = await feedTask.value
        } else {
            completedFeedState = nil
        }
        feedTask = nil
        eventTask?.cancel()
        eventTask = nil

        streamingSession?.cancel()
        streamingSession = nil

        if speakerCaptureActiveForSession {
            _ = await SystemAudioService.shared.stopAndDrain()
        }
        speakerCaptureActiveForSession = false

        (completedFeedState?.archive ?? aacArchive)?.cancel()
        var retryBuffer = completedFeedState?.retryBuffer
        retryBuffer?.release()
        aacArchive = nil
        currentRecordingID = nil
        currentRecordingFileName = nil

        ringBuffer.withLock { $0.removeAll() }
        audioMixer = nil
        PipelineTrace.shared.stop()

        endCurrentTranscriptSession(elapsedMs: currentTranscriptElapsedMs())
        clearState()
    }

    // MARK: - Finalize Recording

    struct StreamingResult {
        let text: String
        let recording: Recording?
        var llmErrorMessage: String?
    }

    func finalizeRecording(
        duration: TimeInterval = 0,
        applyCorrection: Bool = true,
        forceLLM: Bool = false,
        onCorrectionStarted: () -> Void = {}
    ) async -> StreamingResult? {
        let saveCoordinator = RecordingSaveCoordinator.shared
        guard saveCoordinator.reserveSave() else { return nil }
        guard let result = await stopStreaming() else {
            saveCoordinator.releaseSaveReservation()
            return nil
        }

        // The authoritative duration is measured inside the streaming session
        // (start→stop), not the caller's wall-clock — the mini-recorder path never
        // passed one, which stored duration=0 and broke per-language stats. Prefer
        // the measured value; fall back to any caller-supplied duration.
        let resolvedDuration = Self.resolveDuration(measured: result.duration, caller: duration)

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

        var llmErrorMessage: String?
        if applyCorrection && LLMCorrectionService.willCorrect(forceEnabled: forceLLM) {
            onCorrectionStarted()
            let outcome = await LLMCorrectionService.shared.correct(text, forceEnabled: forceLLM)
            text = outcome.text
            llmErrorMessage = outcome.errorMessage
        }

        let captureOutcome = StreamingCaptureOutcome(
            text: text,
            duration: resolvedDuration,
            audioURL: result.url,
            storageError: result.storageError.map(RecordingStorageError.classify),
            retryBuffer: result.retryBuffer,
            recordingID: result.recordingID,
            timestamp: result.timestamp,
            fileName: result.fileName
        )

        let recording = await saveCoordinator.saveReserved(captureOutcome)

        return StreamingResult(
            text: text,
            recording: recording,
            llmErrorMessage: llmErrorMessage
        )
    }

    // MARK: - Event Handling

    private func handleTranscriptionEvent(_ event: TranscriptionEvent) {
        switch event {
        case .provisional(let text):
            provisionalText = text
            publishTranscriptDisplayUpdate()

        case .confirmed(let text):
            confirmedText = text
            publishTranscriptDisplayUpdate()

        case .displayUpdate(let confirmed, let provisional):
            confirmedText = confirmed
            provisionalText = provisional
            publishTranscriptDisplayUpdate()

        case .stats(let stats):
            if let gap = stats.recoveryGap {
                let fileName = currentRecordingFileName ?? "unknown"
                let details = "recording=\(fileName) start_seconds=\(gap.startSeconds) end_seconds=\(gap.endSeconds) reason=\(gap.reason)"
                logger.error("Transcription gap: \(details, privacy: .public)")
                PipelineTrace.shared.log("TRANSCRIPTION_GAP", details)
                if gap.reason != StreamingTranscriptionGap.audioEncoderUnavailableReason {
                    ErrorToastManager.shared.show("Transcription skipped \(gap.timeRange). Continuing; audio is still being saved.")
                } else if !hasReportedUnavailableEncoder {
                    hasReportedUnavailableEncoder = true
                    ErrorToastManager.shared.show("Transcription stopped: the audio encoder can't be loaded. Audio is still being saved. Restart the app to reload the model.")
                }
            }
            if AppPreferences.shared.debugMode {
                logger.debug(
                    "Stats: \(stats.tokensPerSecond, format: .fixed(precision: 1), privacy: .public) tok/s, \(stats.totalAudioSeconds, format: .fixed(precision: 1), privacy: .public)s audio, \(stats.peakMemoryGB, format: .fixed(precision: 2), privacy: .public) GB"
                )
            }

        case .ended(let fullText):
            let cleaned = Self.finalizedText(fullText, hasGaps: hasTranscriptionGaps)
            confirmedText = cleaned
            provisionalText = ""
            publishTranscriptDisplayUpdate()
            logger.info("Streaming ended, full text length: \(fullText.count, privacy: .public) → cleaned: \(cleaned.count, privacy: .public)")
        }

        recordTranscriptEvent(event, elapsedMs: currentTranscriptElapsedMs())
    }

    private func publishTranscriptDisplayUpdate() {
        var snapshot = LiveTranscriptSnapshot()
        snapshot.capture(confirmed: confirmedText, provisional: provisionalText)
        transcriptDisplayUpdate = snapshot
    }

    @discardableResult
    func beginTranscriptSession(startedAt: Date = Date()) -> String {
        hasTranscriptionGaps = false
        hasReportedUnavailableEncoder = false
        let sessionID = transcriptSessionStore.startSession(startedAt: startedAt)
        currentTranscriptSessionID = sessionID
        return sessionID
    }

    func endCurrentTranscriptSession(finalText: String? = nil, elapsedMs: Int? = nil, endedAt: Date = Date()) {
        guard let sessionID = currentTranscriptSessionID else { return }
        defer { currentTranscriptSessionID = nil }

        do {
            try transcriptSessionStore.endSession(
                sessionID: sessionID,
                finalText: finalText,
                elapsedMs: elapsedMs,
                endedAt: endedAt
            )
        } catch {
            logger.error("Failed to end transcript session: \(error.localizedDescription, privacy: .public)")
        }
    }

    func recordTranscriptEvent(_ event: TranscriptionEvent, elapsedMs: Int) {
        if case .stats(let stats) = event {
            hasTranscriptionGaps = hasTranscriptionGaps || !stats.isComplete
        }
        guard let sessionID = currentTranscriptSessionID else { return }

        do {
            switch event {
            case .provisional(let text):
                try transcriptSessionStore.recordDisplayUpdate(
                    sessionID: sessionID,
                    confirmedText: confirmedText,
                    provisionalText: text,
                    elapsedMs: elapsedMs
                )
            case .confirmed(let text):
                try transcriptSessionStore.recordDisplayUpdate(
                    sessionID: sessionID,
                    confirmedText: text,
                    provisionalText: provisionalText,
                    elapsedMs: elapsedMs
                )
            case .displayUpdate(let confirmed, let provisional):
                try transcriptSessionStore.recordDisplayUpdate(
                    sessionID: sessionID,
                    confirmedText: confirmed,
                    provisionalText: provisional,
                    elapsedMs: elapsedMs
                )
            case .stats:
                break
            case .ended(let fullText):
                endCurrentTranscriptSession(
                    finalText: Self.finalizedText(fullText, hasGaps: hasTranscriptionGaps),
                    elapsedMs: elapsedMs
                )
            }
        } catch {
            logger.error("Failed to record transcript event: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func currentTranscriptElapsedMs(now: Date = Date()) -> Int {
        guard let recordingStartTime else { return 0 }
        return Int(max(0, now.timeIntervalSince(recordingStartTime)) * 1_000)
    }

    // MARK: - Private Helpers

    nonisolated static func finalizedText(_ text: String, hasGaps: Bool) -> String {
        hasGaps ? text : RepetitionCleaner.clean(text)
    }

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
        hasTranscriptionGaps = false
        microphoneSource.withLock { $0.pendingDrops = 0 }
        hasReportedUnavailableEncoder = false
        confirmedText = ""
        provisionalText = ""
        transcriptDisplayUpdate = nil
        recordingStartTime = nil
        currentRecordingID = nil
        currentRecordingFileName = nil
        resetCaptureHealth()
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
        var isComplete: Bool = true
        var gaps: [StreamingTranscriptionGap] = []
    }

    var ringBufferSampleCount: Int {
        ringBuffer.withLock { $0.count } + microphoneSource.withLock { $0.buffer?.sampleCount ?? 0 }
    }

    var isAudioEngineInitialized: Bool {
        microphoneInput != nil
    }

    func clearRingBuffer() {
        ringBuffer.withLock { $0.removeAll() }
    }

    func writeRawSamplesToRingBuffer(_ samples: [Float], chunkDuration: Double) -> Int {
        let chunkSize = max(1, Int(chunkDuration * AudioSampleRates.transcription))
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
        repetitionRecoveryEnabled: Bool = true,
        onEvent: @escaping @Sendable (TranscriptionEvent) -> Void
    ) async throws -> FileInjectionResult {
        guard let model = TranscriptionService.shared.streamingModel else {
            throw StreamingAudioError.modelNotLoaded
        }

        let (_, audio) = try loadAudioArray(from: url, sampleRate: Int(AudioSampleRates.transcription))
        let samples = audio.asArray(Float.self)
        let audioDurationS = Double(samples.count) / AudioSampleRates.transcription

        let mappedLanguage = Self.mapLanguageCode(language)
        var config = StreamingConfig(language: mappedLanguage, temperature: temperature)
        config.repetitionRecoveryEnabled = repetitionRecoveryEnabled
        let session = StreamingInferenceSession(model: model, config: config, sourceSampleLimit: samples.count)

        shouldStopFeeding.withLock { $0 = false }

        let intermediateCount = OSAllocatedUnfairLock(initialState: 0)
        let collectedFinalText = OSAllocatedUnfairLock(initialState: "")
        let collectedConfirmedText = OSAllocatedUnfairLock(initialState: "")
        let isComplete = OSAllocatedUnfairLock(initialState: true)
        let gaps = OSAllocatedUnfairLock(initialState: [StreamingTranscriptionGap]())

        let eventTask = Task.detached {
            for await event in session.events {
                onEvent(event)
                switch event {
                case .displayUpdate(let confirmed, _):
                    intermediateCount.withLock { $0 += 1 }
                    collectedConfirmedText.withLock { $0 = confirmed }
                case .ended(let text):
                    collectedFinalText.withLock { $0 = text }
                case .stats(let stats):
                    isComplete.withLock { $0 = $0 && stats.isComplete }
                    if let gap = stats.recoveryGap {
                        gaps.withLock { $0.append(gap) }
                    }
                default:
                    break
                }
            }
        }

        let chunkSize = max(1, Int(chunkDuration * AudioSampleRates.transcription))
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
            audioDurationS: audioDurationS,
            isComplete: isComplete.withLock { $0 },
            gaps: gaps.withLock { $0 }
        )
    }
}

// MARK: - Errors

enum StreamingAudioError: LocalizedError {
    case modelNotLoaded
    case audioFormatCreationFailed
    case streamTimeout
    case engineInitFailed(failure: String)
    case startAborted

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "No transcription model loaded. Please wait for the model to finish loading."
        case .audioFormatCreationFailed:
            return "Failed to create the target audio format for streaming."
        case .streamTimeout:
            return "Stream simulation timed out waiting for completion."
        case .engineInitFailed(let failure):
            return failure
        case .startAborted:
            return nil
        }
    }

    static func shouldReportStartFailure(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if case .startAborted = error as? StreamingAudioError { return false }
        return true
    }
}
