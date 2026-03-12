import AppKit
import ApplicationServices
import Cocoa
import Foundation
import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    static let toggleRecord = Self("toggleRecord", default: .init(.backtick, modifiers: .option))
    static let escape = Self("escape", default: .init(.escape))
}

class ShortcutManager {
    static let shared = ShortcutManager()

    private var activeVm: IndicatorViewModel?

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
    }
    
    private func setupKeyboardShortcuts() {
        KeyboardShortcuts.onKeyDown(for: .toggleRecord) { [weak self] in
            self?.handleKeyDown()
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
    
    private func handleKeyDown() {
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
                vm.startRecording()
                self.activeVm = vm
            } else {
                IndicatorWindowManager.shared.stopRecording()
                self.activeVm = nil
            }
        }
    }
    
}