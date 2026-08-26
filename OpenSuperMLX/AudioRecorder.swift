import AppKit
import AVFoundation
import CoreAudio
import Foundation
import os
import SwiftUI

protocol AudioRecordingBackend: AnyObject {
    var delegate: AVAudioRecorderDelegate? { get set }
    var isMeteringEnabled: Bool { get set }
    var callbackIdentity: ObjectIdentifier { get }
    func prepareToRecord() -> Bool
    func record() -> Bool
    func stop()
}

extension AVAudioRecorder: AudioRecordingBackend {
    var callbackIdentity: ObjectIdentifier { ObjectIdentifier(self) }
}

class AudioRecorder: NSObject, ObservableObject {
    private enum RecordingLifecycle {
        case idle
        case starting
        case recording
        case stopping
    }

    @Published var isRecording = false
    @Published var isPlaying = false
    @Published var currentlyPlayingURL: URL?
    @Published var canRecord = false
    @Published var isConnecting = false
    
    typealias RecorderFactory = (URL, [String: Any]) throws -> any AudioRecordingBackend

    private var audioRecorder: (any AudioRecordingBackend)?
    private var audioPlayer: AVAudioPlayer?
    private var notificationSound: NSSound?
    private let temporaryDirectory: URL
    private var currentRecordingURL: URL?
    private var notificationObserver: Any?
    private var microphoneChangeObserver: Any?
    private var connectionCheckTimer: DispatchSourceTimer?
    private let recorderFactory: RecorderFactory
    private let onSaveError: @Sendable () -> Void
    private let onStopWaiterRegistered: @Sendable (Int) -> Void
    private let completionLock = NSLock()
    private var lifecycle: RecordingLifecycle = .idle
    private var stopContinuations: [CheckedContinuation<URL?, Never>] = []
    private let logger = Logger(subsystem: "OpenSuperMLX", category: "AudioRecorder")

    // MARK: - Singleton Instance

    static let shared = AudioRecorder()
    
    override private init() {
        temporaryDirectory = Recording.pendingRecordingsDirectory
        recorderFactory = { url, settings in
            try AVAudioRecorder(url: url, settings: settings)
        }
        onSaveError = {
            Task { @MainActor in
                ErrorToastManager.shared.show("Recording could not be saved.")
            }
        }
        onStopWaiterRegistered = { _ in }
        
        super.init()
        createTemporaryDirectoryIfNeeded()
        setup()
    }

    init(
        temporaryDirectory: URL,
        recorderFactory: @escaping RecorderFactory,
        onSaveError: @escaping @Sendable () -> Void = {},
        onStopWaiterRegistered: @escaping @Sendable (Int) -> Void = { _ in },
        setupNotifications: Bool = false
    ) {
        self.temporaryDirectory = temporaryDirectory
        self.recorderFactory = recorderFactory
        self.onSaveError = onSaveError
        self.onStopWaiterRegistered = onStopWaiterRegistered
        super.init()
        createTemporaryDirectoryIfNeeded()
        if setupNotifications {
            setup()
        }
    }
    
    deinit {
        if let observer = notificationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = microphoneChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    private func setup() {
        updateCanRecordStatus()
        
        notificationObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasConnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateCanRecordStatus()
        }
        
        NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasDisconnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateCanRecordStatus()
        }
        
        microphoneChangeObserver = NotificationCenter.default.addObserver(
            forName: .microphoneDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateCanRecordStatus()
        }
    }
    
    private func updateCanRecordStatus() {
        canRecord = MicrophoneService.shared.getActiveMicrophone() != nil
    }
    
    private func createTemporaryDirectoryIfNeeded() {
        do {
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create temporary recordings directory: \(error, privacy: .public)")
        }
    }
    
    private func playNotificationSound() {
        // Try to play using NSSound first
        guard let soundURL = Bundle.main.url(forResource: "notification", withExtension: "mp3") else {
            logger.warning("Failed to find notification sound file")
            // Fall back to system sound if notification.mp3 is not found
            NSSound.beep()
            return
        }
        
        if let sound = NSSound(contentsOf: soundURL, byReference: false) {
            // Set maximum volume to ensure it's audible
            sound.volume = 0.3
            sound.play()
            notificationSound = sound
        } else {
            logger.warning("Failed to create NSSound from URL, falling back to system beep")
            // Fall back to system beep if NSSound creation fails
            NSSound.beep()
        }
    }
    
    @discardableResult
    func startRecording() -> Bool {
        PipelineTrace.shared.log("RECORDER", "AudioRecorder.startRecording() called")
        guard canRecord else {
            logger.warning("Cannot start recording - no audio input available")
            return false
        }
        guard reserveStart() else {
            logger.warning("Cannot start recording while another recording is active")
            return false
        }
        
        if AppPreferences.shared.playSoundOnRecordStart {
            playNotificationSound()
        }
        
        let timestamp = Date()
        let filename = RecordingAudioFormat.makeFileName(
            timestamp: timestamp,
            id: UUID(),
            isTaken: { candidate in
                FileManager.default.fileExists(
                    atPath: self.temporaryDirectory.appendingPathComponent(candidate).path
                )
            }
        )
        let fileURL = temporaryDirectory.appendingPathComponent(filename)
        logger.info("Starting recording to \(fileURL.lastPathComponent, privacy: .public)")
        
        #if os(macOS)
        if let activeMic = MicrophoneService.shared.activateForRecording() {
            logger.info("Set system default input to: \(activeMic.displayName, privacy: .public)")
        }
        #endif
        
        let requiresConnection = MicrophoneService.shared.isActiveMicrophoneRequiresConnection()
        updateRecordingState(isRecording: false, isConnecting: requiresConnection)
        return startReservedRecording(
            fileURL: fileURL,
            monitorConnection: requiresConnection
        )
    }
    
    @discardableResult
    func startRecordingWithRecorder(fileURL: URL, monitorConnection: Bool) -> Bool {
        guard reserveStart() else { return false }
        return startReservedRecording(fileURL: fileURL, monitorConnection: monitorConnection)
    }

    private func startReservedRecording(fileURL: URL, monitorConnection: Bool) -> Bool {
        do {
            let recorder = try recorderFactory(fileURL, RecordingAudioFormat.aacSettings)
            recorder.delegate = self
            recorder.isMeteringEnabled = monitorConnection
            guard recorder.prepareToRecord(), recorder.record() else {
                throw CocoaError(.fileWriteUnknown)
            }

            completionLock.lock()
            guard lifecycle == .starting else {
                completionLock.unlock()
                recorder.delegate = nil
                recorder.stop()
                try? FileManager.default.removeItem(at: fileURL)
                return false
            }
            lifecycle = .recording
            audioRecorder = recorder
            currentRecordingURL = fileURL
            completionLock.unlock()

            if monitorConnection {
                startConnectionMonitoring()
            } else {
                updateRecordingState(isRecording: true, isConnecting: false)
            }
            logger.info("Recording started successfully")
            return true
        } catch {
            logger.error("Failed to start recording: \(error, privacy: .public)")
            completionLock.lock()
            if lifecycle == .starting {
                lifecycle = .idle
            }
            completionLock.unlock()
            try? FileManager.default.removeItem(at: fileURL)
            updateRecordingState(isRecording: false, isConnecting: false)
            showSaveError()
            return false
        }
    }
    
    func stopRecording() async -> URL? {
        return await withCheckedContinuation { continuation in
            completionLock.lock()
            switch lifecycle {
            case .idle:
                completionLock.unlock()
                continuation.resume(returning: nil)
            case .starting:
                lifecycle = .idle
                completionLock.unlock()
                continuation.resume(returning: nil)
            case .recording:
                lifecycle = .stopping
                stopContinuations.append(continuation)
                let waiterCount = stopContinuations.count
                let recorder = audioRecorder
                completionLock.unlock()
                onStopWaiterRegistered(waiterCount)
                updateRecordingState(isRecording: false, isConnecting: false)
                stopConnectionMonitoring()
                recorder?.stop()
            case .stopping:
                stopContinuations.append(continuation)
                let waiterCount = stopContinuations.count
                completionLock.unlock()
                onStopWaiterRegistered(waiterCount)
            }
        }
    }
    
    func cancelRecording() {
        completionLock.lock()
        lifecycle = .idle
        let recorder = audioRecorder
        let url = currentRecordingURL
        let continuations = stopContinuations
        audioRecorder = nil
        currentRecordingURL = nil
        stopContinuations.removeAll()
        completionLock.unlock()

        recorder?.delegate = nil
        recorder?.stop()
        updateRecordingState(isRecording: false, isConnecting: false)
        stopConnectionMonitoring()
        continuations.forEach { $0.resume(returning: nil) }

        if let url {
            try? FileManager.default.removeItem(at: url)
        }
    }
    
    
    func moveTemporaryRecording(from tempURL: URL, to finalURL: URL) throws {

        let directory = finalURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        guard !FileManager.default.fileExists(atPath: finalURL.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try FileManager.default.moveItem(at: tempURL, to: finalURL)
    }
    
    func playRecording(url: URL) {
        // Stop current playback if any
        stopPlaying()
        
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.delegate = self
            audioPlayer?.play()
            isPlaying = true
            currentlyPlayingURL = url
        } catch {
            logger.error("Failed to play recording: \(error, privacy: .public), url: \(url, privacy: .public)")
            isPlaying = false
            currentlyPlayingURL = nil
        }
    }
    
    func stopPlaying() {
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        currentlyPlayingURL = nil
    }
    
    private func updateRecordingState(isRecording: Bool, isConnecting: Bool) {
        DispatchQueue.main.async {
            self.isRecording = isRecording
            self.isConnecting = isConnecting
        }
    }
    
    private func startConnectionMonitoring() {
        stopConnectionMonitoring()
        
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        timer.schedule(deadline: .now() + 0.05, repeating: 0.05)
        let initialFileSize = currentRecordingURL.flatMap {
            try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int64
        } ?? 0
        var growthCount = 0
        
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.completionLock.lock()
            let hasRecorder = self.audioRecorder != nil
            let url = self.currentRecordingURL
            self.completionLock.unlock()
            guard hasRecorder, let url else { return }
            
            let currentFileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            let totalGrowth = currentFileSize - initialFileSize
            
            if totalGrowth > 1000 {
                growthCount += 1
            }
            
            if growthCount >= 2 {
                self.stopConnectionMonitoring()
                self.updateRecordingState(isRecording: true, isConnecting: false)
            }
        }
        connectionCheckTimer = timer
        timer.resume()
    }
    
    private func stopConnectionMonitoring() {
        connectionCheckTimer?.cancel()
        connectionCheckTimer = nil
    }

    private func reserveStart() -> Bool {
        completionLock.lock()
        defer { completionLock.unlock() }
        guard lifecycle == .idle else { return false }
        lifecycle = .starting
        return true
    }

    private func finishRecording(
        recorderIdentity: ObjectIdentifier,
        successfully: Bool,
        error: Error? = nil
    ) {
        completionLock.lock()
        guard (lifecycle == .recording || lifecycle == .stopping),
              audioRecorder?.callbackIdentity == recorderIdentity else {
            completionLock.unlock()
            return
        }
        lifecycle = .idle
        let continuations = stopContinuations
        stopContinuations.removeAll()
        let resultURL = currentRecordingURL
        currentRecordingURL = nil
        audioRecorder = nil
        completionLock.unlock()

        updateRecordingState(isRecording: false, isConnecting: false)
        stopConnectionMonitoring()

        var finalURL = resultURL
        let duration = finalURL.flatMap { try? AVAudioPlayer(contentsOf: $0).duration }
        let isTooShort = duration.map { $0 < 1 } ?? true
        if !successfully || isTooShort {
            if let finalURL {
                try? FileManager.default.removeItem(at: finalURL)
            }
            finalURL = nil
        }

        continuations.forEach { $0.resume(returning: finalURL) }

        if let error {
            logger.error("Recording encoding failed: \(error, privacy: .public)")
            showSaveError()
        } else if !successfully {
            logger.error("Recording finished unsuccessfully")
            showSaveError()
        }
    }

    private func showSaveError() {
        onSaveError()
    }
}

extension AudioRecorder: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        finishRecording(
            recorderIdentity: ObjectIdentifier(recorder),
            successfully: flag
        )
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        finishRecording(
            recorderIdentity: ObjectIdentifier(recorder),
            successfully: false,
            error: error
        )
    }
}

extension AudioRecorder: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
        currentlyPlayingURL = nil
    }
}
