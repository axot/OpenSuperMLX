// EngineInitTransaction.swift
// OpenSuperMLX

import AVFoundation
import CoreAudio
import Foundation
import os

struct EngineInitFormat: Equatable {
    let sampleRate: Double
    let channelCount: Int
    let isInterleaved: Bool

    var isSane: Bool {
        sampleRate > 0 && channelCount > 0 && !isInterleaved
    }
}

struct EngineInitObservation: Equatable {
    let engineRunning: Bool
    let startErrorDescription: String?
    let boundDeviceID: AudioDeviceID?
    let targetDeviceID: AudioDeviceID?
    let deviceSideFormat: EngineInitFormat?
    var bindFailedStatus: OSStatus?
    var cancelled: Bool = false
}

enum EngineInitFailure: Equatable {
    case deviceUnresolvable
    case bindFailed(OSStatus)
    case engineStartFailed(String)
    case deviceReverted
    case invalidGraphFormat
}

enum EngineInitVerdict: Equatable {
    case commit(nativeSampleRate: Double)
    case failExplicit(EngineInitFailure)
    case abandon

    /// User-facing explanation for explicit failures; nil for commit/abandon.
    var failureDescription: String? {
        switch self {
        case .commit, .abandon:
            return nil
        case .failExplicit(.deviceUnresolvable):
            return "Selected microphone not found. Check Settings → Microphone."
        case .failExplicit(.bindFailed):
            return "Could not connect to the selected microphone."
        case .failExplicit(.engineStartFailed):
            return "Microphone failed to start. Try recording again."
        case .failExplicit(.deviceReverted):
            return "The system switched to a different microphone during startup. Recording stopped to avoid capturing the wrong device."
        case .failExplicit(.invalidGraphFormat):
            return "The microphone reported an unsupported audio format."
        }
    }
}

enum EngineInitTransaction {
    /// Decide the outcome of one engine-init attempt from its post-start observation.
    /// `.abandon` (not a failure) is for superseded/cancelled attempts: their state may
    /// be broken through no fault of the current request, so they must stay silent.
    static func evaluate(_ observation: EngineInitObservation) -> EngineInitVerdict {
        guard !observation.cancelled else { return .abandon }
        if let status = observation.bindFailedStatus {
            return .failExplicit(.bindFailed(status))
        }
        guard observation.engineRunning else {
            return .failExplicit(.engineStartFailed(observation.startErrorDescription ?? "unknown error"))
        }
        guard let target = observation.targetDeviceID else {
            return .failExplicit(.deviceUnresolvable)
        }
        guard let bound = observation.boundDeviceID, bound == target else {
            return .failExplicit(.deviceReverted)
        }
        guard let deviceSide = observation.deviceSideFormat, deviceSide.isSane else {
            return .failExplicit(.invalidGraphFormat)
        }
        return .commit(nativeSampleRate: deviceSide.sampleRate)
    }
}

final class EngineInitGate: @unchecked Sendable {
    private struct State {
        var generation = 0
        var inFlightTargetUID: String?
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    /// Registers a request for `targetUID`. A target change supersedes the in-flight
    /// attempt by bumping the generation; a same-target request joins it so concurrent
    /// callers share one init.
    func beginRequest(targetUID: String?) -> Int {
        lock.withLock { state in
            if state.inFlightTargetUID != targetUID {
                state.generation += 1
                state.inFlightTargetUID = targetUID
            }
            return state.generation
        }
    }

    func shouldCommit(generation: Int, targetUID: String?) -> Bool {
        lock.withLock { state in
            state.generation == generation && state.inFlightTargetUID == targetUID
        }
    }

    func endRequest(generation: Int) {
        lock.withLock { state in
            if state.generation == generation {
                state.inFlightTargetUID = nil
            }
        }
    }

    /// Invalidate whatever request is in flight (teardown while initializing). The next
    /// request starts a fresh generation.
    func cancelInFlight() {
        lock.withLock { state in
            state.generation += 1
            state.inFlightTargetUID = nil
        }
    }
}
