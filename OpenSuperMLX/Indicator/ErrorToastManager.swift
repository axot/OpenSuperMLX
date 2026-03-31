// ErrorToastManager.swift
// OpenSuperMLX

import AppKit
import SwiftUI

@MainActor
class ErrorToastManager {
    static let shared = ErrorToastManager()

    private var window: NSPanel?

    private init() {}

    func show(_ message: String) {
        if window == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 90),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.ignoresMouseEvents = false
            self.window = panel
        }

        let hostingView = NSHostingView(rootView: ErrorToastView(message: message) {
            self.dismiss()
        })
        window?.contentView = hostingView

        if let screen = NSScreen.main, let window = window {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - 200
            let y = screenFrame.maxY - 100
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        window?.orderFront(nil)
    }

    func dismiss() {
        window?.contentView = nil
        window?.orderOut(nil)
    }
}

struct ErrorToastView: View {
    let message: String
    let onDismiss: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let rect = RoundedRectangle(cornerRadius: 12)

        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.system(size: 16))

            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(2)

            Spacer()

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(width: 400)
        .background {
            rect
                .fill(colorScheme == .dark
                    ? Color.black.opacity(0.24)
                    : Color.white.opacity(0.24))
                .background {
                    rect.fill(Material.thinMaterial)
                }
                .shadow(color: .black.opacity(0.2), radius: 12, x: 0, y: 4)
        }
        .clipShape(rect)
    }
}
