// RecordingRowClickView.swift
// OpenSuperMLX

import AppKit
import SwiftUI

struct RecordingRowClickView: NSViewRepresentable {
    let label: String
    let onSelect: () -> Void

    func makeNSView(context: Context) -> RecordingRowClickButton {
        RecordingRowClickButton()
    }

    func updateNSView(_ button: RecordingRowClickButton, context: Context) {
        button.onSelect = onSelect
        button.setAccessibilityLabel(label)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RecordingRowClickButton,
                      context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}

final class RecordingRowClickButton: NSButton {
    var onSelect: () -> Void = {}

    init() {
        super.init(frame: .zero)
        isBordered = false
        isTransparent = true
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(selectRecording)
        toolTip = "Show complete transcript"
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    @objc private func selectRecording() {
        onSelect()
    }
}
