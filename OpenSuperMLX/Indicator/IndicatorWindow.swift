import Cocoa
import Combine
import os.log
import SwiftUI

enum RecordingState {
    case idle
    case connecting
    case recording
    case decoding
    case correcting
    case busy
}

@MainActor
protocol IndicatorViewDelegate: AnyObject {
    
    func didFinishDecoding()
}

@MainActor
class IndicatorViewModel: ObservableObject {
    @Published var state: RecordingState = .idle
    @Published var isBlinking = false
    let recorder: AudioRecorder = .shared
    @Published var isVisible = false
    @Published private(set) var isStreamingMode = false
    var forceLLMCorrection: Bool = false
    
    var delegate: IndicatorViewDelegate?
    private var blinkTimer: Timer?
    private var hideTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private let logger = Logger(subsystem: "OpenSuperMLX", category: "IndicatorViewModel")
    
    private let recordingStore: RecordingStore
    private let transcriptionService: TranscriptionService
    private let transcriptionQueue: TranscriptionQueue
    private let streamingService = StreamingAudioService.shared
    private var correctionTask: Task<Void, Never>?
    private var decodingTask: Task<Void, Never>?

    // MARK: - Dual-Track State

    private var isDualTrackActive = false
    private var dualTrackOutputType: OutputType = .unknown
    private var dualTrackRecordingStart: Date?
    
    init() {
        self.recordingStore = RecordingStore.shared
        self.transcriptionService = TranscriptionService.shared
        self.transcriptionQueue = TranscriptionQueue.shared
        
        recorder.$isConnecting
            .receive(on: RunLoop.main)
            .sink { [weak self] isConnecting in
                guard let self = self, !self.isStreamingMode else { return }
                if isConnecting {
                    self.state = .connecting
                    self.stopBlinking()
                }
            }
            .store(in: &cancellables)
        
        recorder.$isRecording
            .receive(on: RunLoop.main)
            .sink { [weak self] isRecording in
                guard let self = self, !self.isStreamingMode else { return }
                if isRecording {
                    self.state = .recording
                    self.startBlinking()
                }
            }
            .store(in: &cancellables)
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
    
    func startRecording() {
        if isTranscriptionBusy {
            showBusyMessage()
            return
        }
        
        if AppPreferences.shared.useStreamingTranscription {
            isStreamingMode = true
            state = .recording
            startBlinking()

            let resolved = MicrophoneService.shared.resolveAudioSource()
            let useDualTrack = DualTrackDecision.shouldUseDualTrack(
                resolvedSource: resolved,
                hasScreenRecordingPermission: CGPreflightScreenCaptureAccess()
            )

            if useDualTrack {
                isDualTrackActive = true
                dualTrackOutputType = resolved.outputType
                dualTrackRecordingStart = Date()

                Task {
                    do {
                        try await streamingService.startDualTrackCapture(bundleID: resolved.bundleID)
                    } catch {
                        logger.error("Failed to start dual-track capture: \(error, privacy: .public)")
                        isDualTrackActive = false
                        state = .idle
                        isStreamingMode = false
                        stopBlinking()
                    }
                }
            } else {
                if resolved.mode == .dualTrack {
                    logger.warning("Screen Recording permission not granted, falling back to mic-only")
                }

                do {
                    try streamingService.startStreaming()
                } catch {
                    logger.error("Failed to start streaming: \(error, privacy: .public)")
                    state = .idle
                    isStreamingMode = false
                    stopBlinking()
                }
            }
        } else {
            isStreamingMode = false
            
            if MicrophoneService.shared.isActiveMicrophoneRequiresConnection() {
                state = .connecting
                stopBlinking()
            } else {
                state = .recording
                startBlinking()
            }
            
            Task.detached { [recorder] in
                recorder.startRecording()
            }
        }
    }
    
    func startDecoding() {
        guard state == .recording else {
            logger.warning("startDecoding() called but state is \(String(describing: self.state), privacy: .public), ignoring")
            return
        }
        stopBlinking()
        
        if isStreamingMode {
            state = .decoding

            let wasDualTrack = isDualTrackActive
            let outputType = dualTrackOutputType
            let recordingStart = dualTrackRecordingStart
            isDualTrackActive = false
            dualTrackRecordingStart = nil
            
            decodingTask = Task { [weak self] in
                guard let self = self else { return }

                var systemAudioURL: URL?
                if wasDualTrack {
                    systemAudioURL = await SystemAudioService.shared.stopCapture()
                }

                guard let result = await self.streamingService.finalizeRecording(applyCorrection: false) else {
                    self.state = .idle
                    self.isStreamingMode = false
                    self.delegate?.didFinishDecoding()
                    return
                }
                
                self.recordingStore.addRecording(result.recording)
                
                guard let finalText = await self.runLLMCorrectionIfNeeded(on: result.text) else {
                    self.isStreamingMode = false
                    self.delegate?.didFinishDecoding()
                    return
                }
                
                if finalText != result.text {
                    var updatedRecording = result.recording
                    updatedRecording.transcription = finalText
                    self.recordingStore.updateRecording(updatedRecording)
                }
                
                let micTextEmpty = finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

                if wasDualTrack && micTextEmpty {
                    let duration = recordingStart.map { Date().timeIntervalSince($0) } ?? 0
                    if DualTrackDecision.shouldProcessSystemAudio(
                        recordingDuration: duration,
                        systemAudioURL: systemAudioURL
                    ) {
                        let recordingId = result.recording.id
                        if let systemText = await self.transcriptionService.handleDualTrackCompletion(
                            systemAudioURL: systemAudioURL,
                            outputType: outputType,
                            micTranscription: finalText,
                            recordingId: recordingId
                        ) {
                            if let corrected = await self.runLLMCorrectionIfNeeded(on: systemText) {
                                self.insertText(corrected)
                                logger.info("Transcription result (system audio): \(corrected.prefix(100), privacy: .public)")
                            }
                        }
                    } else {
                        self.logger.info("Skipping system audio transcription (duration=\(duration, format: .fixed(precision: 1), privacy: .public)s, hasURL=\(systemAudioURL != nil, privacy: .public))")
                    }
                } else {
                    self.insertText(finalText)
                    logger.info("Transcription result: \(finalText.prefix(100), privacy: .public)")

                    if wasDualTrack {
                        let duration = recordingStart.map { Date().timeIntervalSince($0) } ?? 0
                        if DualTrackDecision.shouldProcessSystemAudio(
                            recordingDuration: duration,
                            systemAudioURL: systemAudioURL
                        ) {
                            let recordingId = result.recording.id
                            let micText = finalText
                            Task {
                                await self.transcriptionService.handleDualTrackCompletion(
                                    systemAudioURL: systemAudioURL,
                                    outputType: outputType,
                                    micTranscription: micText,
                                    recordingId: recordingId
                                )
                            }
                        } else {
                            self.logger.info("Skipping system audio transcription (duration=\(duration, format: .fixed(precision: 1), privacy: .public)s, hasURL=\(systemAudioURL != nil, privacy: .public))")
                        }
                    }
                }
                
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
            
            if let tempURL = recorder.stopRecording() {
                decodingTask = Task { [weak self] in
                    guard let self = self else { return }
                    
                    do {
                        let rawText = try await self.transcriptionService.transcribeAudio(url: tempURL, settings: Settings(), applyCorrection: false)
                        
                        guard let finalText = await self.runLLMCorrectionIfNeeded(on: rawText) else {
                            self.delegate?.didFinishDecoding()
                            return
                        }
                        
                        let timestamp = Date()
                        let fileName = "\(Int(timestamp.timeIntervalSince1970)).wav"
                        let recording = Recording(
                            id: UUID(), timestamp: timestamp, fileName: fileName,
                            transcription: finalText, duration: 0,
                            status: .completed, progress: 1.0, sourceFileURL: nil
                        )
                        
                        try self.recorder.moveTemporaryRecording(from: tempURL, to: recording.url)
                        self.recordingStore.addRecording(recording)
                        
                        self.insertText(finalText)
                    } catch {
                        logger.error("Error transcribing audio: \(error, privacy: .public)")
                        try? FileManager.default.removeItem(at: tempURL)
                    }
                    
                    self.delegate?.didFinishDecoding()
                }
            } else {
                logger.warning("No recording URL found after stopping recorder")
                self.delegate?.didFinishDecoding()
            }
        }
    }
    
    func insertText(_ text: String) {
        ClipboardUtil.insertText(text)
    }
    
    // MARK: - LLM Correction
    
    private func runLLMCorrectionIfNeeded(on text: String) async -> String? {
        guard AppPreferences.shared.llmCorrectionEnabled || forceLLMCorrection else {
            return text
        }
        
        state = .correcting
        var correctedText = text
        correctionTask = Task {
            let result = await LLMCorrectionService.shared.correctTranscription(text, forceEnabled: self.forceLLMCorrection)
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
        decodingTask?.cancel()
        decodingTask = nil
        correctionTask?.cancel()
        correctionTask = nil
    }
    
    private func startBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.isBlinking.toggle()
            }
        }
    }
    
    private func stopBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        isBlinking = false
    }

    func cleanup() {
        stopBlinking()
        hideTimer?.invalidate()
        hideTimer = nil
        cancelActiveTasks()
        if isDualTrackActive {
            Task { _ = await SystemAudioService.shared.stopCapture() }
            isDualTrackActive = false
            dualTrackRecordingStart = nil
        }
        if isStreamingMode {
            streamingService.cancelStreaming()
            isStreamingMode = false
        }
        cancellables.removeAll()
    }

    func cancelRecording() {
        hideTimer?.invalidate()
        hideTimer = nil
        cancelActiveTasks()
        if isDualTrackActive {
            Task { _ = await SystemAudioService.shared.stopCapture() }
            isDualTrackActive = false
            dualTrackRecordingStart = nil
        }
        if isStreamingMode {
            streamingService.cancelStreaming()
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

struct RecordingIndicator: View {
    let isBlinking: Bool
    
    var body: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [
                        Color.red.opacity(0.8),
                        Color.red
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 8, height: 8)
            .shadow(color: .red.opacity(0.5), radius: 4)
            .opacity(isBlinking ? 0.3 : 1.0)
            .animation(.easeInOut(duration: 0.4), value: isBlinking)
    }
}

struct IndicatorWindow: View {
    @ObservedObject var viewModel: IndicatorViewModel
    @Environment(\.colorScheme) private var colorScheme
    
    private var backgroundColor: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.24)
            : Color.white.opacity(0.24)
    }
    
    var body: some View {

        let rect = RoundedRectangle(cornerRadius: 24)
        
        VStack(spacing: 12) {
            switch viewModel.state {
            case .connecting:
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 24)
                    
                    Text("Connecting...")
                        .font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
            case .recording:
                HStack(spacing: 8) {
                    RecordingIndicator(isBlinking: viewModel.isBlinking)
                        .frame(width: 24)
                    
                    Text("Recording...")
                        .font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
            case .decoding:
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 24)
                    
                    Text("Transcribing...")
                        .font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
            case .correcting:
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 24)
                    
                    Text("Correcting...")
                        .font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
            case .busy:
                HStack(spacing: 8) {
                    Image(systemName: "hourglass")
                        .foregroundColor(.orange)
                        .frame(width: 24)
                    
                    Text("Processing...")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.orange)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
            case .idle:
                EmptyView()
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 36)
        .background {
            rect
                .fill(backgroundColor)
                .background {
                    rect
                        .fill(Material.thinMaterial)
                }
                .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 4)
        }
        .clipShape(rect)
        .frame(width: 200)
        .scaleEffect(viewModel.isVisible ? 1 : 0.5)
        .offset(y: viewModel.isVisible ? 0 : 20)
        .opacity(viewModel.isVisible ? 1 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: viewModel.isVisible)
        .onAppear {
            viewModel.isVisible = true
        }
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
