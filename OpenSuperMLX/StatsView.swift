//
//  StatsView.swift
//  OpenSuperMLX
//
//  Stats dashboard: gradient hero (per-language percentile), a daily
//  contribution heatmap, 6 metric tiles, and a shareable bubble card. Mirrors
//  the `.dgrid` block in the finalized mockup.
//

import os
import SwiftUI

private let statsLogger = Logger(subsystem: "OpenSuperMLX", category: "Stats")

// MARK: - Computed snapshot

struct StatsSnapshot {
    struct LanguageHero {
        let language: StatLanguage
        let percentile: Double
    }

    var heroes: [LanguageHero] = []
    var streak = 0
    var totalUnits = 0
    var spokenSeconds: TimeInterval = 0
    var timeSavedSeconds: TimeInterval = 0
    var sessions = 0
    var busiestDay: Date?
    var dailyActivity: [Date: Int] = [:]

    var hasData: Bool { sessions > 0 }
    var hasPercentile: Bool { !heroes.isEmpty }

    static func compute(_ recordings: [Recording], calendar: Calendar = .current, now: Date = Date()) -> StatsSnapshot {
        var s = StatsSnapshot()
        s.sessions = UsageStats.completedSessionCount(recordings: recordings)
        s.streak = UsageStats.currentStreak(recordings: recordings, calendar: calendar, now: now)
        s.totalUnits = UsageStats.totalUnits(recordings: recordings)
        s.spokenSeconds = UsageStats.totalSpokenSeconds(recordings: recordings)
        s.timeSavedSeconds = UsageStats.totalTimeSaved(recordings: recordings)
        s.busiestDay = UsageStats.busiestDay(recordings: recordings, calendar: calendar)
        s.dailyActivity = UsageStats.dailyActivity(recordings: recordings, calendar: calendar)
        // One percentile computation per language, kept where non-nil — no separate
        // "which languages qualify" pass that would compute each percentile twice.
        s.heroes = StatLanguage.allCases.compactMap { lang in
            UsageStats.computePercentile(recordings: recordings, language: lang)
                .map { StatsSnapshot.LanguageHero(language: lang, percentile: $0) }
        }
        // Rank order: highest percentile (best) first.
        .sorted { $0.percentile > $1.percentile }
        return s
    }
}

// MARK: - Share card model

enum ShareCardModel {
    struct Bubble {
        enum Size { case lg, md, sm }
        let label: String
        let value: String
        let sub: String
        let size: Size
        let anchor: UnitPoint
        let phase: Int
    }

    /// Six-bubble layout matching the mockup. Edge anchors keep ≥20pt clearance.
    static func bubbles(from s: StatsSnapshot) -> [Bubble] {
        let topPercentile = s.heroes.map(\.percentile).max()
        let topValue = topPercentile.map { UsageStats.formatTop(100 - $0) } ?? "—"
        return [
            Bubble(label: "SESSIONS", value: s.sessions.formatted(), sub: "recorded",
                   size: .lg, anchor: UnitPoint(x: 0.5, y: 0.5), phase: 0),
            Bubble(label: "TOP", value: "\(topValue)%", sub: "of users",
                   size: .sm, anchor: UnitPoint(x: 0.5, y: 0.14), phase: 1),
            Bubble(label: "STREAK", value: "\(s.streak)", sub: "days",
                   size: .sm, anchor: UnitPoint(x: 0.82, y: 0.2), phase: 2),
            Bubble(label: "SAVED", value: StatsFormat.shortDuration(s.timeSavedSeconds), sub: "vs typing",
                   size: .sm, anchor: UnitPoint(x: 0.18, y: 0.2), phase: 3),
            Bubble(label: "WORDS", value: StatsFormat.compactCount(s.totalUnits), sub: "transcribed",
                   size: .md, anchor: UnitPoint(x: 0.78, y: 0.82), phase: 4),
            Bubble(label: "BUSIEST", value: StatsFormat.shortDay(s.busiestDay), sub: "day",
                   size: .md, anchor: UnitPoint(x: 0.22, y: 0.82), phase: 5)
        ]
    }
}

// MARK: - Formatting

enum StatsFormat {
    /// `m:ss` elapsed/duration clock used by the recording dock and recording rows.
    /// Non-finite/negative clamps to 0:00 (`Int(NaN)` would trap).
    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.isFinite ? max(0, seconds) : 0)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func hoursMinutes(_ seconds: TimeInterval) -> String {
        // `Int(NaN/Inf)` traps; clamp non-finite (and negatives) to 0 before formatting.
        let total = Int(seconds.isFinite ? max(0, seconds) : 0)
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    static func shortDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.isFinite ? max(0, seconds) : 0)
        let h = total / 3600
        if h > 0 { return "\(h)h" }
        return "\(total / 60)m"
    }

    static func compactCount(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 10_000 { return "\(n / 1000)K" }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1000) }
        return "\(n)"
    }

    static func fullCount(_ n: Int) -> String { n.formatted() }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d"
        return f
    }()

    static func shortDay(_ date: Date?) -> String {
        guard let date else { return "—" }
        return dayFormatter.string(from: date)
    }

}

// MARK: - ViewModel

@MainActor
final class StatsViewModel: ObservableObject {
    enum LoadState {
        case loading
        case loaded(StatsSnapshot)
        case empty
        case failed
    }

    @Published private(set) var state: LoadState = .loading

    private var reloadTask: Task<Void, Never>?

    var snapshot: StatsSnapshot? {
        if case .loaded(let s) = state { return s }
        return nil
    }

    private var hasLoadedOnce = false

    func load() {
        Task { await reload() }
    }

    /// Load only the first time. Re-visiting the Stats tab keeps the existing
    /// snapshot (instant), while notifications refresh it in the background — so
    /// switching tabs never shows the loading skeleton again.
    func loadIfNeeded() {
        guard !hasLoadedOnce else { return }
        hasLoadedOnce = true
        Task { await reload() }
    }

    /// Debounced full reload. Cancels any pending reload first.
    func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    func reload() async {
        do {
            let recordings = try await RecordingStore.shared.fetchAllRecordings()
            let snapshot = await Task.detached(priority: .userInitiated) {
                StatsSnapshot.compute(recordings)
            }.value
            state = snapshot.hasData ? .loaded(snapshot) : .empty
        } catch {
            statsLogger.error("Failed to load stats: \(error, privacy: .public)")
            state = .failed
        }
    }
}

// MARK: - StatsView

struct StatsView: View {
    @ObservedObject var viewModel: StatsViewModel
    @State private var showShareCard = false

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignTokens.bg)
        .onAppear { viewModel.loadIfNeeded() }
        .onReceive(NotificationCenter.default.publisher(for: RecordingStore.recordingsDidUpdateNotification)) { _ in
            viewModel.scheduleReload()
        }
        .onReceive(NotificationCenter.default.publisher(for: RecordingStore.recordingProgressDidUpdateNotification)) { note in
            if let status = note.userInfo?["status"] as? RecordingStatus, status == .completed {
                viewModel.scheduleReload()
            }
        }
        .sheet(isPresented: $showShareCard) {
            if let snapshot = viewModel.snapshot {
                ShareCardSheet(snapshot: snapshot)
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Stats")
                .font(.system(size: 18, weight: .bold))
                .tracking(DesignTokens.trackingTitle * 18)
                .foregroundStyle(DesignTokens.txt)
            Spacer()
            if viewModel.snapshot?.hasData == true {
                Button { showShareCard = true } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Share card")
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(DesignTokens.accOn)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: DesignTokens.radiusButton, style: .continuous)
                            .fill(DesignTokens.acc)
                    )
                }
                .buttonStyle(PrimaryLiftButtonStyle())
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .contentColumn()
        .overlay(alignment: .bottom) {
            Rectangle().fill(DesignTokens.line2).frame(height: 1)
        }
    }

    @ViewBuilder
    private var content: some View {
        ZStack {
            switch viewModel.state {
            case .loading:
                StatsSkeleton()
                    .transition(.opacity)
            case .empty:
                StatsEmptyState()
            case .failed:
                StatsErrorState { viewModel.load() }
            case .loaded(let snapshot):
                ScrollView(showsIndicators: false) {
                    StatsGrid(snapshot: snapshot)
                        .padding(22)
                        .contentColumn()
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isLoaded)
    }

    private var isLoaded: Bool {
        if case .loaded = viewModel.state { return true }
        return false
    }
}

// MARK: - Grid

private struct StatsGrid: View {
    let snapshot: StatsSnapshot
    private let columns = [GridItem(.flexible(), spacing: 12),
                           GridItem(.flexible(), spacing: 12),
                           GridItem(.flexible(), spacing: 12)]

    var body: some View {
        VStack(spacing: 12) {
            HeroPanel(heroes: snapshot.heroes)
            ContributionGraph(daily: snapshot.dailyActivity)
            LazyVGrid(columns: columns, spacing: 12) {
                StatTile(icon: "flame", value: "\(snapshot.streak) days", label: "Current streak")
                StatTile(icon: "text.alignleft", value: StatsFormat.fullCount(snapshot.totalUnits), label: "Total words")
                StatTile(icon: "clock", value: StatsFormat.hoursMinutes(snapshot.spokenSeconds), label: "Spoken time")
                StatTile(icon: "clock.arrow.circlepath", value: StatsFormat.hoursMinutes(snapshot.timeSavedSeconds), label: "Time saved vs typing")
                StatTile(icon: "mic", value: StatsFormat.fullCount(snapshot.sessions), label: "Total sessions")
                StatTile(icon: "chart.bar", value: StatsFormat.shortDay(snapshot.busiestDay), label: "Busiest day")
            }
        }
    }
}

// MARK: - Hero

/// Per-language percentile heroes, rank-ordered (best first) on a single row —
/// all qualifying languages share one line, each card equal-width.
private struct HeroPanel: View {
    let heroes: [StatsSnapshot.LanguageHero]

    var body: some View {
        if heroes.isEmpty {
            HeroCard(tag: "KEEP GOING", topText: "—", caption: "Not enough data yet", emphasized: true)
        } else {
            HStack(spacing: 12) {
                ForEach(Array(heroes.enumerated()), id: \.offset) { idx, h in
                    HeroCard(tag: h.language.displayName.uppercased(),
                             topText: UsageStats.formatTop(100 - h.percentile),
                             caption: "Faster than \(UsageStats.formatTop(h.percentile))% of all users",
                             emphasized: idx == 0)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

private struct HeroCard: View {
    let tag: String
    let topText: String
    let caption: String
    let emphasized: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(DesignTokens.acc.opacity(emphasized ? 1 : 0.4)).frame(width: 6, height: 6)
                Text(tag)
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.1 * 10.5)
                    .foregroundStyle(DesignTokens.txt3)
            }
            // One concatenated Text so "Top X%" scales as a single unit (an HStack of
            // separate Texts truncates to "…" on narrow cards instead of shrinking).
            (
                Text("Top ").font(.system(size: 30, weight: .heavy))
                + Text(topText).font(.system(size: 52, weight: .heavy))
                + Text("%").font(.system(size: 26, weight: .bold))
            )
            .foregroundStyle(emphasized ? DesignTokens.acc : DesignTokens.txt2)
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .padding(.top, 10)
            Text(caption)
                .font(.system(size: 12))
                .foregroundStyle(DesignTokens.txt2)
                .padding(.top, 11)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .background(
            LinearGradient(
                colors: [DesignTokens.bg, DesignTokens.surface3, DesignTokens.accSoft],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(DesignTokens.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Tile

private struct StatTile: View {
    let icon: String
    let value: String
    let label: String
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DesignTokens.acc)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(DesignTokens.accSoft))
                .padding(.bottom, 14)
            Text(value)
                .font(.system(size: 25, weight: .heavy).monospacedDigit())
                .tracking(-0.03 * 25)
                .foregroundStyle(DesignTokens.txt)
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(DesignTokens.txt2)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.radiusCard, style: .continuous)
                .fill(DesignTokens.surface)
                .overlay(RoundedRectangle(cornerRadius: DesignTokens.radiusCard, style: .continuous).stroke(DesignTokens.line, lineWidth: 1))
                .shadow(color: .black.opacity(hovering ? 0.08 : 0.04), radius: hovering ? 6 : 2, y: hovering ? 3 : 1)
        )
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.14), value: hovering)
    }
}

// MARK: - Contribution graph (GitHub-style year heatmap)

private struct ContributionGraph: View {
    let daily: [Date: Int]
    var calendar: Calendar = .current
    var now: Date = Date()
    @State private var hover: (date: Date, count: Int)?

    private let gap: CGFloat = 3

    // Precompute both spans ONCE (init), not per render. The grids are pure date math
    // (~370 Calendar ops for the full year); recomputing them every frame during a
    // window resize is what froze the view. Stored here, looked up by count in body.
    private let weeks53: [[Date?]]
    private let weeks27: [[Date?]]

    init(daily: [Date: Int], calendar: Calendar = .current, now: Date = Date()) {
        self.daily = daily
        self.calendar = calendar
        self.now = now
        self.weeks53 = Self.buildWeeks(Self.fullYearWeeks, calendar: calendar, now: now)
        self.weeks27 = Self.buildWeeks(Self.halfYearWeeks, calendar: calendar, now: now)
    }

    private func weeks(_ count: Int) -> [[Date?]] {
        count >= Self.fullYearWeeks ? weeks53 : weeks27
    }

    /// `count` week-columns ending this week (Sun→Sat per column, weekdays as rows).
    private static func buildWeeks(_ count: Int, calendar: Calendar, now: Date) -> [[Date?]] {
        let today = calendar.startOfDay(for: now)
        let weekday = calendar.component(.weekday, from: today)
        let backToWeekStart = (weekday - calendar.firstWeekday + 7) % 7
        guard let curWeekStart = calendar.date(byAdding: .day, value: -backToWeekStart, to: today),
              let firstWeekStart = calendar.date(byAdding: .day, value: -(count - 1) * 7, to: curWeekStart)
        else { return [] }

        var cols: [[Date?]] = []
        for w in 0..<count {
            guard let weekStart = calendar.date(byAdding: .day, value: w * 7, to: firstWeekStart) else { continue }
            var col: [Date?] = []
            for d in 0..<7 {
                guard let day = calendar.date(byAdding: .day, value: d, to: weekStart) else { col.append(nil); continue }
                col.append(day > today ? nil : day)
            }
            cols.append(col)
        }
        return cols
    }

    private var maxCount: Int { max(daily.values.max() ?? 1, 1) }
    private var totalSessions: Int { daily.values.reduce(0, +) }
    private var activeDays: Int { daily.values.filter { $0 > 0 }.count }

    private func level(_ count: Int) -> Int {
        guard count > 0 else { return 0 }
        let frac = Double(count) / Double(maxCount)
        if frac > 0.66 { return 4 }
        if frac > 0.33 { return 3 }
        if frac > 0.10 { return 2 }
        return 1
    }

    private func cellColor(_ lvl: Int) -> Color {
        switch lvl {
        case 4: return DesignTokens.acc
        case 3: return DesignTokens.acc.opacity(0.66)
        case 2: return DesignTokens.acc.opacity(0.42)
        case 1: return DesignTokens.acc.opacity(0.20)
        default: return DesignTokens.surface3
        }
    }

    private let labelColWidth: CGFloat = 20

    /// Full-year and half-year column spans — the single source for the precomputed
    /// grids (`buildWeeks`), the span lookup (`weeks(_:)`), and `layout(for:)`.
    private static let fullYearWeeks = 53
    private static let halfYearWeeks = 27
    /// Below this cell size the full year is too cramped → fall back to ~6 months.
    private let minComfortableCell: CGFloat = 9

    /// Pick the week span + cell size that best fills the available width: prefer a
    /// full year, but if that forces cells below the comfortable minimum, show ~6
    /// months at a larger cell instead (per the "show half a year if too narrow" idea).
    private func layout(for width: CGFloat) -> (weeks: Int, cell: CGFloat) {
        func cell(_ n: Int) -> CGFloat {
            let usable = width - labelColWidth - gap - CGFloat(n) * gap
            return usable / CGFloat(n)
        }
        let full = cell(Self.fullYearWeeks)
        if full >= minComfortableCell {
            return (Self.fullYearWeeks, min(22, full))
        }
        let half = cell(Self.halfYearWeeks)
        return (Self.halfYearWeeks, max(6, min(22, half)))
    }

    /// Card height tracks the actual cell so 7 rows fill it snugly — no dead space.
    private func cardHeight(cell: CGFloat) -> CGFloat {
        16 /*header*/ + 10 + 12 /*month labels*/ + 10 + (7 * cell + 6 * gap) + 10 + 14 /*legend*/
    }

    @Environment(\.contentRegionWidth) private var regionWidth

    /// Inner width available to the grid. The content column (min region, cap) is
    /// reduced by the two insets between it and this grid: StatsGrid's outer 22pt
    /// padding (44 total) and this card's own 20pt padding (40 total). Subtracting
    /// only the card padding sized the grid 44pt too wide, which forced the card
    /// to balloon past the hero/tile cards. Derived from the authoritative region
    /// width SidebarLayout publishes — never a lagging self-measured value.
    private var innerWidth: CGFloat {
        ContentColumnLayout.columnWidth(region: regionWidth) - (44 + 40)
    }

    var body: some View {
        let l = layout(for: innerWidth)
        return VStack(alignment: .leading, spacing: 10) {
            header
            monthLabels(cell: l.cell, count: l.weeks)
            grid(cell: l.cell, count: l.weeks)
            legend(cell: 11)
        }
        .frame(maxWidth: .infinity, minHeight: cardHeight(cell: l.cell), alignment: .topLeading)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.radiusCard, style: .continuous)
                .fill(DesignTokens.surface)
                .overlay(RoundedRectangle(cornerRadius: DesignTokens.radiusCard, style: .continuous).stroke(DesignTokens.line, lineWidth: 1))
        )
    }

    private var header: some View {
        HStack {
            Text("Activity")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(DesignTokens.txt)
            Spacer()
            if let h = hover {
                Text("\(Self.fullDate.string(from: h.date)) · \(h.count) \(h.count == 1 ? "session" : "sessions")")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DesignTokens.txt2)
            } else {
                Text("\(totalSessions) sessions · \(activeDays) active days")
                    .font(.system(size: 12))
                    .foregroundStyle(DesignTokens.txt3)
            }
        }
    }

    private func monthLabels(cell: CGFloat, count: Int) -> some View {
        // Label the first column that *starts* a new month (its top cell's day ≤ 7),
        // so a label sits above the column the month actually begins in — not on a
        // column that's mostly the previous month. Drop labels < 3 columns apart to
        // avoid crowding (a month spanning few visible weeks).
        let cols = weeks(count)
        var labels: [(Int, String)] = []
        var lastMonth = -1
        for (i, col) in cols.enumerated() {
            guard let firstDay = col.compactMap({ $0 }).first else { continue }
            let m = calendar.component(.month, from: firstDay)
            let dom = calendar.component(.day, from: firstDay)
            guard m != lastMonth, dom <= 7 else { continue }
            if let last = labels.last, i - last.0 < 3 { lastMonth = m; continue }
            labels.append((i, Self.month.string(from: firstDay)))
            lastMonth = m
        }
        return ZStack(alignment: .topLeading) {
            ForEach(Array(labels.enumerated()), id: \.offset) { _, item in
                Text(item.1)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(DesignTokens.txt3)
                    .offset(x: CGFloat(item.0) * (cell + gap))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 12)
        .padding(.leading, labelColWidth + gap)
    }

    /// The grid is a single Canvas (one draw pass) instead of ~370 individual cell
    /// views — view-tree churn on every resize frame is what spiked CPU. Hover is
    /// resolved from the pointer position against the same column/row geometry.
    private func grid(cell: CGFloat, count: Int) -> some View {
        let cols = weeks(count)
        let step = cell + gap
        let gridWidth = labelColWidth + gap + CGFloat(count) * step - gap
        let gridHeight = 7 * cell + 6 * gap

        return Canvas { ctx, _ in
            for (ci, col) in cols.enumerated() {
                let x = labelColWidth + gap + CGFloat(ci) * step
                for d in 0..<7 {
                    guard let day = col[d] else { continue }
                    let y = CGFloat(d) * step
                    let rect = CGRect(x: x, y: y, width: cell, height: cell)
                    let path = Path(roundedRect: rect, cornerRadius: 2.5)
                    ctx.fill(path, with: .color(cellColor(level(daily[day] ?? 0))))
                    let isHover = hover?.date == day
                    ctx.stroke(path, with: .color(isHover ? DesignTokens.acc : DesignTokens.line2),
                               lineWidth: isHover ? 1.5 : 0.5)
                }
            }
        }
        .frame(width: gridWidth, height: gridHeight, alignment: .topLeading)
        .overlay(alignment: .topLeading) {
            // Weekday labels drawn as a thin overlay column (cheap, 7 texts).
            VStack(alignment: .leading, spacing: gap) {
                ForEach(0..<7, id: \.self) { d in
                    Text(weekdayLabel(d))
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(DesignTokens.txt3)
                        .frame(width: labelColWidth, height: cell, alignment: .leading)
                }
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let p):
                hover = dayAt(point: p, cols: cols, cell: cell, step: step)
            case .ended:
                hover = nil
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Map a pointer location to the (date, count) under it, or nil if over a gap.
    private func dayAt(point p: CGPoint, cols: [[Date?]], cell: CGFloat, step: CGFloat) -> (date: Date, count: Int)? {
        let gridX = p.x - (labelColWidth + gap)
        guard gridX >= 0 else { return nil }
        let ci = Int(gridX / step)
        let di = Int(p.y / step)
        guard ci >= 0, ci < cols.count, di >= 0, di < 7 else { return nil }
        // Reject the inter-cell gap.
        guard (gridX - CGFloat(ci) * step) <= cell, (p.y - CGFloat(di) * step) <= cell else { return nil }
        guard let day = cols[ci][di] else { return nil }
        return (day, daily[day] ?? 0)
    }

    private func legend(cell: CGFloat) -> some View {
        HStack(spacing: 4) {
            Text("Learn how sessions are counted")
                .font(.system(size: 10))
                .foregroundStyle(DesignTokens.txt3)
            Spacer()
            Text("Less").font(.system(size: 9)).foregroundStyle(DesignTokens.txt3)
            ForEach(0..<5, id: \.self) { lvl in
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(cellColor(lvl))
                    .frame(width: 11, height: 11)
                    .overlay(RoundedRectangle(cornerRadius: 2.5, style: .continuous).stroke(DesignTokens.line2, lineWidth: 0.5))
            }
            Text("More").font(.system(size: 9)).foregroundStyle(DesignTokens.txt3)
        }
        .padding(.top, 2)
    }

    private func weekdayLabel(_ row: Int) -> String {
        // row is offset from firstWeekday; GitHub shows Mon/Wed/Fri.
        let symbols = calendar.shortWeekdaySymbols
        let idx = (calendar.firstWeekday - 1 + row) % 7
        return (row % 2 == 1) ? String(symbols[idx].prefix(3)) : ""
    }

    private static let month: DateFormatter = {
        let f = DateFormatter(); f.locale = .current; f.dateFormat = "MMM"; return f
    }()
    private static let fullDate: DateFormatter = {
        let f = DateFormatter(); f.locale = .current; f.dateFormat = "MMM d, yyyy"; return f
    }()
}

// MARK: - States

private struct StatsEmptyState: View {
    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: "chart.bar")
                .font(.system(size: 34))
                .foregroundStyle(DesignTokens.txt3)
            Text("No stats yet")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(DesignTokens.txt)
            Text("Record to see your voice stats.")
                .font(.system(size: 13))
                .foregroundStyle(DesignTokens.txt2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct StatsErrorState: View {
    let onRetry: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30))
                .foregroundStyle(DesignTokens.txt3)
            Text("Unable to load stats")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DesignTokens.txt)
            Button("Retry", action: onRetry)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct StatsSkeleton: View {
    @State private var shimmer = false

    private var fill: some ShapeStyle {
        LinearGradient(
            colors: [DesignTokens.surface3, DesignTokens.surface3.opacity(0.55), DesignTokens.surface3],
            startPoint: shimmer ? .init(x: 1, y: 0) : .init(x: -1, y: 0),
            endPoint: shimmer ? .init(x: 2, y: 0) : .init(x: 0, y: 0)
        )
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(fill).frame(height: 120)
                }
            }
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(fill).frame(height: 208)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                ForEach(0..<6, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(fill).frame(height: 96)
                }
            }
        }
        .padding(22)
        .contentColumn()
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false)) { shimmer = true }
        }
    }
}

// MARK: - Button style (hover lift, matches mockup .btn:hover)

struct PrimaryLiftButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .offset(y: hovering ? -1 : 0)
            .shadow(color: .black.opacity(hovering ? 0.12 : 0.05), radius: hovering ? 6 : 2, y: hovering ? 2 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .onHover { hovering = $0 }
            .animation(.easeInOut(duration: 0.14), value: hovering)
    }
}
