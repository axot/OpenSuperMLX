// RecordingRecoveryPanel.swift
// OpenSuperMLX

import AppKit
import Combine
import SwiftUI

@MainActor
final class RecordingRecoveryPanelController {
    static let shared = RecordingRecoveryPanelController(
        coordinator: RecordingSaveCoordinator.shared
    )

    private let coordinator: RecordingSaveCoordinator
    private var panel: NSPanel?
    private var stateObserver: AnyCancellable?

    init(coordinator: RecordingSaveCoordinator) {
        self.coordinator = coordinator
        stateObserver = coordinator.$state.sink { [weak self] state in
            guard case .idle = state else { return }
            self?.panel?.orderOut(nil)
        }
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 250),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Recording Not Saved"
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(
            rootView: RecordingRecoveryView(coordinator: coordinator)
        )
        return panel
    }
}

private struct RecordingRecoveryView: View {
    @ObservedObject var coordinator: RecordingSaveCoordinator
    @State private var confirmsCancel = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Your transcript is safe", systemImage: "externaldrive.badge.exclamationmark")
                .font(.headline)

            Text(message)
                .fixedSize(horizontal: false, vertical: true)

            if showsActions {
                HStack {
                    Button("Cancel Save") {
                        confirmsCancel = true
                    }
                    Spacer()
                    Button("Copy Transcript") {
                        if coordinator.copyTranscript() {
                            ErrorToastManager.shared.show("Transcript copied.")
                        } else {
                            ErrorToastManager.shared.show("Transcript could not be copied.")
                        }
                    }
                    Button("Retry") {
                        Task { _ = await coordinator.retry() }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(progressMessage)
                }
            }
        }
        .padding(24)
        .frame(width: 420)
        .alert("Discard this recording?", isPresented: $confirmsCancel) {
            Button("Keep Trying", role: .cancel) {}
            Button("Discard Recording", role: .destructive) {
                Task { await coordinator.cancelPendingSave() }
            }
        } message: {
            Text("The transcript and recoverable audio will be removed.")
        }
    }

    private var showsActions: Bool {
        if case .awaitingUser = coordinator.state { return true }
        return false
    }

    private var progressMessage: String {
        switch coordinator.state {
        case .saving:
            return "Preparing the recording…"
        case .retrying:
            return "Trying to save the recording…"
        case .cancelling:
            return "Discarding the recording…"
        case .idle, .awaitingUser:
            return "Preparing the recording…"
        }
    }

    private var message: String {
        guard case .awaitingUser(_, let error) = coordinator.state else {
            return "OpenSuperMLX is preparing your recording."
        }
        switch error.category {
        case .outOfSpace:
            return "There is not enough disk space to save the audio. Free some space, then choose Retry."
        case .saveFailed:
            return "The audio could not be saved. Fix the storage problem, then choose Retry."
        }
    }
}
