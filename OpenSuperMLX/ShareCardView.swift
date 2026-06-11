//
//  ShareCardView.swift
//  OpenSuperMLX
//
//  Shareable bubble card (ChatGPT-Wrapped style): scattered circular stat
//  bubbles on an arctic-blush gradient. Mirrors `.sc-bubble` in the mockup.
//  Export renders a deterministic static snapshot (isExporting = true).
//

import SwiftUI

struct ShareCardView: View {
    let bubbles: [ShareCardModel.Bubble]
    /// When true, all drift animations are disabled and bubbles sit at their
    /// deterministic initial layout — used by the export ImageRenderer.
    var isExporting: Bool = false

    // Display dimensions (points). Export renders this same view at scale 2.
    static let side: CGFloat = 420

    var body: some View {
        VStack(spacing: 0) {
            Text("Your voice stats")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.black.opacity(0.6))
                .tracking(-0.02 * 16)
                .frame(maxWidth: .infinity)

            GeometryReader { geo in
                ZStack {
                    ForEach(Array(bubbles.enumerated()), id: \.offset) { idx, bubble in
                        BubbleView(bubble: bubble, isExporting: isExporting)
                            .position(
                                x: bubble.anchor.x * geo.size.width,
                                y: bubble.anchor.y * geo.size.height
                            )
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .padding(.vertical, 8)

            footer
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 24)
        .frame(width: Self.side, height: Self.side)
        .background(
            LinearGradient(
                stops: [
                    .init(color: Color(hex: 0xE8F4F8), location: 0.0),
                    .init(color: Color(hex: 0xD0E8F2), location: 0.20),
                    .init(color: Color(hex: 0xB8D4E8), location: 0.40),
                    .init(color: Color(hex: 0xE8D0D8), location: 0.65),
                    .init(color: Color(hex: 0xF2C8C0), location: 0.85),
                    .init(color: Color(hex: 0xF8DCD4), location: 1.0)
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.black)
                    .frame(width: 16, height: 16)
                    .overlay {
                        Image(systemName: "waveform")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                Text("OpenSuperMLX")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.55))
            }
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 9))
                    .foregroundStyle(.black.opacity(0.3))
                Text("Local device only")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.black.opacity(0.35))
            }
        }
        .padding(.top, 10)
    }
}

// MARK: - Share Card Sheet (display + export)

struct ShareCardSheet: View {
    let snapshot: StatsSnapshot
    @Environment(\.dismiss) private var dismiss

    private var bubbles: [ShareCardModel.Bubble] { ShareCardModel.bubbles(from: snapshot) }

    var body: some View {
        VStack(spacing: 22) {
            ShareCardView(bubbles: bubbles, isExporting: false)

            HStack(spacing: 10) {
                ShareSheetButton(title: "Close", systemImage: nil, style: .ghost) { dismiss() }
                ShareSheetButton(title: "Copy image", systemImage: "doc.on.doc", style: .solid) {
                    exportToClipboard()
                }
            }
        }
        .padding(28)
        .background(DesignTokens.surface2)
    }

    /// Render a deterministic static snapshot at @2x and write PNG to the clipboard.
    /// ImageRenderer + NSPasteboard are main-thread-only; this runs on @MainActor.
    @MainActor
    private func exportToClipboard() {
        let card = ShareCardView(bubbles: bubbles, isExporting: true)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 2.0
        guard let nsImage = renderer.nsImage else {
            ErrorToastManager.shared.show("Export failed")
            return
        }
        if ClipboardUtil.copyImage(nsImage) {
            ErrorToastManager.shared.show("Copied!")
        } else {
            ErrorToastManager.shared.show("Export failed")
        }
    }
}

// MARK: - Share sheet button (mono, matches design system)

private struct ShareSheetButton: View {
    enum Style { case ghost, solid }
    let title: String
    let systemImage: String?
    let style: Style
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 12, weight: .semibold))
                }
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(style == .solid ? DesignTokens.accOn : DesignTokens.txt)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(background)
            .offset(y: hovering ? -1 : 0)
            .shadow(color: .black.opacity(style == .solid ? (hovering ? 0.18 : 0.10) : 0),
                    radius: hovering ? 7 : 3, y: hovering ? 3 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.14), value: hovering)
    }

    @ViewBuilder
    private var background: some View {
        switch style {
        case .solid:
            RoundedRectangle(cornerRadius: DesignTokens.radiusButton, style: .continuous)
                .fill(DesignTokens.acc)
        case .ghost:
            RoundedRectangle(cornerRadius: DesignTokens.radiusButton, style: .continuous)
                .fill(hovering ? DesignTokens.surface3 : DesignTokens.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.radiusButton, style: .continuous)
                        .stroke(DesignTokens.line, lineWidth: 1)
                )
        }
    }
}

// MARK: - Bubble

private struct BubbleView: View {
    let bubble: ShareCardModel.Bubble
    let isExporting: Bool
    @State private var animate = false

    private var diameter: CGFloat {
        switch bubble.size {
        case .lg: return 110
        case .md: return 88
        case .sm: return 74
        }
    }

    private var valueFontSize: CGFloat {
        switch bubble.size {
        case .lg: return 30
        case .md: return 24
        case .sm: return 19
        }
    }

    var body: some View {
        VStack(spacing: 1) {
            Text(bubble.label)
                .font(.system(size: 8, weight: .bold))
                .tracking(0.07 * 8)
                .foregroundStyle(.black.opacity(0.35))
            Text(bubble.value)
                .font(.system(size: valueFontSize, weight: .black))
                .tracking(-0.04 * valueFontSize)
                .foregroundStyle(.black)
            Text(bubble.sub)
                .font(.system(size: 8.5))
                .foregroundStyle(.black.opacity(0.4))
        }
        .frame(width: diameter, height: diameter)
        .background(Circle().fill(.white))
        .overlay(Circle().stroke(.black.opacity(0.04), lineWidth: 1))
        .shadow(color: .black.opacity(0.08), radius: 6, y: 3)
        .offset(driftOffset)
        .onAppear {
            guard !isExporting else { return }
            withAnimation(
                .easeInOut(duration: Self.durations[bubble.phase % 6])
                    .repeatForever(autoreverses: true)
                    .delay(Self.delays[bubble.phase % 6])
            ) {
                animate = true
            }
        }
    }

    private var driftOffset: CGSize {
        guard animate && !isExporting else { return .zero }
        let d = Self.drifts[bubble.phase % 6]
        return CGSize(width: d.x, height: d.y)
    }

    // Per-bubble drift vectors (±8–12pt), durations 9–14s, staggered delays.
    private static let drifts: [CGPoint] = [
        CGPoint(x: 6, y: -10), CGPoint(x: -8, y: 8), CGPoint(x: 10, y: -6),
        CGPoint(x: -6, y: 10), CGPoint(x: 8, y: 8), CGPoint(x: -10, y: -6)
    ]
    private static let durations: [Double] = [12, 9, 11, 14, 10, 13]
    private static let delays: [Double] = [0, 1.5, 0.8, 2.2, 0.4, 3]
}
