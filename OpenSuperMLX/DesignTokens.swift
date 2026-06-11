//
//  DesignTokens.swift
//  OpenSuperMLX
//
//  Design system tokens mirrored from the finalized HTML mockup
//  (designs/stats-dashboard-20260529/FINAL-all-pages.html `:root`).
//  The redesign is an intentional light-mono aesthetic; these are fixed,
//  scheme-independent surface colors so the chrome renders identically
//  regardless of system appearance.
//

import SwiftUI

enum DesignTokens {
    // MARK: - Colors

    static let acc = Color(hex: 0x0A0A0A)
    static let accSoft = Color(hex: 0xF4F4F5)
    static let accOn = Color.white
    static let bg = Color.white
    static let surface = Color.white
    static let surface2 = Color(hex: 0xFAFAFA)
    static let surface3 = Color(hex: 0xF6F6F7)
    static let line = Color.black.opacity(0.07)
    static let line2 = Color.black.opacity(0.045)
    static let lineHard = Color.black.opacity(0.12)
    static let txt = Color(hex: 0x0A0A0A)
    static let txt2 = Color(hex: 0x62626B)
    static let txt3 = Color(hex: 0x9B9BA3)
    static let txt4 = Color(hex: 0xC2C2C8)
    static let track = Color(hex: 0xEEEEF0)
    static let bar = Color(hex: 0xE4E4E7)
    static let red = Color(hex: 0xF0463A)
    static let green = Color(hex: 0x34A866)

    // MARK: - Radii

    static let radiusWindow: CGFloat = 14
    static let radiusCard: CGFloat = 14
    static let radiusNav: CGFloat = 9
    static let radiusButton: CGFloat = 9
    static let radiusSearch: CGFloat = 10

    // MARK: - Letter spacing (tracking)

    static let trackingBase: CGFloat = -0.012
    static let trackingTitle: CGFloat = -0.025

    // MARK: - Layout

    /// Max width for a content column. The window resizes 750–1100pt, but content
    /// is capped and centered so it never stretches into an awkwardly wide layout.
    /// Sized so the 53-week activity heatmap gets comfortably large cells.
    static let contentMaxWidth: CGFloat = 880
}

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}
