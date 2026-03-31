// DualTrackDecision.swift
// OpenSuperMLX

import Foundation

enum DualTrackDecision {

    static func shouldUseDualTrack(
        resolvedSource: ResolvedAudioSource,
        hasScreenRecordingPermission: Bool
    ) -> Bool {
        guard resolvedSource.mode == .dualTrack else { return false }
        guard hasScreenRecordingPermission else { return false }
        return true
    }

    static func shouldProcessSystemAudio(
        recordingDuration: TimeInterval,
        systemAudioURL: URL?
    ) -> Bool {
        guard systemAudioURL != nil else { return false }
        guard recordingDuration >= 2.0 else { return false }
        return true
    }
}
