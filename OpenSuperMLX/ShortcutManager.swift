import AppKit
import ApplicationServices
import Cocoa
import Foundation
import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    static let toggleRecord = Self("toggleRecord", initial: .init(.backtick, modifiers: .option))
    static let toggleRecordWithLLM = Self("toggleRecordWithLLM", initial: .init(.backtick, modifiers: [.option, .shift]))
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

        KeyboardShortcuts.onKeyDown(for: .toggleRecordWithLLM) { [weak self] in
            self?.handleKeyDown(forceLLM: true)
        }

        KeyboardShortcuts.onKeyUp(for: .toggleRecordWithLLM) { [weak self] in
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
    
    private func handleKeyDown(forceLLM: Bool = false) {
        let requestedAt = DispatchTime.now().uptimeNanoseconds
        holdWorkItem?.cancel()
        holdMode = false
        
        Task { @MainActor in
            if self.activeVm == nil {
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
                IndicatorWindowManager.shared.releasePreviousViewModel()
                let vm = IndicatorViewModel()
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
                _ = IndicatorWindowManager.shared.show(nearPoint: cursorPosition, viewModel: vm)
                if forceLLM { vm.forceLLMCorrection = true }
                if !vm.startRecording(), let openedCaptureGeneration {
                    StreamingAudioService.shared.abortUnclaimedCapture(generation: openedCaptureGeneration)
                }
                self.activeVm = vm
                Task.detached(priority: .userInitiated) { [weak self, weak vm] in
                    guard let caret = FocusUtils.getCaretRect() else { return }
                    await MainActor.run {
                        guard let self, let vm, self.activeVm === vm else { return }
                        IndicatorWindowManager.shared.move(
                            nearPoint: FocusUtils.convertAXPointToCocoa(caret.origin)
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
                if self.captureStartPending {
                    self.captureStartEpoch += 1
                    self.captureStartPending = false
                    StreamingAudioService.shared.abortPendingStart()
                }
                IndicatorWindowManager.shared.stopRecording()
                self.holdMode = false
            }
        }
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
