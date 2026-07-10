// TranscriptSessionStore.swift
// OpenSuperMLX

import Foundation

enum TranscriptSegmentKind: String, Codable, Equatable {
    case final
    case provisional
}

struct TranscriptSegment: Codable, Equatable {
    let sessionID: String
    let cursor: String
    let sequence: Int
    let startMs: Int
    let endMs: Int
    let kind: TranscriptSegmentKind
    let text: String
    let createdAt: Date
}

struct TranscriptDelta: Codable, Equatable {
    let sessionID: String
    let nextCursor: String?
    let hasMore: Bool
    let segments: [TranscriptSegment]
}

struct TranscriptWindow: Codable, Equatable {
    let sessionID: String
    let anchorCursor: String
    let segments: [TranscriptSegment]
}

struct TranscriptSearchResponse: Codable, Equatable {
    let sessionID: String
    let query: String
    let matches: [TranscriptSearchMatch]
}

struct TranscriptSearchMatch: Codable, Equatable {
    let segment: TranscriptSegment
    let context: [TranscriptSegment]
}

struct TranscriptSessionSummary: Codable, Equatable {
    let sessionID: String
    let startedAt: Date
    let endedAt: Date?
    let segmentCount: Int
    let latestCursor: String?
}

enum TranscriptSessionStoreError: LocalizedError, Equatable {
    case noActiveSession
    case sessionNotFound(String)
    case cursorNotFound(String)
    case invalidCursor(String)
    case emptyQuery

    var errorDescription: String? {
        switch self {
        case .noActiveSession:
            return "No transcript session is active."
        case .sessionNotFound(let sessionID):
            return "Transcript session not found: \(sessionID)"
        case .cursorNotFound(let cursor):
            return "Transcript cursor not found: \(cursor)"
        case .invalidCursor(let cursor):
            return "Invalid transcript cursor: \(cursor)"
        case .emptyQuery:
            return "Search query must not be empty."
        }
    }
}

final class TranscriptSessionStore {
    static let shared = TranscriptSessionStore()

    private struct SessionState {
        let id: String
        let startedAt: Date
        var endedAt: Date?
        var segments: [TranscriptSegment] = []
        var nextSequence = 1
        var lastConfirmedText = ""
        var lastProvisionalText = ""
        var lastElapsedMs = 0
    }

    private let lock = NSLock()
    private var sessions: [String: SessionState] = [:]
    private var latestSessionID: String?

    // MARK: - Session Lifecycle

    @discardableResult
    func startSession(sessionID: String? = nil, startedAt: Date = Date()) -> String {
        lock.lock()
        defer { lock.unlock() }

        let resolvedSessionID = sessionID ?? Self.makeSessionID()
        sessions[resolvedSessionID] = SessionState(id: resolvedSessionID, startedAt: startedAt)
        latestSessionID = resolvedSessionID
        return resolvedSessionID
    }

    func endSession(sessionID: String, finalText: String? = nil, elapsedMs: Int? = nil, endedAt: Date = Date()) throws {
        lock.lock()
        defer { lock.unlock() }

        guard var state = sessions[sessionID] else {
            throw TranscriptSessionStoreError.sessionNotFound(sessionID)
        }

        if let finalText {
            appendConfirmedDelta(
                finalText,
                to: &state,
                elapsedMs: elapsedMs ?? state.lastElapsedMs
            )
        }
        state.lastProvisionalText = ""
        state.endedAt = endedAt
        sessions[sessionID] = state
    }

    func listSessions(limit: Int = 20) -> [TranscriptSessionSummary] {
        lock.lock()
        defer { lock.unlock() }

        return sessions.values
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(max(0, limit))
            .map(Self.summary)
    }

    // MARK: - Writes

    @discardableResult
    func appendSegment(
        sessionID: String,
        kind: TranscriptSegmentKind,
        text: String,
        startMs: Int,
        endMs: Int,
        createdAt: Date = Date()
    ) throws -> TranscriptSegment {
        lock.lock()
        defer { lock.unlock() }

        guard var state = sessions[sessionID] else {
            throw TranscriptSessionStoreError.sessionNotFound(sessionID)
        }

        let segment = makeSegment(
            state: state,
            kind: kind,
            text: text,
            startMs: startMs,
            endMs: endMs,
            createdAt: createdAt
        )
        state.nextSequence += 1
        state.segments.append(segment)
        state.lastElapsedMs = max(state.lastElapsedMs, endMs)
        if kind == .final {
            state.lastConfirmedText += text
        } else {
            state.lastProvisionalText = text
        }
        sessions[sessionID] = state
        return segment
    }

    func recordDisplayUpdate(
        sessionID: String,
        confirmedText: String,
        provisionalText: String,
        elapsedMs: Int
    ) throws {
        lock.lock()
        defer { lock.unlock() }

        guard var state = sessions[sessionID] else {
            throw TranscriptSessionStoreError.sessionNotFound(sessionID)
        }

        appendConfirmedDelta(confirmedText, to: &state, elapsedMs: elapsedMs)
        if !provisionalText.isEmpty && provisionalText != state.lastProvisionalText {
            let segment = makeSegment(
                state: state,
                kind: .provisional,
                text: provisionalText,
                startMs: state.lastElapsedMs,
                endMs: elapsedMs,
                createdAt: Date()
            )
            state.nextSequence += 1
            state.segments.append(segment)
        }
        state.lastProvisionalText = provisionalText
        state.lastElapsedMs = max(state.lastElapsedMs, elapsedMs)
        sessions[sessionID] = state
    }

    // MARK: - Reads

    func transcriptDelta(
        sessionID requestedSessionID: String?,
        afterCursor: String?,
        maxSegments: Int,
        includeProvisional: Bool
    ) throws -> TranscriptDelta {
        lock.lock()
        defer { lock.unlock() }

        let sessionID = try resolveSessionID(requestedSessionID)
        let state = try requireState(sessionID)
        let afterSequence = try afterCursor.map(Self.parseCursor) ?? 0
        let filtered = state.segments
            .filter { includeProvisional || $0.kind == .final }
            .filter { $0.sequence > afterSequence }
        let bounded = Array(filtered.prefix(max(0, maxSegments)))

        return TranscriptDelta(
            sessionID: sessionID,
            nextCursor: bounded.last?.cursor ?? afterCursor,
            hasMore: filtered.count > bounded.count,
            segments: bounded
        )
    }

    func transcriptWindow(
        sessionID requestedSessionID: String?,
        aroundCursor: String,
        beforeSegments: Int,
        afterSegments: Int,
        includeProvisional: Bool
    ) throws -> TranscriptWindow {
        lock.lock()
        defer { lock.unlock() }

        let sessionID = try resolveSessionID(requestedSessionID)
        let state = try requireState(sessionID)
        _ = try Self.parseCursor(aroundCursor)

        let filtered = state.segments.filter { includeProvisional || $0.kind == .final }
        guard let anchorIndex = filtered.firstIndex(where: { $0.cursor == aroundCursor }) else {
            throw TranscriptSessionStoreError.cursorNotFound(aroundCursor)
        }

        let start = max(0, anchorIndex - max(0, beforeSegments))
        let end = min(filtered.count, anchorIndex + max(0, afterSegments) + 1)
        return TranscriptWindow(
            sessionID: sessionID,
            anchorCursor: aroundCursor,
            segments: Array(filtered[start..<end])
        )
    }

    func searchTranscript(
        query: String,
        sessionID requestedSessionID: String?,
        limit: Int,
        contextSegments: Int,
        includeProvisional: Bool
    ) throws -> TranscriptSearchResponse {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            throw TranscriptSessionStoreError.emptyQuery
        }

        lock.lock()
        defer { lock.unlock() }

        let sessionID = try resolveSessionID(requestedSessionID)
        let state = try requireState(sessionID)
        let searchable = state.segments.filter { includeProvisional || $0.kind == .final }
        let contextCount = max(0, contextSegments)
        var matches: [TranscriptSearchMatch] = []

        for index in searchable.indices {
            guard matches.count < max(0, limit) else { break }
            guard searchable[index].text.range(
                of: trimmedQuery,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) != nil else { continue }

            let start = max(searchable.startIndex, index - contextCount)
            let end = min(searchable.endIndex, index + contextCount + 1)
            matches.append(TranscriptSearchMatch(
                segment: searchable[index],
                context: Array(searchable[start..<end])
            ))
        }

        return TranscriptSearchResponse(
            sessionID: sessionID,
            query: trimmedQuery,
            matches: matches
        )
    }

    // MARK: - Private

    private func appendConfirmedDelta(_ confirmedText: String, to state: inout SessionState, elapsedMs: Int) {
        let delta = Self.confirmedDelta(previous: state.lastConfirmedText, current: confirmedText)
        guard !delta.isEmpty else {
            state.lastConfirmedText = confirmedText
            return
        }

        let segment = makeSegment(
            state: state,
            kind: .final,
            text: delta,
            startMs: state.lastElapsedMs,
            endMs: elapsedMs,
            createdAt: Date()
        )
        state.nextSequence += 1
        state.segments.append(segment)
        state.lastConfirmedText = confirmedText
    }

    private func makeSegment(
        state: SessionState,
        kind: TranscriptSegmentKind,
        text: String,
        startMs: Int,
        endMs: Int,
        createdAt: Date
    ) -> TranscriptSegment {
        TranscriptSegment(
            sessionID: state.id,
            cursor: Self.makeCursor(sequence: state.nextSequence),
            sequence: state.nextSequence,
            startMs: max(0, startMs),
            endMs: max(max(0, startMs), endMs),
            kind: kind,
            text: text,
            createdAt: createdAt
        )
    }

    private func resolveSessionID(_ sessionID: String?) throws -> String {
        if let sessionID, !sessionID.isEmpty {
            return sessionID
        }
        guard let latestSessionID else {
            throw TranscriptSessionStoreError.noActiveSession
        }
        return latestSessionID
    }

    private func requireState(_ sessionID: String) throws -> SessionState {
        guard let state = sessions[sessionID] else {
            throw TranscriptSessionStoreError.sessionNotFound(sessionID)
        }
        return state
    }

    private static func summary(_ state: SessionState) -> TranscriptSessionSummary {
        TranscriptSessionSummary(
            sessionID: state.id,
            startedAt: state.startedAt,
            endedAt: state.endedAt,
            segmentCount: state.segments.count,
            latestCursor: state.segments.last?.cursor
        )
    }

    private static func makeSessionID() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return "live-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8))"
    }

    private static func makeCursor(sequence: Int) -> String {
        String(format: "seg_%06d", sequence)
    }

    private static func parseCursor(_ cursor: String) throws -> Int {
        guard cursor.hasPrefix("seg_"),
              let sequence = Int(cursor.dropFirst(4)),
              sequence >= 0 else {
            throw TranscriptSessionStoreError.invalidCursor(cursor)
        }
        return sequence
    }

    private static func confirmedDelta(previous: String, current: String) -> String {
        if current.hasPrefix(previous) {
            return String(current.dropFirst(previous.count))
        }
        return current
    }
}
