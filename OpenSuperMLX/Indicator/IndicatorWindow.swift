import Cocoa
import Combine
import SwiftUI

enum RecordingState {
    case idle
    case connecting
    case recording
    case decoding
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
    @Published var recorder: AudioRecorder = .shared
    @Published var isVisible = false
    @Published private(set) var isStreamingMode = false
    var forceLLMCorrection: Bool = false
    
    var delegate: IndicatorViewDelegate?
    private var blinkTimer: Timer?
    private var hideTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    
    private let recordingStore: RecordingStore
    private let transcriptionService: TranscriptionService
    private let transcriptionQueue: TranscriptionQueue
    private let streamingService = StreamingAudioService.shared
    
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
        transcriptionService.isTranscribing || transcriptionQueue.isProcessing || streamingService.isStreaming
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
            
            Task {
                do {
                    try await streamingService.startStreaming()
                } catch {
                    print("Failed to start streaming: \(error)")
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
        stopBlinking()
        
        if isStreamingMode {
            state = .decoding
            
            Task { [weak self] in
                guard let self = self else { return }
                
                guard let result = await self.streamingService.finalizeRecording(forceLLM: self.forceLLMCorrection) else {
                    self.state = .idle
                    self.isStreamingMode = false
                    self.delegate?.didFinishDecoding()
                    return
                }
                
                self.recordingStore.addRecording(result.recording)
                self.insertText(result.text)
                print("Transcription result: \(result.text)")
                
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
                Task { [weak self] in
                    guard let self = self else { return }
                    
                    do {
                        print("start decoding...")
                        let text = try await self.transcriptionService.transcribeAudio(url: tempURL, settings: Settings(), forceLLM: self.forceLLMCorrection)
                        
                        let timestamp = Date()
                        let fileName = "\(Int(timestamp.timeIntervalSince1970)).wav"
                        let recording = Recording(
                            id: UUID(), timestamp: timestamp, fileName: fileName,
                            transcription: text, duration: 0,
                            status: .completed, progress: 1.0, sourceFileURL: nil
                        )
                        
                        try self.recorder.moveTemporaryRecording(from: tempURL, to: recording.url)
                        self.recordingStore.addRecording(recording)
                        
                        self.insertText(text)
                        print("Transcription result: \(text)")
                    } catch {
                        print("Error transcribing audio: \(error)")
                        try? FileManager.default.removeItem(at: tempURL)
                    }
                    
                    self.delegate?.didFinishDecoding()
                }
            } else {
                
                print("!!! Not found record url !!!")
                self.delegate?.didFinishDecoding()
            }
        }
    }
    
    func insertText(_ text: String) {
        ClipboardUtil.insertText(text)
    }
    
    private func startBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            // Update UI on the main thread
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
        if isStreamingMode {
            streamingService.cancelStreaming()
            isStreamingMode = false
        }
        cancellables.removeAll()
    }

    func cancelRecording() {
        hideTimer?.invalidate()
        hideTimer = nil
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
    @StateObject private var recordingVM = {
        let vm = IndicatorViewModel()
//        vm.startRecording()
        return vm
    }()
    
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
