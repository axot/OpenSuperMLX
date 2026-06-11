//
//  SidebarLayout.swift
//  OpenSuperMLX
//
//  Left-sidebar app shell: brand, nav, footer links. Mirrors the
//  `.side` block in the finalized HTML mockup.
//

import SwiftUI

// MARK: - SidebarTab

enum SidebarTab: Int, CaseIterable, Identifiable {
    case recordings
    case stats
    case settings

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .recordings: return "Recordings"
        case .stats: return "Stats"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .recordings: return "mic"
        case .stats: return "chart.bar"
        case .settings: return "gearshape"
        }
    }
}

// MARK: - SidebarLayout

struct SidebarLayout<Content: View>: View {
    @Binding var selectedTab: SidebarTab
    let onDeleteAllTapped: () -> Void
    @ViewBuilder var content: () -> Content

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    var body: some View {
        // ZStack instead of HStack: content fills the whole window with a fixed
        // leading inset, and the sidebar is pinned on top at the left. During a fast
        // resize the HStack's width negotiation lagged a frame and let content slide
        // over the sidebar; here content's origin is always 0 and the sidebar can't
        // be displaced because it isn't part of a width split.
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                content()
                    // Pin the content region to exactly (window − sidebar). A hard
                    // width (not maxWidth) stops any intrinsic content min-width from
                    // inflating the ZStack and shoving the whole UI off the left edge
                    // during a fast resize. Panes cap themselves to this region width
                    // via `.contentColumn()`, so the `.clipped()` here is a backstop,
                    // not the mechanism that hides overflow.
                    .environment(\.contentRegionWidth, max(0, geo.size.width - SidebarLinks.totalWidth))
                    .frame(width: max(0, geo.size.width - SidebarLinks.totalWidth),
                           height: geo.size.height, alignment: .topLeading)
                    .background(DesignTokens.bg)
                    .clipped()
                    .offset(x: SidebarLinks.totalWidth)

                HStack(spacing: 0) {
                    sidebar
                    Divider().overlay(DesignTokens.line)
                }
                .frame(width: SidebarLinks.totalWidth, height: geo.size.height, alignment: .leading)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
                .contextMenu {
                    Button(role: .destructive, action: onDeleteAllTapped) {
                        Label("Delete All Recordings…", systemImage: "trash")
                    }
                }

            VStack(spacing: 2) {
                ForEach(SidebarTab.allCases) { tab in
                    SidebarNavItem(tab: tab, isActive: selectedTab == tab) {
                        selectedTab = tab
                    }
                }
            }

            Spacer()

            VStack(alignment: .leading, spacing: 1) {
                SidebarToolLink(label: "Send feedback", systemImage: "bubble.left") {
                    NSWorkspace.shared.open(SidebarLinks.feedback)
                }
                SidebarToolLink(label: "GitHub", systemImage: "chevron.left.forwardslash.chevron.right") {
                    NSWorkspace.shared.open(SidebarLinks.github)
                }
            }

            footer
        }
        .frame(width: 216, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .frame(maxHeight: .infinity)
        .background(DesignTokens.surface2)
    }

    private var brand: some View {
        HStack(spacing: 10) {
            BrandLogo(size: 26, iconSize: 14)
            Text("OpenSuperMLX")
                .font(.system(size: 14, weight: .bold))
                .tracking(DesignTokens.trackingTitle * 14)
                .foregroundStyle(DesignTokens.txt)
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .padding(.bottom, 18)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.shield")
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.green)
            Text("Local device only")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(DesignTokens.txt3)
            Spacer(minLength: 4)
            Text(Self.appVersion.isEmpty ? "" : "v\(Self.appVersion)")
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(DesignTokens.txt4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11)
        .padding(.top, 12)
        .overlay(alignment: .top) {
            Rectangle().fill(DesignTokens.line2).frame(height: 1)
        }
        .padding(.top, 10)
    }
}

private enum SidebarLinks {
    static let feedback = URL(string: "https://github.com/axot/OpenSuperMLX/issues/new")!
    static let github = URL(string: "https://github.com/axot/OpenSuperMLX")!
    /// Sidebar footprint: 216 content + 12×2 padding.
    static let totalWidth: CGFloat = 240
}

// MARK: - Brand Logo

struct BrandLogo: View {
    var size: CGFloat = 26
    var iconSize: CGFloat = 14

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.31, style: .continuous)
            .fill(DesignTokens.acc)
            .frame(width: size, height: size)
            .overlay {
                WaveformGlyph()
                    .fill(.white)
                    .frame(width: iconSize, height: iconSize)
            }
            .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
    }
}

/// Brand mark glyph (#i-wave from the design system): four asymmetric rounded
/// bars + a sparkle, normalized to a 24×24 box. Used by the sidebar logo and
/// the app icon so both render identically.
struct WaveformGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        let ox = rect.minX + (rect.width - 24 * s) / 2
        let oy = rect.minY + (rect.height - 24 * s) / 2
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }

        var p = Path()
        // Bars: (x, y, height), width 2.2, corner radius 1.1 — matches the mockup rects.
        let bars: [(CGFloat, CGFloat, CGFloat)] = [
            (5.0, 10.5, 5), (8.3, 8, 10), (11.6, 6.5, 13), (14.9, 9, 8)
        ]
        for (bx, by, bh) in bars {
            p.addRoundedRect(
                in: CGRect(x: ox + bx * s, y: oy + by * s, width: 2.2 * s, height: bh * s),
                cornerSize: CGSize(width: 1.1 * s, height: 1.1 * s)
            )
        }
        // Sparkle: 4-point concave star centered at (19.5, 4.3).
        p.move(to: P(19.5, 1.83))
        p.addCurve(to: P(21.97, 4.30), control1: P(19.88, 3.445), control2: P(20.355, 3.92))
        p.addCurve(to: P(19.5, 6.77), control1: P(20.355, 4.68), control2: P(19.88, 5.155))
        p.addCurve(to: P(17.03, 4.30), control1: P(19.12, 5.155), control2: P(18.645, 4.68))
        p.addCurve(to: P(19.5, 1.83), control1: P(18.645, 3.92), control2: P(19.12, 3.445))
        p.closeSubpath()
        return p
    }
}

// MARK: - Nav Item

private struct SidebarNavItem: View {
    let tab: SidebarTab
    let isActive: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(isActive ? DesignTokens.acc : DesignTokens.txt3)
                    .frame(width: 17)
                Text(tab.label)
                    .font(.system(size: 13, weight: isActive ? .semibold : .medium))
                    .foregroundStyle(isActive ? DesignTokens.txt : DesignTokens.txt2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background {
                if isActive {
                    RoundedRectangle(cornerRadius: DesignTokens.radiusNav, style: .continuous)
                        .fill(DesignTokens.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignTokens.radiusNav, style: .continuous)
                                .stroke(DesignTokens.line, lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.08), radius: 3, y: 2)
                } else if isHovered {
                    RoundedRectangle(cornerRadius: DesignTokens.radiusNav, style: .continuous)
                        .fill(Color.black.opacity(0.035))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tab.label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }
}

// MARK: - Tool Link

private struct SidebarToolLink: View {
    let label: String
    let systemImage: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: systemImage)
                    .font(.system(size: 13))
                    .foregroundStyle(DesignTokens.txt3)
                    .frame(width: 14)
                Text(label)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(DesignTokens.txt2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background {
                if isHovered {
                    RoundedRectangle(cornerRadius: DesignTokens.radiusNav, style: .continuous)
                        .fill(Color.black.opacity(0.035))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }
}
