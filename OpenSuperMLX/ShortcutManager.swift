import AppKit
import ApplicationServices
import Cocoa
import Foundation
import KeyboardShortcuts
import os.log
import SwiftUI

private let logger = Logger(subsystem: "OpenSuperMLX", category: "ShortcutManager")

extension KeyboardShortcuts.Name {
    static let toggleRecord = Self("toggleRecord", initial: .init(.backtick, modifiers: .option))
    static let voiceCommand = Self("voiceCommand", initial: .init(.backtick, modifiers: [.option, .shift]))
    static let escape = Self("escape", initial: .init(.escape))
}

@MainActor
class ShortcutManager {
    static let shared = ShortcutManager()

    private var activeVm: IndicatorViewModel?
    private var captureStartPending = false {
        didSet {
            RecordingActivity.shared.report(self, isActive: captureStartPending)
            refreshEscapeShortcut()
        }
    }
    private var captureStartEpoch = 0
    private var holdWorkItem: DispatchWorkItem?
    private let holdThreshold: TimeInterval = 0.3
    private var holdMode = false
    private var commandCapture = CommandCaptureGate()
    @MainActor private var escapeState = EscapeShortcutState()
    @MainActor private var escapeReleaseTask: Task<Void, Never>?
    private var escapeMonitor: Any?
    private var applicationObservers: [NSObjectProtocol] = []
    private var presetObserver: NSObjectProtocol?
    private var registeredPresetIDs: Set<UUID> = []

    @MainActor var transcriptInspectorVisible: Bool {
        get { escapeState.inspectorVisible }
        set {
            escapeState.inspectorVisible = newValue
            refreshEscapeShortcut()
        }
    }

    @MainActor var indicatorVisible: Bool {
        get { escapeState.indicatorVisible }
        set {
            escapeState.indicatorVisible = newValue
            refreshEscapeShortcut()
        }
    }

    private init() {
        print("ShortcutManager init")
        
        setupKeyboardShortcuts()
        setupEscapeOwnership()
        setupPresetShortcuts()
        releaseVoiceCommandIfTaken()
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(indicatorWindowDidHide),
            name: .indicatorWindowDidHide,
            object: nil
        )
    }
    
    @objc private func indicatorWindowDidHide() {
        activeVm = nil
        holdMode = false
    }
    
    private func setupKeyboardShortcuts() {
        KeyboardShortcuts.onKeyDown(for: .toggleRecord) { [weak self] in
            self?.handleKeyDown()
        }

        KeyboardShortcuts.onKeyUp(for: .toggleRecord) { [weak self] in
            self?.handleKeyUp()
        }

        KeyboardShortcuts.onKeyDown(for: .voiceCommand) { [weak self] in
            self?.handleKeyDown(command: true)
        }

        KeyboardShortcuts.onKeyUp(for: .voiceCommand) { [weak self] in
            self?.handleKeyUp()
        }

        KeyboardShortcuts.onKeyUp(for: .escape) { [weak self] in
            Task { @MainActor in
                if self?.captureStartPending == true {
                    self?.captureStartEpoch += 1
                    self?.captureStartPending = false
                    StreamingAudioService.shared.abortPendingStart()
                }
                if self?.activeVm != nil {
                    IndicatorWindowManager.shared.stopForce()
                    self?.activeVm = nil
                }
            }
        }
        KeyboardShortcuts.disable(.escape)
    }

    private func setupPresetShortcuts() {
        presetObserver = NotificationCenter.default.addObserver(
            forName: .promptPresetsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncPresetShortcuts() }
        }
        syncPresetShortcuts()
    }

    private func syncPresetShortcuts() {
        let presets = PromptPresetStore.shared.presets
        let currentIDs = Set(presets.map(\.id))

        for id in registeredPresetIDs.subtracting(currentIDs) {
            let name = PromptPreset.shortcutName(for: id)
            KeyboardShortcuts.removeHandler(for: name)
            KeyboardShortcuts.setShortcut(nil, for: name)
        }

        for preset in presets {
            let name = preset.shortcutName
            KeyboardShortcuts.removeHandler(for: name)
            KeyboardShortcuts.onKeyDown(for: name) { [weak self] in
                Task { @MainActor in
                    self?.runPreset(id: preset.id)
                }
            }
        }

        registeredPresetIDs = currentIDs
    }

    /// The voice command's default can match a key the user already gave to recording or
    /// a preset before the command existed. Those bindings were chosen; the default yields.
    private func releaseVoiceCommandIfTaken() {
        let others = [KeyboardShortcuts.getShortcut(for: .toggleRecord)]
            + PromptPresetStore.shared.presets.map { KeyboardShortcuts.getShortcut(for: $0.shortcutName) }
        guard Self.shortcutCollides(KeyboardShortcuts.getShortcut(for: .voiceCommand), with: others) else { return }
        KeyboardShortcuts.setShortcut(nil, for: .voiceCommand)
        logger.info("Cleared the voice command shortcut; its key is already bound")
    }

    private func runPreset(id: UUID) {
        guard let preset = PromptPresetStore.shared.presets.first(where: { $0.id == id }) else { return }
        Task {
            let outcome = await PromptPresetService.shared.apply(preset)
            if let message = outcome.toastMessage {
                ErrorToastManager.shared.show(message)
            }
        }
    }

    private func setupEscapeOwnership() {
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            applicationObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshEscapeShortcut() }
            })
        }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.escapeState.escapeIsDown = event.type == .keyDown
                self.escapeReleaseTask?.cancel()
                if self.escapeState.escapeIsDown {
                    self.escapeReleaseTask = Task { @MainActor [weak self] in
                        repeat {
                            do { try await Task.sleep(nanoseconds: 50_000_000) }
                            catch { return }
                        } while CGEventSource.keyState(.combinedSessionState, key: 53)
                        self?.escapeState.escapeIsDown = false
                        self?.refreshEscapeShortcut()
                    }
                }
                self.refreshEscapeShortcut()
            }
            return event
        }
    }

    @MainActor private func refreshEscapeShortcut() {
        escapeState.applicationActive = NSApp.isActive
        var state = escapeState
        state.indicatorVisible = state.indicatorVisible || captureStartPending
        if state.shouldRegisterGlobalEscape {
            KeyboardShortcuts.enable(.escape)
        } else {
            KeyboardShortcuts.disable(.escape)
        }
    }
    
    private func handleKeyDown(command: Bool = false) {
        let requestedAt = DispatchTime.now().uptimeNanoseconds
        holdWorkItem?.cancel()
        holdMode = false
        
        Task { @MainActor in
            if self.activeVm == nil {
                guard !self.commandCapture.isCapturing else {
                    // A second press while the selection is still being read means "stop".
                    if command { _ = self.commandCapture.requestStop() }
                    return
                }
                if self.captureStartPending {
                    self.captureStartEpoch += 1
                    self.captureStartPending = false
                    StreamingAudioService.shared.abortPendingStart()
                    return
                }
                self.captureStartEpoch += 1
                let epoch = self.captureStartEpoch
                self.captureStartPending = true
                defer {
                    if self.captureStartEpoch == epoch { self.captureStartPending = false }
                }
                var commandSelection: PromptPresetService.Selection?
                if command {
                    _ = self.commandCapture.begin()
                    let capture = await PromptPresetService.shared.captureCommandSelection(
                        shortcutModifiers: KeyboardShortcuts.getShortcut(for: .voiceCommand)?.modifiers ?? []
                    )
                    guard self.commandCapture.finish(), self.captureStartEpoch == epoch else { return }
                    switch capture {
                    case .success(let selection):
                        commandSelection = selection
                    case .failure(let error):
                        ErrorToastManager.shared.show(error.message)
                        return
                    }
                }
                IndicatorWindowManager.shared.releasePreviousViewModel()
                let vm = IndicatorViewModel()
                if command { vm.prepareCommand(selection: commandSelection) }
                var openedCaptureGeneration: Int?
                if vm.canStartRecording && TranscriptionService.shared.usesStreamingTranscription {
                    do {
                        openedCaptureGeneration = try await StreamingAudioService.shared.beginMicrophoneCapture(requestedAt: requestedAt)
                    } catch {
                        if self.captureStartEpoch == epoch {
                            if StreamingAudioError.shouldReportStartFailure(error) {
                                ErrorToastManager.shared.show(error.localizedDescription)
                            }
                        }
                        vm.cleanup()
                        return
                    }
                }
                guard self.captureStartEpoch == epoch else {
                    vm.cleanup()
                    return
                }
                let cursorPosition = FocusUtils.getCurrentCursorPosition()
                _ = IndicatorWindowManager.shared.show(onScreenContaining: cursorPosition, viewModel: vm)
                if !vm.startRecording(), let openedCaptureGeneration {
                    StreamingAudioService.shared.abortUnclaimedCapture(generation: openedCaptureGeneration)
                }
                self.activeVm = vm
                Task.detached(priority: .userInitiated) { [weak self, weak vm] in
                    guard let caret = FocusUtils.getCaretRect() else { return }
                    await MainActor.run {
                        guard let self, let vm, self.activeVm === vm else { return }
                        IndicatorWindowManager.shared.move(
                            onScreenContaining: FocusUtils.convertAXPointToCocoa(caret.origin)
                        )
                    }
                }
            } else if !self.holdMode {
                IndicatorWindowManager.shared.stopRecording()
            }
        }
        
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.holdMode = true
            }
        }
        holdWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + holdThreshold, execute: workItem)
    }
    
    private func handleKeyUp() {
        holdWorkItem?.cancel()
        holdWorkItem = nil
        
        Task { @MainActor in
            if self.holdMode {
                if !self.commandCapture.requestStop() {
                    if self.captureStartPending {
                        self.captureStartEpoch += 1
                        self.captureStartPending = false
                        StreamingAudioService.shared.abortPendingStart()
                    }
                    IndicatorWindowManager.shared.stopRecording()
                }
                self.holdMode = false
            }
        }
    }
}

// MARK: - Built-in Shortcut Conflicts

extension ShortcutManager {
    static func builtInShortcutOwner(
        of shortcut: KeyboardShortcuts.Shortcut,
        excluding excluded: KeyboardShortcuts.Name?,
        shortcutFor: @MainActor (KeyboardShortcuts.Name) -> KeyboardShortcuts.Shortcut? = { KeyboardShortcuts.getShortcut(for: $0) }
    ) -> String? {
        let builtIns: [(KeyboardShortcuts.Name, String)] = [
            (.toggleRecord, "Toggle record"),
            (.voiceCommand, "Voice command on selection"),
        ]
        return builtIns.first { name, _ in name != excluded && shortcutFor(name) == shortcut }?.1
    }

    nonisolated static func shortcutCollides(
        _ shortcut: KeyboardShortcuts.Shortcut?,
        with others: [KeyboardShortcuts.Shortcut?]
    ) -> Bool {
        guard let shortcut else { return false }
        return others.contains(shortcut)
    }
}

/// The voice command reads the selection before recording starts. A stop that arrives
/// during that read (a second tap, or releasing a held key) cancels the command instead
/// of being lost and leaving a recording running.
struct CommandCaptureGate {
    private(set) var isCapturing = false
    private var stopRequested = false

    mutating func begin() -> Bool {
        guard !isCapturing else { return false }
        isCapturing = true
        stopRequested = false
        return true
    }

    mutating func requestStop() -> Bool {
        guard isCapturing else { return false }
        stopRequested = true
        return true
    }

    mutating func finish() -> Bool {
        isCapturing = false
        return !stopRequested
    }
}

struct EscapeShortcutState {
    var indicatorVisible = false
    var inspectorVisible = false
    var applicationActive = false
    var escapeIsDown = false

    var shouldRegisterGlobalEscape: Bool {
        indicatorVisible && !(applicationActive && inspectorVisible) && !escapeIsDown
    }
}
