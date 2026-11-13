// MicrophoneCaptureRecovery.swift
// OpenSuperMLX

import Foundation

@MainActor
final class MicrophoneCaptureRecovery {
    enum Result: Equatable {
        case restored
        case retryNeeded
        case exhausted
        case abandon
    }

    private var attempts = 0
    private var generation = 0

    func reset() {
        attempts = 0
        generation += 1
    }

    func recover(
        resume: (() async -> Bool)?,
        rebuild: () async -> Bool
    ) async -> Result {
        guard attempts < 2 else { return .exhausted }
        let requestGeneration = generation
        attempts += 1
        if let resume, await resume() {
            guard generation == requestGeneration, !Task.isCancelled else { return .abandon }
            attempts = 0
            return .restored
        }
        guard generation == requestGeneration, !Task.isCancelled else { return .abandon }
        let restored = await rebuild()
        guard generation == requestGeneration, !Task.isCancelled else { return .abandon }
        if restored {
            attempts = 0
            return .restored
        }
        return attempts >= 2 ? .exhausted : .retryNeeded
    }
}
