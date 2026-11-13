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
    
    func releasePreviousViewModel() {
        viewModel?.cleanup()
        viewModel = nil
        window?.contentView = nil
        window?.orderOut(nil)
        visibilityChanged(false)
        recordingActivity.report(self, isActive: false)
    }

    func show(
        nearPoint point: NSPoint? = nil,
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
            let windowFrame = window.frame
            let screenFrame = screen.frame

            var x: CGFloat
            var y: CGFloat

            if let point = point {
                x = point.x - windowFrame.width / 2
                y = point.y + 20
            } else {
                x = screenFrame.midX - windowFrame.width / 2
                y = screenFrame.maxY - windowFrame.height - 100
            }

            x = max(screenFrame.minX, min(x, screenFrame.maxX - windowFrame.width))
            y = max(screenFrame.minY, min(y, screenFrame.maxY - windowFrame.height))

            window.setFrameOrigin(NSPoint(x: x, y: y))

            let hostingView = NSHostingView(rootView: IndicatorWindow(viewModel: newViewModel))
            window.contentView = hostingView
        }

        window?.orderFront(nil)
        return newViewModel
    }

    func move(nearPoint point: NSPoint) {
        guard let window, let screen = FocusUtils.screenContaining(point: point) ?? NSScreen.main else { return }
        let bounds = screen.frame
        window.setFrameOrigin(NSPoint(
            x: max(bounds.minX, min(point.x - window.frame.width / 2, bounds.maxX - window.frame.width)),
            y: max(bounds.minY, min(point.y + 20, bounds.maxY - window.frame.height))
        ))
    }

    static func makePanel() -> NSPanel {
        // NSPanel for full-screen space compatibility
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
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
