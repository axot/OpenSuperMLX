//
//  ContentView.swift
//  OpenSuperMLX
//
//  Created by user on 05.02.2025.
//

import AVFoundation
import Combine
import os
import SwiftUI
import UniformTypeIdentifiers

import KeyboardShortcuts

@MainActor
class ContentViewModel: ObservableObject {
    // MARK: - State

    @Published var state: RecordingState = .idle
    @Published var isBlinking = false
    let transcriptionService = TranscriptionService.shared
    let transcriptionQueue = TranscriptionQueue.shared
    let microphoneService = MicrophoneService.shared
    @Published var recordings: [Recording] = []
    @Published var totalCount = 0
    @Published var isLoadingMore = false
    @Published var canLoadMore = true
    @Published var recordingDuration: TimeInterval = 0
    @Published var shouldClearSearch = false
    @Published var streamingConfirmedText = ""
    @Published var currentRMSLevel: Float = 0
    @Published private(set) var isStreamingMode = false

    private let recorder: AudioRecorder = .shared
    private let recordingStore = RecordingStore.shared
    private let streamingService = StreamingAudioService.shared
    private let logger = Logger(subsystem: "OpenSuperMLX", category: "ContentView")
    private var currentPage = 0
    private let pageSize = 100
    private var currentSearchQuery = ""
    private var blinkTimer: Timer?
    private var recordingStartTime: Date?
    private var durationTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init() {
        recorder.$isConnecting
            .receive(on: RunLoop.main)
            .sink { [weak self] isConnecting in
                guard let self = self else { return }
                if isConnecting && !self.isProcessing {
                    self.state = .connecting
                    self.stopBlinking()
                    self.stopDurationTimer()
                    self.recordingDuration = 0
                }
            }
            .store(in: &cancellables)
        
        recorder.$isRecording
            .receive(on: RunLoop.main)
            .sink { [weak self] isRecording in
                guard let self = self, !self.isStreamingMode else { return }
                if isRecording && !self.isProcessing {
                    self.state = .recording
                    self.startBlinking()
                    self.startDurationTimerIfNeeded()
                } else if !isRecording && self.state == .recording {
                    self.state = .idle
                    self.stopBlinking()
                    self.stopDurationTimer()
                    self.recordingDuration = 0
                }
            }
            .store(in: &cancellables)
        
        streamingService.$confirmedText
            .receive(on: RunLoop.main)
            .sink { [weak self] text in
                self?.streamingConfirmedText = text
            }
            .store(in: &cancellables)

        streamingService.$currentRMSLevel
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] level in
                self?.currentRMSLevel = level
            }
            .store(in: &cancellables)

        transcriptionService.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Data Loading

    func loadInitialData() {
        currentSearchQuery = ""
        currentPage = 0
        canLoadMore = true
        recordings = []
        loadMore()
        refreshTotalCount()
    }

    func refreshTotalCount() {
        Task { [weak self] in
            guard let self else { return }
            let count = (try? await self.recordingStore.fetchRecordingsCount()) ?? 0
            await MainActor.run { self.totalCount = count }
        }
    }

    func loadMore() {
        guard !isLoadingMore && canLoadMore else { return }
        isLoadingMore = true
        
        let page = currentPage
        let limit = pageSize
        let query = currentSearchQuery
        let offset = page * limit

        Task {
            let newRecordings: [Recording]
            if query.isEmpty {
                newRecordings = try await recordingStore.fetchRecordings(limit: limit, offset: offset)
            } else {
                newRecordings = await recordingStore.searchRecordingsAsync(query: query, limit: limit, offset: offset)
            }

            await MainActor.run {
                defer {
                    self.isLoadingMore = false
                }

                guard self.currentSearchQuery == query else {
                    return
                }
                
                if page == 0 {
                    self.recordings = newRecordings
                } else {
                    self.recordings.append(contentsOf: newRecordings)
                }
                
                if newRecordings.count < limit {
                    self.canLoadMore = false
                } else {
                    self.currentPage += 1
                }
            }
        }
    }
    
    func search(query: String) {
        currentSearchQuery = query
        currentPage = 0
        canLoadMore = true
        recordings = []
        loadMore()
    }
    
    func handleProgressUpdate(id: UUID, transcription: String?, progress: Float, status: RecordingStatus, isRegeneration: Bool?) {
        if let index = recordings.firstIndex(where: { $0.id == id }) {
            if let transcription = transcription {
                recordings[index].transcription = transcription
            }
            recordings[index].progress = progress
            recordings[index].status = status
            if let isRegeneration = isRegeneration {
                recordings[index].isRegeneration = isRegeneration
            }
        }
    }
    
    func deleteRecording(_ recording: Recording) {
        recordingStore.deleteRecording(recording)
        if let index = recordings.firstIndex(where: { $0.id == recording.id }) {
            recordings.remove(at: index)
        }
        totalCount = max(0, totalCount - 1)
    }

    func deleteAllRecordings() {
        recordingStore.deleteAllRecordings()
        recordings.removeAll()
        totalCount = 0
    }

    // MARK: - Recording Control

    var isRecording: Bool {
        if isStreamingMode {
            return streamingService.isStreaming
        }
        return recorder.isRecording
    }

    var isTranscriptionBusy: Bool {
        transcriptionService.isTranscribing || transcriptionQueue.isProcessing || streamingService.isStreaming
    }

    var isProcessing: Bool {
        state == .decoding || state == .correcting
    }

    func startRecording() {
        if AppPreferences.shared.debugMode {
            let traceDir = FileManager.default.temporaryDirectory.appendingPathComponent("temp_recordings")
            try? FileManager.default.createDirectory(at: traceDir, withIntermediateDirectories: true)
            PipelineTrace.shared.start(directory: traceDir)
        }
        PipelineTrace.shared.log("UI", "ContentView.startRecording()")
        if isTranscriptionBusy {
            return
        }

        if AppPreferences.shared.useStreamingTranscription {
            isStreamingMode = true
            state = .recording
            startBlinking()
            recordingStartTime = Date()
            recordingDuration = 0
            startDurationTimerIfNeeded()
            
            do {
                try streamingService.startStreaming()
            } catch {
                logger.error("Failed to start streaming: \(error, privacy: .public)")
                state = .idle
                isStreamingMode = false
                stopBlinking()
                stopDurationTimer()
                recordingDuration = 0
            }
        } else {
            isStreamingMode = false
            
            if microphoneService.isActiveMicrophoneRequiresConnection() {
                state = .connecting
                stopBlinking()
                stopDurationTimer()
                recordingDuration = 0
            } else {
                state = .recording
                startBlinking()
                recordingStartTime = Date()
                recordingDuration = 0
                startDurationTimerIfNeeded()
            }
            
            Task.detached { [recorder] in
                recorder.startRecording()
            }
        }
    }

    func startDecoding() {
        state = .decoding
        stopBlinking()
        stopDurationTimer()
        
        IndicatorWindowManager.shared.hide()

        if isStreamingMode {
            Task { [weak self] in
                guard let self = self else { return }

                guard let result = await self.streamingService.finalizeRecording(duration: self.recordingDuration) else {
                    self.state = .idle
                    self.recordingDuration = 0
                    self.isStreamingMode = false
                    return
                }

                self.recordingStore.addRecording(result.recording)

                if !self.currentSearchQuery.isEmpty {
                    self.shouldClearSearch = true
                    self.currentSearchQuery = ""
                }
                self.recordings.insert(result.recording, at: 0)
                self.totalCount += 1

                if let error = LLMCorrectionService.shared.lastErrorMessage {
                    ErrorToastManager.shared.show(error)
                }

                logger.info("Transcription result: \(result.text.prefix(100), privacy: .public)")

                self.state = .idle
                self.recordingDuration = 0
                self.isStreamingMode = false
            }
        } else if let tempURL = recorder.stopRecording() {
            Task { [weak self] in
                guard let self = self else { return }

                do {
                    let text = try await self.transcriptionService.transcribeAudio(url: tempURL, settings: Settings())

                    let timestamp = Date()
                    let fileName = "\(Int(timestamp.timeIntervalSince1970)).wav"
                    let recording = Recording(
                        id: UUID(), timestamp: timestamp, fileName: fileName,
                        transcription: text, duration: self.recordingDuration,
                        status: .completed, progress: 1.0, sourceFileURL: nil
                    )

                    try self.recorder.moveTemporaryRecording(from: tempURL, to: recording.url)
                    self.recordingStore.addRecording(recording)

                    if !self.currentSearchQuery.isEmpty {
                        self.shouldClearSearch = true
                        self.currentSearchQuery = ""
                    }
                    self.recordings.insert(recording, at: 0)
                    self.totalCount += 1

                    if let error = LLMCorrectionService.shared.lastErrorMessage {
                        ErrorToastManager.shared.show(error)
                    }

                    logger.info("Transcription result: \(text.prefix(100), privacy: .public)")
                } catch {
                    logger.error("Error transcribing audio: \(error, privacy: .public)")
                    try? FileManager.default.removeItem(at: tempURL)
                }

                self.state = .idle
                self.recordingDuration = 0
            }
        } else {
            state = .idle
            recordingDuration = 0
        }
    }

    func cancelRecording() {
        if isStreamingMode {
            streamingService.cancelStreaming()
        }
        isStreamingMode = false
        state = .idle
        stopBlinking()
        stopDurationTimer()
        recordingDuration = 0
        streamingConfirmedText = ""
    }

    // MARK: - Private Helpers

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
        recordingStartTime = nil
    }
    
    private func startDurationTimerIfNeeded() {
        guard durationTimer == nil else { return }
        if recordingStartTime == nil {
            recordingStartTime = Date()
            recordingDuration = 0
        }
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let now = Date()
            Task { @MainActor in
                if let recordingStartTime = self.recordingStartTime {
                    self.recordingDuration = now.timeIntervalSince(recordingStartTime)
                }
            }
        }
        RunLoop.main.add(durationTimer!, forMode: .common)
    }

    private func startBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.isBlinking.toggle()
            }
        }
        RunLoop.main.add(blinkTimer!, forMode: .common)
    }

    private func stopBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        isBlinking = false
    }
}

struct ContentView: View {
    @StateObject private var viewModel = ContentViewModel()
    @StateObject private var permissionsManager = PermissionsManager()
    @StateObject private var statsViewModel = StatsViewModel()
    @State private var selectedTab: SidebarTab = .recordings
    @State private var showDeleteConfirmation = false

    private var isPermissionsGranted: Bool {
        permissionsManager.isMicrophonePermissionGranted
            && permissionsManager.isAccessibilityPermissionGranted
    }

    var body: some View {
        Group {
            if !isPermissionsGranted {
                PermissionsView(permissionsManager: permissionsManager)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(DesignTokens.bg)
            } else {
                SidebarLayout(
                    selectedTab: $selectedTab,
                    onDeleteAllTapped: {
                        if !viewModel.recordings.isEmpty {
                            showDeleteConfirmation = true
                        }
                    }
                ) {
                    switch selectedTab {
                    case .recordings:
                        RecordingsPane(viewModel: viewModel) {
                            if viewModel.totalCount > 0 {
                                showDeleteConfirmation = true
                            }
                        }
                    case .stats:
                        StatsView(viewModel: statsViewModel)
                    case .settings:
                        SettingsView(embedded: true)
                    }
                }
            }
        }
        .background(DesignTokens.bg)
        .onAppear {
            viewModel.loadInitialData()
            // Warm stats in the background so opening the Stats tab is instant.
            statsViewModel.loadIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: RecordingStore.recordingProgressDidUpdateNotification)) { notification in
            guard let userInfo = notification.userInfo,
                  let id = userInfo["id"] as? UUID,
                  let progress = userInfo["progress"] as? Float,
                  let status = userInfo["status"] as? RecordingStatus else { return }

            let transcription = userInfo["transcription"] as? String
            let isRegeneration = userInfo["isRegeneration"] as? Bool

            viewModel.handleProgressUpdate(
                id: id,
                transcription: transcription,
                progress: progress,
                status: status,
                isRegeneration: isRegeneration
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: RecordingStore.recordingsDidUpdateNotification)) { _ in
            viewModel.loadInitialData()
        }
        .overlay {
            if viewModel.transcriptionService.isLoading && isPermissionsGranted {
                ZStack {
                    Color.black.opacity(0.3)
                    VStack(spacing: 16) {
                        if let downloadProgress = viewModel.transcriptionService.downloadProgress,
                           downloadProgress > 0, downloadProgress < 1 {
                            ProgressView(value: downloadProgress)
                                .progressViewStyle(.linear)
                                .frame(width: 200)
                            Text("\(Int(downloadProgress * 100))%")
                                .foregroundColor(.white)
                                .font(.subheadline)
                            Text("Downloading Model...")
                                .foregroundColor(.white)
                                .font(.headline)
                        } else {
                            ProgressView()
                                .scaleEffect(1.5)
                            Text("Loading Model...")
                                .foregroundColor(.white)
                                .font(.headline)
                        }
                    }
                }
                .ignoresSafeArea()
            }
        }
        .fileDropHandler()
        .alert("Delete All Recordings", isPresented: $showDeleteConfirmation) {
            Button("Delete All", role: .destructive) {
                viewModel.deleteAllRecordings()
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete all recordings? This action cannot be undone.")
        }
    }
}

// MARK: - Recordings Pane

struct RecordingsPane: View {
    @ObservedObject var viewModel: ContentViewModel
    let onDeleteAll: () -> Void
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var searchTask: Task<Void, Never>? = nil
    @State private var searchHovered = false

    private var currentShortcutDescription: String {
        KeyboardShortcuts.getShortcut(for: .toggleRecord)?.description ?? ""
    }

    private var isRecordingState: Bool {
        viewModel.isRecording || viewModel.state == .recording || viewModel.isProcessing || viewModel.state == .connecting
    }

    private func performSearch(_ query: String) {
        searchTask?.cancel()
        if query.isEmpty {
            debouncedSearchText = ""
            viewModel.search(query: "")
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.debouncedSearchText = query
                viewModel.search(query: query)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if viewModel.recordings.isEmpty && debouncedSearchText.isEmpty {
                RecordingsEmptyState(shortcutDescription: currentShortcutDescription)
            } else {
                searchField
                recordingsList
            }
            dock
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignTokens.bg)
        .onChange(of: viewModel.shouldClearSearch) { _, shouldClear in
            if shouldClear {
                searchText = ""
                debouncedSearchText = ""
                searchTask?.cancel()
                viewModel.shouldClearSearch = false
            }
        }
    }

    private var header: some View {
        HStack {
            HStack(spacing: 8) {
                Text("Recordings")
                    .font(.system(size: 18, weight: .bold))
                    .tracking(DesignTokens.trackingTitle * 18)
                    .foregroundStyle(DesignTokens.txt)
                if viewModel.totalCount > 0 {
                    Text(viewModel.totalCount.formatted())
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(DesignTokens.txt3)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .contentColumn()
        .overlay(alignment: .bottom) {
            Rectangle().fill(DesignTokens.line2).frame(height: 1)
        }
    }

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(DesignTokens.txt3)
            TextField("Search transcriptions…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .onChange(of: searchText) { _, newValue in
                    performSearch(newValue)
                }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    debouncedSearchText = ""
                    searchTask?.cancel()
                    viewModel.search(query: "")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(DesignTokens.txt3)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.radiusSearch, style: .continuous)
                .fill(DesignTokens.surface2)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.radiusSearch, style: .continuous)
                        .stroke(searchHovered ? DesignTokens.lineHard : DesignTokens.line, lineWidth: 1)
                )
        )
        .onHover { searchHovered = $0 }
        .animation(.easeInOut(duration: 0.14), value: searchHovered)
        .padding(.horizontal, 22)
        .contentColumn()
        .padding(.top, 16)
        .padding(.bottom, 4)
    }

    private var recordingsList: some View {
        ScrollView(showsIndicators: false) {
            if viewModel.recordings.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 30))
                        .foregroundStyle(DesignTokens.txt3)
                        .padding(.top, 50)
                    Text("No results found")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DesignTokens.txt2)
                    Text("Try different search terms")
                        .font(.system(size: 12.5))
                        .foregroundStyle(DesignTokens.txt3)
                }
                .frame(maxWidth: .infinity)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(viewModel.recordings) { recording in
                        RecordingRow(
                            recording: recording,
                            searchQuery: debouncedSearchText,
                            isLast: recording.id == viewModel.recordings.last?.id,
                            onDelete: { viewModel.deleteRecording(recording) },
                            onRegenerate: {
                                Task { await TranscriptionQueue.shared.requeueRecording(recording) }
                            }
                        )
                        .id(recording.id)
                        .onAppear {
                            if recording.id == viewModel.recordings.last?.id {
                                viewModel.loadMore()
                            }
                        }
                    }
                    if viewModel.isLoadingMore {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 8)
                .padding(.bottom, 12)
                .contentColumn()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.recordings.count)
    }

    private var dock: some View {
        RecordingDock(
            isRecording: isRecordingState,
            isBusy: viewModel.isProcessing || viewModel.state == .connecting,
            shortcutDescription: currentShortcutDescription,
            level: viewModel.isStreamingMode ? viewModel.currentRMSLevel : 0,
            elapsed: viewModel.recordingDuration,
            text: viewModel.streamingConfirmedText,
            onRecord: { viewModel.startRecording() },
            onStop: { viewModel.startDecoding() }
        ) {
            HStack(spacing: 8) {
                MicrophonePickerIconView(microphoneService: viewModel.microphoneService)
                if viewModel.totalCount > 0 {
                    DockToolButton(systemName: "trash", help: "Delete all recordings", action: onDeleteAll)
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isRecordingState)
    }
}

// MARK: - Empty state

struct RecordingsEmptyState: View {
    let shortcutDescription: String

    var body: some View {
        VStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [DesignTokens.surface, DesignTokens.accSoft],
                        startPoint: .top, endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(DesignTokens.line, lineWidth: 1)
                )
                .frame(width: 60, height: 60)
                .overlay {
                    Image(systemName: "mic")
                        .font(.system(size: 26, weight: .regular))
                        .foregroundStyle(DesignTokens.txt3)
                }
                .padding(.bottom, 8)
            Text("No recordings yet")
                .font(.system(size: 17, weight: .bold))
                .tracking(-0.02 * 17)
                .foregroundStyle(DesignTokens.txt)
            Text("Hit the record button below, or press the shortcut from any app to capture your first transcription.")
                .font(.system(size: 13))
                .foregroundStyle(DesignTokens.txt2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            if !shortcutDescription.isEmpty {
                HStack(spacing: 8) {
                    KeyCap(shortcutDescription)
                    Text("anywhere")
                        .font(.system(size: 12))
                        .foregroundStyle(DesignTokens.txt2)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    Capsule().fill(DesignTokens.surface2)
                        .overlay(Capsule().stroke(DesignTokens.line, lineWidth: 1))
                )
                .padding(.top, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PermissionsView: View {
    @ObservedObject var permissionsManager: PermissionsManager

    var body: some View {
        VStack(spacing: 20) {
            Text("Required Permissions")
                .font(.title)
                .padding()

            PermissionRow(
                isGranted: permissionsManager.isMicrophonePermissionGranted,
                title: "Microphone Access",
                description: "Required for audio recording",
                action: {
                    permissionsManager.requestMicrophonePermissionOrOpenSystemPreferences()
                }
            )

            PermissionRow(
                isGranted: permissionsManager.isAccessibilityPermissionGranted,
                title: "Accessibility Access",
                description: "Required for global keyboard shortcuts",
                action: { permissionsManager.openSystemPreferences(for: .accessibility) }
            )

            Spacer()
        }
        .padding()
    }
}

struct PermissionRow: View {
    let isGranted: Bool
    let title: String
    let description: String
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: isGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(isGranted ? .green : .red)

                Text(title)
                    .font(.headline)

                Spacer()

                if !isGranted {
                    Button("Grant Access") {
                        action()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            Text(description)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(ThemePalette.panelSurface(colorScheme))
        .cornerRadius(10)
    }
}

struct RecordingRow: View {
    let recording: Recording
    let searchQuery: String
    let onDelete: () -> Void
    let onRegenerate: () -> Void
    let isLast: Bool
    @StateObject private var audioRecorder = AudioRecorder.shared
    @State private var isHovered = false
    @State private var didCopy = false

    init(recording: Recording, searchQuery: String, isLast: Bool = false,
         onDelete: @escaping () -> Void, onRegenerate: @escaping () -> Void) {
        self.recording = recording
        self.searchQuery = searchQuery
        self.isLast = isLast
        self.onDelete = onDelete
        self.onRegenerate = onRegenerate
    }

    private var isPlaying: Bool {
        audioRecorder.isPlaying && audioRecorder.currentlyPlayingURL == recording.url
    }

    private var isPending: Bool {
        recording.status == .pending || recording.status == .converting || recording.status == .transcribing
    }

    private var isRegenerating: Bool {
        recording.isRegeneration && isPending
    }

    private var statusText: String {
        switch recording.status {
        case .pending: return "In queue…"
        case .converting: return "Converting…"
        case .transcribing: return "Transcribing…"
        case .completed: return ""
        case .failed: return "Failed"
        }
    }

    private var displayText: String {
        if recording.transcription.isEmpty
            || recording.transcription == "Starting transcription..."
            || recording.transcription == "In queue..." {
            return ""
        }
        return recording.transcription
    }

    private var relativeDateText: String {
        Self.relativeDate(recording.timestamp)
    }

    private var durationText: String { StatsFormat.clock(recording.duration) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
            metadata
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.radiusSearch, style: .continuous)
                .fill(isHovered ? DesignTokens.surface3 : .clear)
        )
        .overlay(alignment: .bottom) {
            if !isLast && !isHovered {
                Rectangle().fill(DesignTokens.line2).frame(height: 1)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu { contextMenu }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        // LazyVStack recycles row view instances; when a recycled slot is reused
        // for a different recording its @State isHovered can carry a stale `true`,
        // painting a not-yet-hovered row gray on scroll. Clear it on identity change.
        .onChange(of: recording.id) { _, _ in
            isHovered = false
            didCopy = false
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if recording.status == .failed {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(DesignTokens.red)
                    Text("Transcription failed")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DesignTokens.red)
                }
                if !recording.transcription.isEmpty {
                    Text(recording.transcription)
                        .font(.system(size: 12))
                        .foregroundStyle(DesignTokens.txt3)
                }
            }
        } else if isPending && !isRegenerating {
            VStack(alignment: .leading, spacing: 4) {
                if let sourceFileName = recording.sourceFileName {
                    Text(sourceFileName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DesignTokens.txt)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                progressBadge
            }
        } else if !displayText.isEmpty {
            ZStack(alignment: .topLeading) {
                highlightedText
                    .font(.system(size: 13.5))
                    .foregroundStyle(DesignTokens.txt)
                    .lineSpacing(3)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isRegenerating {
                    ShimmerOverlay()
                        .transition(.opacity.animation(.easeInOut(duration: 0.3)))
                }
            }
        } else {
            Text("No speech detected")
                .font(.system(size: 13.5))
                .foregroundStyle(DesignTokens.txt3)
        }
    }

    private var progressBadge: some View {
        HStack(spacing: 6) {
            if recording.status == .pending {
                Image(systemName: "clock")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.txt3)
            } else {
                ZStack {
                    Circle().stroke(DesignTokens.line, lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: CGFloat(recording.progress))
                        .stroke(DesignTokens.txt3, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.1), value: recording.progress)
                }
                .frame(width: 14, height: 14)
                Text("\(Int(recording.progress * 100))%")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(DesignTokens.txt3)
                    .contentTransition(.numericText())
                    .animation(.linear(duration: 0.1), value: recording.progress)
            }
            Text(statusText)
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.txt3)
        }
    }

    // MARK: - Metadata row

    private var metadata: some View {
        HStack(spacing: 11) {
            if isRegenerating {
                progressBadge
            } else {
                Text(relativeDateText)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                Circle().fill(DesignTokens.txt4).frame(width: 3, height: 3)
                Text(durationText)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
            }
            Spacer(minLength: 8)
            // Fixed-size circular buttons fade in on hover so the row never reflows.
            HStack(spacing: 6) {
                Button(action: copyTranscription) {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: didCopy ? .semibold : .regular))
                        .foregroundStyle(didCopy ? DesignTokens.acc : DesignTokens.txt2)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(DesignTokens.accSoft))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .help("Copy text")
                .opacity(copyButtonVisible ? 1 : 0)
                .allowsHitTesting(copyButtonVisible)
                .animation(.easeInOut(duration: 0.12), value: copyButtonVisible)

                Button {
                    if isPlaying {
                        audioRecorder.stopPlaying()
                    } else {
                        audioRecorder.playRecording(url: recording.url)
                    }
                } label: {
                    Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(isPlaying ? DesignTokens.red : DesignTokens.acc)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(DesignTokens.accSoft))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .help(isPlaying ? "Stop" : "Play")
                .opacity(playButtonVisible ? 1 : 0)
                .allowsHitTesting(playButtonVisible)
                .animation(.easeInOut(duration: 0.12), value: playButtonVisible)
            }
        }
        .foregroundStyle(DesignTokens.txt3)
        .frame(height: 26)
        .padding(.top, 8)
    }

    private var playButtonVisible: Bool {
        (isHovered || isPlaying) && !isPending && recording.status != .failed
    }

    private var copyButtonVisible: Bool {
        isHovered && !isPending && recording.status != .failed && !displayText.isEmpty
    }

    private func copyTranscription() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(recording.transcription, forType: .string)
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            didCopy = false
        }
    }

    // MARK: - Context menu

    @ViewBuilder
    private var contextMenu: some View {
        if !isPending && recording.status != .failed {
            Button {
                if isPlaying { audioRecorder.stopPlaying() }
                else { audioRecorder.playRecording(url: recording.url) }
            } label: {
                Label(isPlaying ? "Stop" : "Play", systemImage: isPlaying ? "stop.fill" : "play.fill")
            }
            Button(action: copyTranscription) {
                Label("Copy text", systemImage: "doc.on.doc")
            }
        }
        if recording.status == .completed || recording.status == .failed {
            Button(action: onRegenerate) {
                Label("Regenerate", systemImage: "arrow.clockwise")
            }
        }
        if !isPending && recording.status != .failed {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([recording.url])
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
        }
        Divider()
        Button(role: .destructive) {
            if isPlaying { audioRecorder.stopPlaying() }
            onDelete()
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: - Search highlighting

    private var highlightedText: Text {
        guard !searchQuery.isEmpty else { return Text(displayText) }
        var attributed = AttributedString(displayText)
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var start = displayText.startIndex
        while let range = displayText.range(of: searchQuery, options: options, range: start..<displayText.endIndex) {
            if let attrRange = Range(range, in: attributed) {
                attributed[attrRange].backgroundColor = .yellow
                attributed[attrRange].foregroundColor = .black
            }
            start = range.upperBound
        }
        return Text(attributed)
    }

    // MARK: - Relative date

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d, HH:mm"
        return f
    }()

    static func relativeDate(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) {
            return "Today \(timeFormatter.string(from: date))"
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday \(timeFormatter.string(from: date))"
        }
        return dateTimeFormatter.string(from: date)
    }
}

struct ShimmerOverlay: View {
    @State private var phase: CGFloat = 0
    
    var body: some View {
        GeometryReader { geometry in
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            LinearGradient(
                                gradient: Gradient(colors: [
                                    Color.clear,
                                    Color.white.opacity(0.4),
                                    Color.clear
                                ]),
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .offset(x: -geometry.size.width + (phase * geometry.size.width * 2))
                )
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .onAppear {
            withAnimation(
                .linear(duration: 1.2)
                .repeatForever(autoreverses: false)
            ) {
                phase = 1
            }
        }
    }
}

struct MicrophonePickerIconView: View {
    @ObservedObject var microphoneService: MicrophoneService
    @ObservedObject private var streamingService = StreamingAudioService.shared
    @StateObject private var permissionsManager = PermissionsManager()
    @State private var showMenu = false
    @State private var classificationsTick: Int = 0
    @Environment(\.colorScheme) private var colorScheme

    private var builtInMicrophones: [MicrophoneService.AudioDevice] {
        microphoneService.availableMicrophones.filter { $0.isBuiltIn }
    }

    private var externalMicrophones: [MicrophoneService.AudioDevice] {
        microphoneService.availableMicrophones.filter { !$0.isBuiltIn }
    }

    private var currentOutputClassification: DeviceClassification? {
        _ = classificationsTick // depend on the tick so SwiftUI re-evaluates after a flip
        return MicrophoneService.shared.getCurrentOutputUID()
            .flatMap { OutputDeviceClassifier.shared.classification(for: $0) }
    }

    private var speakerToggleTitle: String {
        if currentOutputClassification == .speaker {
            return "Audio Output (unavailable on speaker)"
        }
        return "Audio Output"
    }

    private var recentDevices: [(uid: String, entry: ClassificationEntry)] {
        _ = classificationsTick
        return OutputDeviceClassifier.shared.recentDevices(limit: 3)
    }

    private var currentOutputUID: String? {
        _ = classificationsTick
        return MicrophoneService.shared.getCurrentOutputUID()
    }
    
    var body: some View {
        Button(action: { showMenu.toggle() }) {
            Image(systemName: microphoneService.availableMicrophones.isEmpty ? "mic.slash" : "mic.fill")
                .font(.system(size: 14))
                .foregroundStyle(showMenu ? DesignTokens.accOn : DesignTokens.txt2)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.radiusNav, style: .continuous)
                        .fill(showMenu ? DesignTokens.acc : DesignTokens.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignTokens.radiusNav, style: .continuous)
                                .stroke(showMenu ? DesignTokens.acc : DesignTokens.line, lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
                )
        }
        .buttonStyle(.plain)
        .help(microphoneService.currentMicrophone?.displayName ?? "Select microphone")
        .popover(isPresented: $showMenu, arrowEdge: .top) {
            popoverContent
                .frame(width: 286)
                .background(DesignTokens.bg)
                .onAppear { streamingService.startIdleMetering() }
                .onDisappear { streamingService.stopIdleMetering() }
                .onReceive(NotificationCenter.default.publisher(for: .outputDeviceClassificationDidChange)) { _ in
                    classificationsTick &+= 1
                }
                .onReceive(NotificationCenter.default.publisher(for: .outputDeviceDidChange)) { _ in
                    classificationsTick &+= 1
                }
        }
    }

    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            popoverSectionLabel("Microphone")
            if microphoneService.availableMicrophones.isEmpty {
                Text("No microphones available")
                    .font(.system(size: 13))
                    .foregroundStyle(DesignTokens.txt3)
                    .padding(.horizontal, 10).padding(.vertical, 8)
            } else {
                ForEach(microphoneService.availableMicrophones) { microphone in
                    let isCurrent = microphoneService.currentMicrophone?.id == microphone.id
                    Button(action: {
                        microphoneService.selectMicrophone(microphone)
                        showMenu = false
                    }) {
                        HStack(spacing: 10) {
                            Image(systemName: microphone.isBuiltIn ? "laptopcomputer" : "mic")
                                .font(.system(size: 13))
                                .foregroundStyle(DesignTokens.txt3)
                                .frame(width: 18, alignment: .center)
                            Text(microphone.displayName)
                                .font(.system(size: 13))
                                .foregroundStyle(DesignTokens.txt)
                                .lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 4)
                            if isCurrent {
                                PopoverVU(level: streamingService.currentRMSLevel)
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(DesignTokens.acc)
                            }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PopoverRowButtonStyle())
                }
            }

            if !recentDevices.isEmpty {
                popoverDivider
                popoverSectionLabel("Audio Output")
                ForEach(recentDevices, id: \.uid) { item in
                    let displayName = item.entry.displayName.isEmpty
                        ? fallbackDisplayName(forUID: item.uid) : item.entry.displayName
                    HStack(spacing: 10) {
                        Image(systemName: item.entry.classification == .headphone ? "headphones" : "speaker.wave.2")
                            .font(.system(size: 13))
                            .foregroundStyle(DesignTokens.txt3)
                            .frame(width: 18, alignment: .center)
                        Text(displayName)
                            .font(.system(size: 13))
                            .foregroundStyle(DesignTokens.txt2)
                            .lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 4)
                        if item.uid == currentOutputUID {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11))
                                .foregroundStyle(DesignTokens.txt3)
                        }
                        Button(action: {
                            let newClassification: DeviceClassification =
                                (item.entry.classification == .headphone) ? .speaker : .headphone
                            OutputDeviceClassifier.shared.set(newClassification, for: item.uid, displayName: item.entry.displayName)
                            if item.uid == currentOutputUID {
                                StreamingAudioService.shared.applyClassificationChange()
                            }
                            classificationsTick &+= 1
                        }) {
                            Text(item.entry.classification == .headphone ? "Headphone" : "Speaker")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(DesignTokens.txt2)
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 6).fill(DesignTokens.surface3)
                                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(DesignTokens.line, lineWidth: 1))
                                )
                        }
                        .buttonStyle(.plain)
                        .help("Click to flip classification")
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                }
            }

            popoverDivider

            Button(action: {
                microphoneService.speakerCaptureEnabled.toggle()
                if microphoneService.speakerCaptureEnabled && !permissionsManager.isScreenRecordingPermissionGranted {
                    permissionsManager.requestScreenRecordingPermission()
                }
            }) {
                HStack(spacing: 10) {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 13))
                        .foregroundStyle(DesignTokens.txt3)
                        .frame(width: 18, alignment: .center)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("System Audio").font(.system(size: 13)).foregroundStyle(DesignTokens.txt)
                        Text("Capture app audio output").font(.system(size: 11)).foregroundStyle(DesignTokens.txt3)
                    }
                    Spacer(minLength: 4)
                    // Display-only: the enclosing Button is the sole mutation path
                    // (the toggle is non-interactive), so the binding just reflects state.
                    DesignToggle(isOn: .constant(microphoneService.effectiveSpeakerCaptureActive))
                        .allowsHitTesting(false)
                }
                .padding(.horizontal, 10).padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(PopoverRowButtonStyle())
            .help(currentOutputClassification == .speaker ? "Unavailable on speaker output" : "Capture system audio output")
        }
        .padding(6)
    }

    private func popoverSectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold))
            .tracking(0.07 * 10)
            .foregroundStyle(DesignTokens.txt3)
            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 5)
    }

    private var popoverDivider: some View {
        Rectangle().fill(DesignTokens.line2).frame(height: 1).padding(.horizontal, 8).padding(.vertical, 5)
    }
}

// MARK: - Popover row button style

private struct PopoverRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.isPressed ? DesignTokens.accSoft : .clear)
            )
            .contentShape(Rectangle())
    }
}

// MARK: - Popover VU (4-bar live meter for the selected mic)

/// Four-bar meter beside the selected microphone, driven by the real mic RMS
/// (`StreamingAudioService.currentRMSLevel`, fed by idle metering while the popover
/// is open or by streaming). Per-bar staggered response gives organic motion
/// without faking the amplitude.
struct PopoverVU: View {
    /// Real RMS in [0, 1].
    let level: Float

    private let maxH: CGFloat = 14
    private let minH: CGFloat = 3
    private let ratios: [CGFloat] = [0.55, 1.0, 0.75, 0.45]

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(0..<4, id: \.self) { i in
                Capsule()
                    .fill(DesignTokens.acc)
                    .frame(width: 3, height: barHeight(i))
                    .animation(.easeOut(duration: 0.1), value: level)
            }
        }
        .frame(width: 21, height: maxH)
    }

    private func barHeight(_ i: Int) -> CGFloat {
        let amp = VUScale.amplitude(level)
        return minH + amp * (maxH - minH) * ratios[i]
    }
}


enum ThemePalette {
    static func panelSurface(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.gray.opacity(0.1)
            : Color(red: 0.95, green: 0.96, blue: 0.98)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
