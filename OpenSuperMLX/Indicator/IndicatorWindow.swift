import AVFoundation
import Cocoa
import Combine
import os.log
import SwiftUI

enum RecordingState: Equatable {
    case idle
    case connecting
    case recording
    case decoding
    case correcting
    case busy

    var isCapturing: Bool { self == .connecting || self == .recording }
    var isProcessing: Bool { self == .decoding || self == .correcting }
    var hasRecordingSession: Bool { isCapturing || isProcessing }

    static func allowsCaptureStart(saveBlocked: Bool, busy: Bool) -> Bool {
        !saveBlocked && !busy
    }

    func afterCaptureReadiness(_ isReady: Bool) -> RecordingState {
        guard isCapturing else { return self }
        return isReady ? .recording : .connecting
    }

    func afterStartFailure(isCurrent: Bool) -> RecordingState? {
        guard isCurrent else { return nil }
        return isCapturing ? .idle : self
    }
}

@MainActor
protocol IndicatorViewDelegate: AnyObject {
    
    func didFinishDecoding()
}

@MainActor
class IndicatorViewModel: ObservableObject {
    static let levelHistoryCapacity = 22

    @Published var state: RecordingState = .idle
    @Published private(set) var levelHistory = [Float](repeating: 0, count: levelHistoryCapacity)
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var dictationCleanup: DictationCleanup = .raw
    @Published private(set) var isCommandMode = false
    private var commandSelection: PromptPresetService.Selection?
    let recorder: AudioRecorder = .shared
    @Published var isVisible = false
    @Published private(set) var isStreamingMode = false
    @Published private(set) var completedRecording: Recording?
    
    var delegate: IndicatorViewDelegate?
    private var levelTimer: Timer?
    private var hideTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private let logger = Logger(subsystem: "OpenSuperMLX", category: "IndicatorViewModel")
    
    private let transcriptionService: TranscriptionService
    private let transcriptionQueue: TranscriptionQueue
    private let streamingService = StreamingAudioService.shared
    private let saveCoordinator: RecordingSaveCoordinator
    private let recoveryPresenter: () -> Void
    private let textInserter: (String) -> Void
    private let commandRunner: @MainActor (String, PromptPresetService.Selection?) async -> PresetApplyOutcome
    private var correctionTask: Task<Void, Never>?
    private var decodingTask: Task<Void, Never>?
    private var startStreamingTask: Task<Void, Never>?
    private var startStreamingEpoch = 0
    private var micDisconnectObserver: NSObjectProtocol?

    init(
        saveCoordinator: RecordingSaveCoordinator? = nil,
        recoveryPresenter: (() -> Void)? = nil,
        textInserter: ((String) -> Void)? = nil,
        commandRunner: (@MainActor (String, PromptPresetService.Selection?) async -> PresetApplyOutcome)? = nil
    ) {
        self.transcriptionService = TranscriptionService.shared
        self.transcriptionQueue = TranscriptionQueue.shared
        self.saveCoordinator = saveCoordinator ?? .shared
        self.recoveryPresenter = recoveryPresenter ?? {
            RecordingRecoveryPanelController.shared.show()
        }
        self.textInserter = textInserter ?? { ClipboardUtil.insertText($0) }
        self.commandRunner = commandRunner ?? { await PromptPresetService.shared.applyInstruction($0, to: $1) }

        streamingService.$isCaptureReady
            .removeDuplicates()
            .sink { [weak self] ready in
                guard let self, self.isStreamingMode, self.state.isCapturing else { return }
                self.state = self.state.afterCaptureReadiness(ready)
                if ready { self.startLevelMetering() } else { self.stopLevelMetering() }
            }
            .store(in: &cancellables)
        
        recorder.$isConnecting
            .receive(on: RunLoop.main)
            .sink { [weak self] isConnecting in
                guard let self = self, !self.isStreamingMode else { return }
                if isConnecting {
                    self.state = .connecting
                    self.stopLevelMetering()
                }
            }
            .store(in: &cancellables)
        
        recorder.$isRecording
            .receive(on: RunLoop.main)
            .sink { [weak self] isRecording in
                guard let self = self, !self.isStreamingMode else { return }
                if isRecording {
                    self.state = .recording
                    self.startLevelMetering()
                }
            }
            .store(in: &cancellables)

        micDisconnectObserver = NotificationCenter.default.addObserver(
            forName: .microphoneDisconnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isStreamingMode, self.state == .recording else { return }
                self.logger.info("Microphone disconnected during streaming — finalizing recording")
                self.startDecoding(coolDownOnFinish: true)
                ErrorToastManager.shared.show("Microphone disconnected — recording saved")
            }
        }
    }
    
    var isTranscriptionBusy: Bool {
        transcriptionService.isTranscribing || transcriptionQueue.isProcessing || streamingService.isStreaming || state == .correcting
    }
    
    func showBusyMessage() {
        state = .busy
        
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.delegate?.didFinishDecoding()
            }
        }
    }
    
    var canStartRecording: Bool {
        RecordingState.allowsCaptureStart(
            saveBlocked: saveCoordinator.blocksNewRecording, busy: isTranscriptionBusy
        )
    }

    @discardableResult
    func startRecording() -> Bool {
        guard !saveCoordinator.blocksNewRecording else {
            recoveryPresenter()
            return false
        }
        if AppPreferences.shared.debugMode {
            let traceDir = FileManager.default.temporaryDirectory.appendingPathComponent("temp_recordings")
            try? FileManager.default.createDirectory(at: traceDir, withIntermediateDirectories: true)
            PipelineTrace.shared.start(directory: traceDir)
        }
        PipelineTrace.shared.log("UI", "IndicatorWindow.startRecording()")
        if isTranscriptionBusy {
            showBusyMessage()
            return false
        }
        dictationCleanup = isCommandMode ? .raw : .current

        if transcriptionService.usesStreamingTranscription {
            isStreamingMode = true
            state = streamingService.isCaptureReady ? .recording : .connecting
            if state == .recording { startLevelMetering() } else { stopLevelMetering() }

            startStreamingEpoch += 1
            let epoch = startStreamingEpoch
            startStreamingTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.streamingService.startStreaming()
                } catch {
                    guard let state = self.state.afterStartFailure(isCurrent: self.startStreamingEpoch == epoch) else { return }
                    if StreamingAudioError.shouldReportStartFailure(error) {
                        self.logger.error("Failed to start streaming: \(error, privacy: .public)")
                        ErrorToastManager.shared.show(error.localizedDescription)
                    }
                    self.state = state
                    self.isStreamingMode = false
                    self.stopLevelMetering()
                }
            }
        } else {
            isStreamingMode = false
            
            if MicrophoneService.shared.isActiveMicrophoneRequiresConnection() {
                state = .connecting
                stopLevelMetering()
            } else {
                state = .recording
                startLevelMetering()
            }
            
            Task.detached { [weak self, recorder] in
                guard !recorder.startRecording() else { return }
                await MainActor.run {
                    self?.state = .idle
                    self?.isStreamingMode = false
                    self?.stopLevelMetering()
                }
            }
        }
        return true
    }
    
    /// `coolDownOnFinish` is for the mic-disconnect path: the engine holds a dead
    /// device and must be released, but only after the finalize Task drained the ring
    /// buffer — tearing it down before that would drop the recording's tail audio.
    func startDecoding(coolDownOnFinish: Bool = false) {
        guard state.isCapturing else {
            logger.warning("startDecoding() called but state is \(String(describing: self.state), privacy: .public), ignoring")
            return
        }
        stopLevelMetering()

        if isStreamingMode {
            state = .decoding

            decodingTask = Task { [weak self] in
                guard let self = self else { return }
                defer {
                    if coolDownOnFinish {
                        self.streamingService.coolDown()
                    }
                }
                await self.awaitStartStreamingIfNeeded()

                guard let result = await self.streamingService.finalizeRecording(
                    applyCorrection: !self.isCommandMode,
                    cleanupPreset: self.dictationCleanup.preset,
                    onCorrectionStarted: { self.state = .correcting }
                ) else {
                    self.state = .idle
                    self.isStreamingMode = false
                    self.delegate?.didFinishDecoding()
                    return
                }
                guard !Task.isCancelled else { return }

                self.completedRecording = result.recording
                if result.recording == nil {
                    self.recoveryPresenter()
                }

                if let error = result.llmErrorMessage {
                    ErrorToastManager.shared.show(error)
                }

                await self.deliver(result.text)
                logger.info("Transcription result: \(result.text.prefix(100), privacy: .public)")

                self.isStreamingMode = false
                self.delegate?.didFinishDecoding()
            }
        } else {
            if isTranscriptionBusy {
                recorder.cancelRecording()
                showBusyMessage()
                return
            }
            
            state = .decoding
            
            decodingTask = Task { [weak self] in
                guard let self = self else { return }

                guard let tempURL = await self.recorder.stopRecording() else {
                    self.delegate?.didFinishDecoding()
                    return
                }
                guard self.saveCoordinator.reserveSave() else {
                    self.recoveryPresenter()
                    self.delegate?.didFinishDecoding()
                    return
                }
                    
                do {
                    let rawText = try await self.transcriptionService.transcribeAudio(url: tempURL, settings: Settings(), applyCorrection: false)

                    guard let finalText = await self.runLLMCorrectionIfNeeded(on: rawText) else {
                        self.saveCoordinator.releaseSaveReservation()
                        try? FileManager.default.removeItem(at: tempURL)
                        self.delegate?.didFinishDecoding()
                        return
                    }

                    let timestamp = Date()
                    let id = UUID()
                    let fileName = RecordingAudioFormat.makeFileName(
                        timestamp: timestamp,
                        id: id,
                        isTaken: { candidate in
                            FileManager.default.fileExists(
                                atPath: Recording.recordingsDirectory
                                    .appendingPathComponent(candidate).path
                            )
                        }
                    )
                    let request = EncodedRecordingSaveRequest(
                        text: finalText,
                        duration: (try? AVAudioPlayer(contentsOf: tempURL).duration) ?? 0,
                        audioURL: tempURL,
                        recordingID: id,
                        timestamp: timestamp,
                        fileName: fileName
                    )
                    await self.completeNonStreamingSave(request, finalText: finalText)
                } catch {
                    self.saveCoordinator.releaseSaveReservation()
                    logger.error("Error transcribing audio: \(error, privacy: .public)")
                    try? FileManager.default.removeItem(at: tempURL)
                }

                self.delegate?.didFinishDecoding()
            }
        }
    }
    
    var commandLabel: String? {
        guard isCommandMode else { return nil }
        return commandSelection?.isEmpty != false ? "New text" : "Edit selection"
    }

    func prepareCommand(selection: PromptPresetService.Selection?) {
        commandSelection = selection
        isCommandMode = true
    }

    func selectCleanup(_ choice: DictationCleanup) {
        guard !isCommandMode, state == .recording || state == .connecting else { return }
        choice.select()
        dictationCleanup = choice
    }

    func deliver(_ text: String) async {
        guard isCommandMode else {
            textInserter(text)
            return
        }
        state = .correcting
        let outcome = await commandRunner(text, commandSelection)
        if let message = outcome.toastMessage {
            ErrorToastManager.shared.show(message)
        }
    }

    func completeNonStreamingSave(
        _ request: EncodedRecordingSaveRequest,
        finalText: String
    ) async {
        let recording = await saveCoordinator.saveReservedEncodedRecording(request)
        guard !Task.isCancelled else { return }
        completedRecording = recording
        if recording == nil {
            recoveryPresenter()
        }
        await deliver(finalText)
    }
    
    // MARK: - LLM Correction
    
    private func runLLMCorrectionIfNeeded(on text: String) async -> String? {
        guard !isCommandMode, AppPreferences.shared.llmCorrectionEnabled else {
            return text
        }
        
        state = .correcting
        var correctedText = text
        correctionTask = Task {
            let result = await LLMCorrectionService.shared.correctTranscription(
                text,
                preset: self.dictationCleanup.preset
            )
            guard !Task.isCancelled else { return }
            correctedText = result
        }
        await correctionTask?.value
        correctionTask = nil
        
        guard !Task.isCancelled else { return nil }

        if let error = LLMCorrectionService.shared.lastErrorMessage {
            ErrorToastManager.shared.show(error)
        }

        return correctedText
    }
    
    // MARK: - Task Cleanup
    
    private func cancelActiveTasks() {
        startStreamingEpoch += 1
        startStreamingTask?.cancel()
        startStreamingTask = nil
        decodingTask?.cancel()
        decodingTask = nil
        correctionTask?.cancel()
        correctionTask = nil
    }

    private func awaitStartStreamingIfNeeded() async {
        if let startStreamingTask {
            await startStreamingTask.value
            self.startStreamingTask = nil
        }
    }

    nonisolated static func appendingLevel(_ level: Float, to history: [Float], capacity: Int) -> [Float] {
        Array((history + [level]).suffix(capacity))
    }

    nonisolated static func formatElapsed(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    private func startLevelMetering() {
        if recordingStartedAt == nil {
            recordingStartedAt = Date()
        }
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let level = self.isStreamingMode
                    ? self.streamingService.currentRMSLevel
                    : self.recorder.meteredLevel()
                self.levelHistory = Self.appendingLevel(
                    level,
                    to: self.levelHistory,
                    capacity: Self.levelHistoryCapacity
                )
            }
        }
    }

    private func stopLevelMetering() {
        levelTimer?.invalidate()
        levelTimer = nil
    }

    func cleanup() {
        stopLevelMetering()
        hideTimer?.invalidate()
        hideTimer = nil
        cancelActiveTasks()
        if isStreamingMode {
            streamingService.abortPendingStart()
            Task { await streamingService.cancelStreaming() }
            isStreamingMode = false
        }
        if let obs = micDisconnectObserver {
            NotificationCenter.default.removeObserver(obs)
            micDisconnectObserver = nil
        }
        cancellables.removeAll()
    }

    func cancelRecording() {
        hideTimer?.invalidate()
        hideTimer = nil
        cancelActiveTasks()
        streamingService.abortPendingStart()
        if isStreamingMode {
            Task { await streamingService.cancelStreaming() }
            isStreamingMode = false
        } else {
            recorder.cancelRecording()
        }
    }

    @MainActor
    func hideWithAnimation() async {
        await withCheckedContinuation { continuation in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                self.isVisible = false
            } completion: {
                continuation.resume()
            }
        }
    }
}

// MARK: - Indicator Views

struct PulsingRecordDot: View {
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.red.opacity(0.45))
                .scaleEffect(isPulsing ? 1 : 0.45)
                .opacity(isPulsing ? 0 : 1)
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .shadow(color: .red.opacity(0.7), radius: 4)
        }
        .frame(width: 18, height: 18)
        .onAppear {
            withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
                isPulsing = true
            }
        }
    }
}

struct HUDSpinner: View {
    @State private var isSpinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 14, height: 14)
            .rotationEffect(.degrees(isSpinning ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                    isSpinning = true
                }
            }
    }
}

struct LiveWaveform: View {
    let levels: [Float]

    private let barWidth: CGFloat = 3
    private let minHeight: CGFloat = 3
    private let maxHeight: CGFloat = 24

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(Color.white)
                    .frame(width: barWidth, height: barHeight(levels[i]))
            }
        }
        .frame(height: maxHeight)
        .animation(.easeOut(duration: 0.08), value: levels)
        // Older samples fade out on the left so the wave reads as scrolling.
        .mask(
            LinearGradient(
                colors: [.clear, .black.opacity(0.6), .black],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
    }

    private func barHeight(_ level: Float) -> CGFloat {
        minHeight + VUScale.amplitude(level) * (maxHeight - minHeight)
    }
}

struct CleanupChip: View {
    let selection: DictationCleanup
    let choices: [DictationCleanup]
    let onSelect: (DictationCleanup) -> Void

    var body: some View {
        Menu {
            ForEach(choices) { choice in
                Button {
                    onSelect(choice)
                } label: {
                    if choice == selection {
                        Label(choice.title, systemImage: "checkmark")
                    } else {
                        Text(choice.title)
                    }
                }
                if choice == .clean, choices.count > 2 {
                    Divider()
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selection.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(selection == .raw ? .white.opacity(0.65) : .white)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Capsule().fill(Color.white.opacity(0.14)))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(maxWidth: 100, alignment: .leading)
        .help("Cleanup applied when you stop recording")
    }
}

struct CommandChip: View {
    let title: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 10, weight: .semibold))
            Text(title)
                .lineLimit(1)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundColor(.white)
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(Capsule().fill(Color.purple.opacity(0.55)))
        .fixedSize()
        .help("Say what to do with the selection, then press the shortcut again")
    }
}

struct IndicatorWindow: View {
    @ObservedObject var viewModel: IndicatorViewModel

    var body: some View {
        let shape = Capsule()

        content
            .padding(.horizontal, 16)
            .frame(width: 340, height: 44)
            .background {
                shape
                    .fill(Color.black.opacity(0.78))
                    .background(.ultraThinMaterial, in: shape)
            }
            .overlay {
                shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
            }
            .clipShape(shape)
            .shadow(color: .black.opacity(0.3), radius: 14, x: 0, y: 6)
            .environment(\.colorScheme, .dark)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: viewModel.state)
            .scaleEffect(viewModel.isVisible ? 1 : 0.6)
            .offset(y: viewModel.isVisible ? 0 : 16)
            .opacity(viewModel.isVisible ? 1 : 0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: viewModel.isVisible)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                viewModel.isVisible = true
            }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .recording:
            HStack(spacing: 10) {
                PulsingRecordDot()
                if let commandLabel = viewModel.commandLabel {
                    CommandChip(title: commandLabel)
                } else {
                    CleanupChip(
                        selection: viewModel.dictationCleanup,
                        choices: DictationCleanup.choices(presets: PromptPresetStore.shared.presets),
                        onSelect: viewModel.selectCleanup
                    )
                }
                LiveWaveform(levels: viewModel.levelHistory)
                    .frame(maxWidth: .infinity)
                if let startedAt = viewModel.recordingStartedAt {
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text(IndicatorViewModel.formatElapsed(context.date.timeIntervalSince(startedAt)))
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                            .foregroundColor(.white.opacity(0.9))
                    }
                }
            }
            .transition(.opacity)

        case .connecting:
            statusRow("Connecting…")

        case .decoding:
            statusRow("Transcribing…")

        case .correcting:
            if viewModel.isCommandMode {
                statusRow("Applying instruction…")
            } else {
                statusRow(viewModel.dictationCleanup.preset.map { "Applying \($0.name)…" } ?? "Correcting…")
            }

        case .busy:
            HStack(spacing: 8) {
                Image(systemName: "hourglass")
                    .foregroundColor(.orange)
                Text("Still processing…")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.orange)
            }
            .transition(.opacity)

        case .idle:
            EmptyView()
        }
    }

    private func statusRow(_ title: String) -> some View {
        HStack(spacing: 10) {
            HUDSpinner()
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
        }
        .transition(.opacity)
    }
}

struct IndicatorWindowPreview: View {
    @StateObject private var recordingVM = IndicatorViewModel()

    @StateObject private var decodingVM = {
        let vm = IndicatorViewModel()
        vm.startDecoding()
        return vm
    }()
    
    var body: some View {
        VStack(spacing: 20) {
            IndicatorWindow(viewModel: recordingVM)
            IndicatorWindow(viewModel: decodingVM)
        }
        .padding()
        .frame(height: 200)
        .background(Color(.windowBackgroundColor))
    }
}

#Preview {
    IndicatorWindowPreview()
}
