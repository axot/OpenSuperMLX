//
//  RecordingDockView.swift
//  OpenSuperMLX
//
//  Bottom dock for the Recordings page. A single stable layout across both
//  states so the leading button and trailing tools never move:
//   - leading: 46pt circular button (idle = black w/ red dot → start; recording
//     = red w/ white square → stop). Same frame in both states.
//   - middle: idle hints ↔ recording meta (label + VU + timer + live text).
//   - trailing: tools (mic picker, delete) — always present so device switching
//     and delete-all stay reachable while recording.
//  Mirrors the `.dock` / `.dock-rec` blocks in the finalized HTML mockup.
//

import SwiftUI

// MARK: - Logo-style 4-bar waveform

/// Four bars matching the brand mark's asymmetric ratios. Driven by the live
/// streaming RMS level when available; falls back to a static silhouette when
/// `level` is 0 (non-streaming recording mode has no live meter).
struct LogoWaveform: View {
    /// Live amplitude in [0, 1]. 0 ⇒ static silhouette.
    var level: Float
    var barWidth: CGFloat = 3.5
    var maxHeight: CGFloat = 16
    var color: Color = DesignTokens.acc

    private let ratios: [CGFloat] = [0.5, 1.0, 0.75, 0.4]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<4, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(width: barWidth, height: barHeight(i))
                    .animation(.easeOut(duration: 0.12), value: level)
            }
        }
        .frame(height: maxHeight)
    }

    private func barHeight(_ i: Int) -> CGFloat {
        let amp = VUScale.amplitude(level)
        if amp > 0.02 {
            return minH4 + amp * (maxHeight - minH4) * ratios[i]
        }
        return minH4 + (maxHeight - minH4) * ratios[i] * 0.28
    }
    private let minH4: CGFloat = 4
}

/// Shared mapping from raw RMS [0,1] to meter amplitude [0,1].
///
/// Human loudness perception is logarithmic, so a linear gain reads as flat at
/// speech levels. Standard meter practice: convert to dBFS (20·log10(rms)) and
/// lerp a fixed dynamic range to [0,1], clamped at a noise floor to avoid idle
/// flicker. Nominal speech sits at roughly −18…−12 dBFS, so a −54→−6 dBFS window
/// puts normal talking in the upper-middle of the bar with headroom for peaks.
/// (Refs: Ardour "Calculating RMS in Digital Audio"; Sonarworks "Decibel in Audio".)
enum VUScale {
    static let floorDB: Float = -54
    static let ceilDB: Float = -6

    static func amplitude(_ rms: Float) -> CGFloat {
        guard rms > 0.0000001 else { return 0 }
        let db = 20 * log10(rms)
        let norm = (db - floorDB) / (ceilDB - floorDB)
        return CGFloat(min(1, max(0, norm)))
    }
}

// MARK: - Dock

/// Unified dock. `isRecording` toggles the leading button + middle content
/// without changing the surrounding geometry.
struct RecordingDock<Tools: View>: View {
    let isRecording: Bool
    let isBusy: Bool
    let shortcutDescription: String
    let level: Float
    let elapsed: TimeInterval
    let text: String
    let onRecord: () -> Void
    let onStop: () -> Void
    @ViewBuilder var tools: () -> Tools

    @State private var hovering = false

    private var timeString: String { StatsFormat.clock(elapsed) }

    var body: some View {
        HStack(spacing: 15) {
            recordButton
            middle
            Spacer(minLength: 8)
            tools()
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 22)
        .contentColumn()
        .frame(height: 78)
        .overlay(alignment: .top) {
            Rectangle().fill(DesignTokens.line2).frame(height: 1)
        }
        .background(
            LinearGradient(
                colors: [.clear, Color.black.opacity(0.012)],
                startPoint: .top, endPoint: .bottom
            )
        )
    }

    // MARK: Leading button (fixed 46pt frame in both states)

    private var recordButton: some View {
        Button(action: { isRecording ? onStop() : onRecord() }) {
            ZStack {
                Circle()
                    .fill(isRecording ? DesignTokens.red : DesignTokens.acc)
                    .shadow(
                        color: (isRecording ? DesignTokens.red : Color.black).opacity(isRecording ? 0.4 : 0.12),
                        radius: isRecording ? 8 : 5, y: isRecording ? 6 : 2
                    )
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else if isRecording {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(.white)
                        .frame(width: 14, height: 14)
                } else {
                    Circle().fill(DesignTokens.red).frame(width: 13, height: 13)
                }
            }
            .frame(width: 46, height: 46)
            .scaleEffect(hovering && !isBusy ? 1.04 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovering)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isRecording)
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .onHover { hovering = $0 }
        .help(isRecording ? "Stop & paste" : "Start recording")
    }

    // MARK: Middle (idle hints ↔ recording meta), fixed-height frame

    @ViewBuilder
    private var middle: some View {
        if isRecording {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text("Recording")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(DesignTokens.red)
                    LogoWaveform(level: level)
                    Text(timeString)
                        .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(DesignTokens.txt3)
                }
                TypewriterText(target: text, placeholder: "Listening…")
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .transition(.opacity)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if !shortcutDescription.isEmpty {
                        KeyCap(shortcutDescription)
                    }
                    Text("Mini recorder anywhere")
                        .font(.system(size: 11))
                        .foregroundStyle(DesignTokens.txt2)
                }
                Text("Drop an audio file to transcribe")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.txt2)
            }
            .transition(.opacity)
        }
    }
}

// MARK: - Typewriter text

/// Reveals streaming transcription one character at a time so new chunks slide
/// in instead of popping. Tracks the latest `target`; a per-frame timer advances
/// the visible prefix toward it (faster when far behind so it never lags audibly),
/// and snaps when the text is replaced rather than extended (e.g. a reset).
struct TypewriterText: View {
    let target: String
    var placeholder: String = ""

    @State private var shown = ""
    // Live mirror of `target`. The reveal timer reads this (@State, backed by
    // external storage) rather than `target` — the latter is a `let` captured by
    // value when the timer is scheduled, so a chunk appended mid-reveal would be
    // invisible until the next distinct target change. Mirroring keeps the running
    // timer advancing toward the newest text every tick.
    @State private var liveTarget = ""
    @State private var timer: Timer?

    var body: some View {
        Text(shown.isEmpty ? placeholder : shown)
            .foregroundStyle(shown.isEmpty ? DesignTokens.txt3 : DesignTokens.txt)
            .onAppear { liveTarget = target; sync(animated: false) }
            .onChange(of: target) { _, newValue in
                liveTarget = newValue
                sync(animated: true)
            }
            .onDisappear { timer?.invalidate(); timer = nil }
    }

    private func sync(animated: Bool) {
        // Replacement (not an extension of what's shown) → snap to avoid scrambling.
        if !liveTarget.hasPrefix(shown) {
            shown = liveTarget
            return
        }
        guard animated else { shown = liveTarget; return }
        // A running timer already reads `liveTarget` each tick, so it will pick up
        // the freshly-appended chunk without rescheduling.
        guard timer == nil else { return }
        // ~15 chars/sec base reveal — within the 15–20 cps comfortable-reading band
        // (UX motion research); a touch toward the slow end since CJK text is denser.
        timer = Timer.scheduledTimer(withTimeInterval: 0.066, repeats: true) { _ in
            Task { @MainActor in step() }
        }
    }

    private func step() {
        guard liveTarget.hasPrefix(shown), shown.count < liveTarget.count else {
            // Caught up, or target replaced — finish/snap and stop.
            if !liveTarget.hasPrefix(shown) { shown = liveTarget }
            timer?.invalidate(); timer = nil
            return
        }
        // One char per tick normally (~15 cps); accelerate gently only when far
        // behind so a big committed chunk still catches up within ~1.5s instead of
        // lagging the speaker — but never fast enough to read as an instant pop.
        let behind = liveTarget.count - shown.count
        let stride = behind > 40 ? max(1, behind / 30) : 1
        let end = liveTarget.index(liveTarget.startIndex, offsetBy: min(liveTarget.count, shown.count + stride))
        shown = String(liveTarget[..<end])
        if shown.count >= liveTarget.count {
            timer?.invalidate(); timer = nil
        }
    }
}

// MARK: - Dock tool button

/// Square icon button used in the dock trailing tools (mic-adjacent, delete).
struct DockToolButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14))
                .foregroundStyle(hovering ? DesignTokens.txt : DesignTokens.txt2)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.radiusNav, style: .continuous)
                        .fill(DesignTokens.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignTokens.radiusNav, style: .continuous)
                                .stroke(hovering ? DesignTokens.lineHard : DesignTokens.line, lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - KeyCap

struct KeyCap: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(DesignTokens.txt2)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(DesignTokens.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(DesignTokens.line, lineWidth: 1)
                    )
            )
    }
}
