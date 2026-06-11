//
//  ContentColumn.swift
//  OpenSuperMLX
//
//  Centered, width-capped content column.
//
//  Replaces the `.frame(maxWidth: cap).frame(maxWidth: .infinity)` idiom. That
//  idiom laid content out at the full `cap` (880) width inside a width-greedy
//  vertical ScrollView: the ScrollView adopts its content's ideal cross-axis
//  width instead of clamping it to the offered region, so at any window narrower
//  than the cap the pane was rendered at 880pt and the surplus overflowed on the
//  right — then masked by SidebarLayout's `.clipped()`. The clip was static at
//  every width < ~880, which is why it surfaced during resize.
//
//  Here the cap is derived from the *content region width* that SidebarLayout
//  already knows authoritatively (window − sidebar), published via the
//  environment. Each pane caps to `min(region, cap)` — a definite value that is
//  always ≤ the region — so content can never overflow regardless of ScrollView
//  width negotiation.
//

import SwiftUI

enum ContentColumnLayout {
    /// Width of the centered content column for a given content-region width:
    /// capped at `cap`, never wider than the region, never negative.
    static func columnWidth(region: CGFloat, cap: CGFloat = DesignTokens.contentMaxWidth) -> CGFloat {
        max(0, min(region, cap))
    }
}

private struct ContentRegionWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = DesignTokens.contentMaxWidth
}

extension EnvironmentValues {
    /// Width of the area available to a content pane (window minus sidebar),
    /// supplied by SidebarLayout.
    var contentRegionWidth: CGFloat {
        get { self[ContentRegionWidthKey.self] }
        set { self[ContentRegionWidthKey.self] = newValue }
    }
}

private struct ContentColumnModifier: ViewModifier {
    @Environment(\.contentRegionWidth) private var regionWidth

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: ContentColumnLayout.columnWidth(region: regionWidth))
            .frame(maxWidth: .infinity)
    }
}

extension View {
    /// Cap this block to `min(contentRegionWidth, contentMaxWidth)` and center it.
    /// The cap is a definite width bounded by the real region, so the block never
    /// overflows the region (no clipping), at any window width or during resize.
    func contentColumn() -> some View {
        modifier(ContentColumnModifier())
    }
}
