// RecordingClock.swift
// OpenSuperMLX

import Foundation

struct RecordingClock {
    private(set) var startedAt: Date?

    mutating func start(at date: Date = Date()) {
        if startedAt == nil { startedAt = date }
    }

    mutating func stop(reset: Bool = true) {
        if reset { startedAt = nil }
    }

    func elapsed(at date: Date = Date()) -> TimeInterval {
        startedAt.map { max(0, date.timeIntervalSince($0)) } ?? 0
    }
}
