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
        if escapeState.shouldRegisterGlobalEscape {
            KeyboardShortcuts.enable(.escape)
        } else {
            KeyboardShortcuts.disable(.escape)
        }
    }
    
    private func handleKeyDown(forceLLM: Bool = false) {
        holdWorkItem?.cancel()
        holdMode = false
        
        Task { @MainActor in
            if self.activeVm == nil {
                let cursorPosition = FocusUtils.getCurrentCursorPosition()
                let indicatorPoint: NSPoint?
                if let caret = FocusUtils.getCaretRect() {
                    indicatorPoint = FocusUtils.convertAXPointToCocoa(caret.origin)
                } else {
                    indicatorPoint = cursorPosition
                }
                let vm = IndicatorWindowManager.shared.show(nearPoint: indicatorPoint)
                if forceLLM { vm.forceLLMCorrection = true }
                vm.startRecording()
                self.activeVm = vm
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
