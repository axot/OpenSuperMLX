import AppKit
import ApplicationServices
import Carbon
import Cocoa
import Foundation
import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    static let toggleRecord = Self("toggleRecord", default: .init(.backtick, modifiers: .option))
    static let toggleRecordWithLLM = Self("toggleRecordWithLLM", default: .init(.backtick, modifiers: [.option, .shift]))
    static let escape = Self("escape", default: .init(.escape))
}

class ShortcutManager {
    static let shared = ShortcutManager()

    private var activeVm: IndicatorViewModel?
    private var useModifierOnlyHotkey = false

    private init() {
        print("ShortcutManager init")
        
        setupKeyboardShortcuts()
        setupModifierKeyMonitor()
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hotkeySettingsChanged),
            name: .hotkeySettingsChanged,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(indicatorWindowDidHide),
            name: .indicatorWindowDidHide,
            object: nil
        )
    }
    
    @objc private func indicatorWindowDidHide() {
        activeVm = nil
    }
    
    @objc private func hotkeySettingsChanged() {
        setupModifierKeyMonitor()
    }
    
    private func setupKeyboardShortcuts() {
        KeyboardShortcuts.onKeyDown(for: .toggleRecord) { [weak self] in
            self?.handleKeyDown()
        }

        KeyboardShortcuts.onKeyDown(for: .toggleRecordWithLLM) { [weak self] in
            self?.handleKeyDown(forceLLM: true)
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
    
    private func setupModifierKeyMonitor() {
        let modifierKeyString = AppPreferences.shared.modifierOnlyHotkey
        let modifierKey = ModifierKey(rawValue: modifierKeyString) ?? .none
        
        if modifierKey != .none {
            useModifierOnlyHotkey = true
            KeyboardShortcuts.disable(.toggleRecord)
            KeyboardShortcuts.disable(.toggleRecordWithLLM)
            
            ModifierKeyMonitor.shared.onKeyDown = { [weak self] in
                self?.handleKeyDown()
            }
            
            ModifierKeyMonitor.shared.start(modifierKey: modifierKey)
            print("ShortcutManager: Using modifier-only hotkey: \(modifierKey.displayName)")
        } else {
            useModifierOnlyHotkey = false
            ModifierKeyMonitor.shared.stop()
            KeyboardShortcuts.enable(.toggleRecord)
            KeyboardShortcuts.enable(.toggleRecordWithLLM)
            print("ShortcutManager: Using regular keyboard shortcut")
        }
    }
    
    private func handleKeyDown(forceLLM: Bool = false) {

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
            } else {
                IndicatorWindowManager.shared.stopRecording()
                self.activeVm = nil
            }
        }
    }
    
}