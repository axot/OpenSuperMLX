import AppKit
import ApplicationServices
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
    private var holdWorkItem: DispatchWorkItem?
    private let holdThreshold: TimeInterval = 0.3
    private var holdMode = false

    private init() {
        print("ShortcutManager init")
        
        setupKeyboardShortcuts()
        
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
            self?.holdMode = true
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