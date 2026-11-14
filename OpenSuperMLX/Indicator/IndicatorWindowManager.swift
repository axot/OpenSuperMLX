import AppKit
import Combine
import SwiftUI

import KeyboardShortcuts

@MainActor
class IndicatorWindowManager: ObservableObject, IndicatorViewDelegate {
    static let shared = IndicatorWindowManager()

    private var window: NSWindow?
    @Published private(set) var viewModel: IndicatorViewModel?

    private let recordingActivity: RecordingActivity
    private let visibilityChanged: (Bool) -> Void

    private convenience init() {
        self.init(recordingActivity: .shared) { ShortcutManager.shared.indicatorVisible = $0 }
    }

    init(recordingActivity: RecordingActivity, visibilityChanged: @escaping (Bool) -> Void) {
        self.recordingActivity = recordingActivity
        self.visibilityChanged = visibilityChanged
    }
    
    static let panelSize = NSSize(width: 380, height: 88)
    static let bottomMargin: CGFloat = 16

    func releasePreviousViewModel() {
        viewModel?.cleanup()
        viewModel = nil
        window?.contentView = nil
        window?.orderOut(nil)
        visibilityChanged(false)
        recordingActivity.report(self, isActive: false)
    }

    func show(
        onScreenContaining point: NSPoint? = nil,
        viewModel providedViewModel: IndicatorViewModel? = nil
    ) -> IndicatorViewModel {
        visibilityChanged(true)
        recordingActivity.report(self, isActive: true)

        viewModel?.cleanup()
        let newViewModel = providedViewModel ?? IndicatorViewModel()
        newViewModel.delegate = self
        viewModel = newViewModel

        if window == nil {
            window = Self.makePanel()
        }

        let targetScreen = point.flatMap { FocusUtils.screenContaining(point: $0) } ?? NSScreen.main
        if let window = window, let screen = targetScreen {
            window.setContentSize(Self.panelSize)
            window.setFrameOrigin(Self.indicatorOrigin(
                windowSize: window.frame.size,
                visibleFrame: screen.visibleFrame
            ))

            let hostingView = FirstMouseHostingView(rootView: IndicatorWindow(viewModel: newViewModel))
            window.contentView = hostingView
        }

        window?.orderFront(nil)
        return newViewModel
    }

    static func indicatorOrigin(windowSize: NSSize, visibleFrame: NSRect) -> NSPoint {
        NSPoint(
            x: visibleFrame.midX - windowSize.width / 2,
            y: visibleFrame.minY + bottomMargin
        )
    }

    func move(onScreenContaining point: NSPoint) {
        guard let window, let screen = FocusUtils.screenContaining(point: point) ?? NSScreen.main else { return }
        window.setFrameOrigin(Self.indicatorOrigin(
            windowSize: window.frame.size,
            visibleFrame: screen.visibleFrame
        ))
    }

    static func makePanel() -> NSPanel {
        // NSPanel for full-screen space compatibility
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.canHide = false
        panel.hidesOnDeactivate = false
        return panel
    }
    
    func stopRecording() {
        viewModel?.startDecoding()
    }
    
    func stopForce() {
        viewModel?.cancelRecording()
        viewModel?.cleanup()
        hide()
    }

    func hide() {
        visibilityChanged(false)
        
        Task {
            guard let viewModel = self.viewModel else { return }
            
            await viewModel.hideWithAnimation()
            viewModel.cleanup()
            // A newer session may have started during the hide animation; its own hide tears it down.
            guard self.viewModel === viewModel else { return }

            self.window?.contentView = nil
            self.window?.orderOut(nil)
            self.viewModel = nil
            self.recordingActivity.report(self, isActive: false)
            
            NotificationCenter.default.post(name: .indicatorWindowDidHide, object: nil)
        }
    }
    
    func didFinishDecoding() {
        hide()
    }
}

/// The pill never becomes key, so without this the first click on the cleanup chip
/// would only focus the panel instead of opening the menu.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
