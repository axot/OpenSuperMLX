// RecordingDetailsView.swift
// OpenSuperMLX

import AppKit
import Foundation
import SwiftUI

// MARK: - Document

struct RecordingDetailDocument {
    enum ID: Hashable {
        case live(UUID)
        case recording(UUID)
    }

    enum Phase {
        case live, processing, completed
    }

    let id: ID
    let title: String
    let subtitle: String
    let duration: TimeInterval
    let text: String
    let phase: Phase

    var isLive: Bool {
        if case .live = id { return true }
        return false
    }

    var characterCount: Int {
        text.filter { !$0.isWhitespace }.count
    }

    static func live(sessionID: UUID, confirmed: String, provisional: String, deviceName: String,
                     duration: TimeInterval, isProcessing: Bool) -> Self {
        Self(id: .live(sessionID), title: "Current recording", subtitle: deviceName,
             duration: duration, text: confirmed + provisional, phase: isProcessing ? .processing : .live)
    }

    @MainActor static func saved(_ recording: Recording) -> Self {
        Self(id: .recording(recording.id), title: recording.sourceFileName ?? "Recording details",
             subtitle: RecordingRow.relativeDate(recording.timestamp), duration: recording.duration,
             text: recording.transcription, phase: .completed)
    }
}

// MARK: - Details

struct RecordingDetailsView: View {
    let document: RecordingDetailDocument
    let coordinator: TranscriptTextView.Coordinator
    let canReturnToLive: Bool
    let onReturnToLive: () -> Void
    let onClose: () -> Void
    @State private var query = TranscriptSearch.Input(text: "")
    @State private var search = TranscriptSearch()
    @State private var navigationID = 0
    @State private var followsLive = true
    @State private var searchFocusRequest = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            TranscriptTextView(
                document: document, ranges: search.ranges, selectedRange: search.selectedRange,
                navigationID: navigationID, followsLive: document.isLive && followsLive && query.text.isEmpty,
                coordinator: coordinator, onManualScroll: { followsLive = false },
                onEscape: clearSearchOrClose
            )
            .overlay(alignment: .topLeading) {
                if document.text.isEmpty {
                    Text(document.isLive ? "Listening…" : "No speech detected")
                        .font(.system(size: 13))
                        .foregroundStyle(DesignTokens.txt3)
                        .padding(.horizontal, 22)
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                }
            }
            footer
        }
        .background(DesignTokens.bg)
        .onAppear { updateSearch(reset: true) }
        .onChange(of: document.id) { _, _ in
            followsLive = query.text.isEmpty
            updateSearch(reset: true)
        }
        .onChange(of: TranscriptSearch.Input(text: document.text)) { _, _ in updateSearch() }
        .onChange(of: query) { _, _ in
            if !query.text.isEmpty { followsLive = false }
            updateSearch(reset: true)
        }
        .onExitCommand(perform: clearSearchOrClose)
    }

    private var header: some View {
        VStack(spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Text(document.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DesignTokens.txt)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2)
                HStack(spacing: 5) {
                    Circle().fill(statusColor).frame(width: 5, height: 5)
                    Text(statusLabel).font(.system(size: 11))
                }
                .foregroundStyle(statusColor)
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 11))
                        .foregroundStyle(DesignTokens.txt2).frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("Close recording details")
            }
            HStack(spacing: 8) {
                Text(document.subtitle)
                    .lineLimit(1)
                Text("· \(StatsFormat.clock(document.duration))")
                    .fixedSize()
                Spacer(minLength: 0)
                Text("\(document.characterCount.formatted()) characters")
                    .fixedSize()
            }
            .font(.system(size: 11))
            .foregroundStyle(DesignTokens.txt3)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Button { searchFocusRequest += 1 } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12)).foregroundStyle(DesignTokens.txt3)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("f", modifiers: .command)
            .help("Search transcript (⌘F)")
            TranscriptSearchField(
                input: $query, focusRequest: searchFocusRequest,
                onNavigate: moveMatch, onEscape: clearSearchOrClose
            )
            .frame(maxWidth: .infinity)
            if !query.text.isEmpty {
                Text(search.ranges.isEmpty ? "No matches" : "\(search.selectedIndex + 1)/\(search.ranges.count)")
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(DesignTokens.txt2)
                    .fixedSize()
            }
            findButton("chevron.up", help: "Previous match") { moveMatch(-1) }
            findButton("chevron.down", help: "Next match") { moveMatch(1) }
            if !query.text.isEmpty {
                Button {
                    query = .init(text: "")
                    searchFocusRequest += 1
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .help("Clear transcript search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(DesignTokens.surface2)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(DesignTokens.line, lineWidth: 1))
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var footer: some View {
        HStack {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(document.text, forType: .string)
            } label: {
                Label("Copy all", systemImage: "doc.on.doc")
            }
            .help("Copy complete transcript")
            Spacer()
            if document.isLive {
                Button {
                    query = .init(text: "")
                    followsLive.toggle()
                } label: {
                    Label(followsLive ? "Following live" : "Follow live", systemImage: "arrow.down")
                }
                .help("Follow the latest transcription")
            } else if canReturnToLive {
                Button(action: onReturnToLive) {
                    Label("Back to live", systemImage: "arrow.down")
                }
                .help("Show the current recording")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(DesignTokens.txt2)
        .buttonStyle(.plain)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .overlay(alignment: .top) {
            Rectangle().fill(DesignTokens.line2).frame(height: 1)
        }
    }

    private var statusLabel: String {
        switch document.phase {
        case .live: return "Live"
        case .processing: return "Finishing"
        case .completed: return "Completed"
        }
    }

    private var statusColor: Color {
        switch document.phase {
        case .live: return DesignTokens.red
        case .processing: return DesignTokens.txt3
        case .completed: return DesignTokens.green
        }
    }

    private func findButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10)).frame(width: 16, height: 20)
        }
        .buttonStyle(.plain)
        .disabled(search.ranges.isEmpty)
        .help(help)
    }

    private func updateSearch(reset: Bool = false) {
        search.update(text: document.text, query: query.text, resetSelection: reset)
        if reset { navigationID += 1 }
    }

    private func moveMatch(_ direction: Int) {
        search.move(by: direction)
        navigationID += 1
    }

    private func clearSearchOrClose() {
        if query.text.isEmpty {
            onClose()
        } else {
            query = .init(text: "")
        }
    }
}

// MARK: - Native Search

struct TranscriptSearchField: NSViewRepresentable {
    @Binding var input: TranscriptSearch.Input
    let focusRequest: Int
    let onNavigate: (Int) -> Void
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = "Search in transcript…"
        field.font = .systemFont(ofSize: 12)
        field.textColor = NSColor(DesignTokens.txt)
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.onTextChange = { input = .init(text: $0) }
        coordinator.onNavigate = onNavigate
        coordinator.onEscape = onEscape
        if !field.stringValue.utf16.elementsEqual(input.text.utf16) {
            field.stringValue = input.text
            if let editor = field.currentEditor() as? NSTextView {
                editor.string = input.text
            }
        }
        if coordinator.focusRequest != focusRequest {
            coordinator.focusRequest = focusRequest
            Task { @MainActor [weak field] in
                _ = field?.window?.makeFirstResponder(field)
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width,
               height: nsView.intrinsicContentSize.height)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onTextChange: (String) -> Void = { _ in }
        var onNavigate: (Int) -> Void = { _ in }
        var onEscape: () -> Void = {}
        var focusRequest = 0

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            onTextChange(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch NSStringFromSelector(commandSelector) {
            case "cancelOperation:":
                onEscape()
                return true
            case "insertNewline:", "insertNewlineIgnoringFieldEditor:", "insertLineBreak:":
                navigate(modifiers: NSApp.currentEvent?.modifierFlags ?? [])
                return true
            default:
                return false
            }
        }

        func navigate(modifiers: NSEvent.ModifierFlags) {
            onNavigate(modifiers.contains(.shift) ? -1 : 1)
        }
    }
}

// MARK: - Native Transcript

struct TranscriptTextView: NSViewRepresentable {
    let document: RecordingDetailDocument
    let ranges: [NSRange]
    let selectedRange: NSRange?
    let navigationID: Int
    let followsLive: Bool
    let coordinator: Coordinator
    let onManualScroll: () -> Void
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator { coordinator }

    func makeNSView(context: Context) -> TranscriptScrollView {
        let scrollView = TranscriptScrollView()
        let textView = TranscriptNativeTextView()
        textView.onManualScroll = onManualScroll
        textView.onEscape = onEscape
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = .width
        textView.textContainerInset = NSSize(width: 18, height: 4)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        context.coordinator.documentID = nil
        scrollView.onManualScroll = onManualScroll
        let coordinator = context.coordinator
        scrollView.onPositionChange = { [weak coordinator] point in
            if let coordinator, let id = coordinator.documentID {
                coordinator.positions[id] = point
            }
        }
        return scrollView
    }

    func updateNSView(_ scrollView: TranscriptScrollView, context: Context) {
        guard let textView = scrollView.documentView as? TranscriptNativeTextView else { return }
        let coordinator = context.coordinator
        let changedDocument = coordinator.documentID != document.id
        let position = scrollView.contentView.bounds.origin
        let changedText = !textView.string.utf16.elementsEqual(document.text.utf16)
        let changedSearch = coordinator.ranges != ranges || coordinator.selectedRange != selectedRange
        let jump = coordinator.navigationID != navigationID || changedDocument
        scrollView.onManualScroll = onManualScroll
        textView.onManualScroll = onManualScroll
        textView.onEscape = onEscape
        scrollView.isUpdating = true
        textView.isUpdating = true
        defer {
            scrollView.isUpdating = false
            textView.isUpdating = false
        }
        if changedDocument {
            if let id = coordinator.documentID { coordinator.positions[id] = position }
            coordinator.documentID = document.id
            textView.setSelectedRange(NSRange(location: 0, length: 0))
        }
        Self.updateText(textView, text: document.text)
        if changedText || changedSearch || changedDocument {
            Self.highlight(textView, ranges: ranges, selectedRange: selectedRange)
        }
        coordinator.ranges = ranges
        coordinator.selectedRange = selectedRange
        coordinator.navigationID = navigationID
        if let container = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: container)
        }
        if jump, let selectedRange, Self.isValid(selectedRange, in: textView.string) {
            textView.scrollRangeToVisible(selectedRange)
        } else if followsLive {
            textView.scrollRangeToVisible(NSRange(location: (document.text as NSString).length, length: 0))
        } else {
            scrollView.contentView.scroll(to: changedDocument ? coordinator.positions[document.id] ?? .zero : position)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        coordinator.positions[document.id] = scrollView.contentView.bounds.origin
    }

    static func updateText(_ view: NSTextView, text: String) {
        guard !view.string.utf16.elementsEqual(text.utf16) else { return }
        let previous = view.string
        let selection = view.selectedRange()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor(DesignTokens.txt),
            .paragraphStyle: paragraph,
        ]
        let previousLength = (previous as NSString).length
        if text.utf16.prefix(previousLength).elementsEqual(previous.utf16) {
            view.textStorage?.append(NSAttributedString(string: (text as NSString).substring(from: previousLength), attributes: attributes))
        } else {
            view.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))
        }
        let length = (text as NSString).length
        let location = min(selection.location, length)
        view.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
    }

    static func highlight(_ view: NSTextView, ranges: [NSRange], selectedRange: NSRange?) {
        guard let layout = view.layoutManager else { return }
        layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: (view.string as NSString).length))
        for range in ranges where isValid(range, in: view.string) {
            layout.addTemporaryAttribute(
                .backgroundColor,
                value: NSColor(red: 1, green: 0.94, blue: 0.71, alpha: 1),
                forCharacterRange: range
            )
        }
        if let selectedRange, isValid(selectedRange, in: view.string) {
            layout.addTemporaryAttribute(
                .backgroundColor,
                value: NSColor(red: 0.98, green: 0.83, blue: 0.45, alpha: 1),
                forCharacterRange: selectedRange
            )
        }
    }

    private static func isValid(_ range: NSRange, in text: String) -> Bool {
        let length = (text as NSString).length
        return range.location >= 0 && range.location <= length
            && range.length >= 0 && range.length <= length - range.location
    }

    final class Coordinator {
        var documentID: RecordingDetailDocument.ID?
        var positions: [RecordingDetailDocument.ID: NSPoint] = [:]
        var ranges: [NSRange] = []
        var selectedRange: NSRange?
        var navigationID = 0
    }
}

final class TranscriptScrollView: NSScrollView {
    var isUpdating = false
    var onManualScroll: (() -> Void)?
    var onPositionChange: ((NSPoint) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        onManualScroll?()
        super.scrollWheel(with: event)
    }

    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        guard !isUpdating else { return }
        onPositionChange?(clipView.bounds.origin)
        if let event = NSApp.currentEvent, [.leftMouseDragged, .leftMouseDown, .keyDown].contains(event.type) {
            onManualScroll?()
        }
    }
}

final class TranscriptNativeTextView: NSTextView {
    var isUpdating = false
    var onManualScroll: (() -> Void)?
    var onEscape: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if [115, 116, 119, 121, 123, 124, 125, 126].contains(event.keyCode) {
            onManualScroll?()
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func scrollPageUp(_ sender: Any?) {
        if !isUpdating { onManualScroll?() }
        super.scrollPageUp(sender)
    }

    override func scrollPageDown(_ sender: Any?) {
        if !isUpdating { onManualScroll?() }
        super.scrollPageDown(sender)
    }

    override func scrollToBeginningOfDocument(_ sender: Any?) {
        if !isUpdating { onManualScroll?() }
        super.scrollToBeginningOfDocument(sender)
    }

    override func scrollToEndOfDocument(_ sender: Any?) {
        if !isUpdating { onManualScroll?() }
        super.scrollToEndOfDocument(sender)
    }
}
