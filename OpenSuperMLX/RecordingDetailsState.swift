// RecordingDetailsState.swift
// OpenSuperMLX

import Foundation

// MARK: - Selection

struct RecordingDetailsState {
    enum Selection: Equatable {
        case live
        case recording(UUID)
    }

    private(set) var selection: Selection?
    private(set) var liveSessionID = UUID()
    private(set) var lastSavedRecordingID: UUID?

    mutating func selectRecording(_ id: UUID) {
        selection = .recording(id)
    }

    mutating func toggleCurrent(isRecording: Bool) {
        let target: Selection?
        if isRecording {
            target = .live
        } else {
            target = lastSavedRecordingID.map(Selection.recording)
        }
        selection = selection == target ? nil : target
    }

    mutating func recordingCompleted(_ id: UUID) {
        lastSavedRecordingID = id
        if selection == .live {
            selection = .recording(id)
        }
    }

    mutating func beginRecording() {
        liveSessionID = UUID()
        lastSavedRecordingID = nil
    }

    mutating func recordingStopped(savedID: UUID?) {
        if let savedID {
            recordingCompleted(savedID)
        } else if selection == .live {
            selection = nil
        }
    }

    mutating func clearRecordings() {
        lastSavedRecordingID = nil
        if case .recording = selection {
            selection = nil
        }
    }

    mutating func removeRecording(_ id: UUID) {
        if selection == .recording(id) {
            selection = nil
        }
        if lastSavedRecordingID == id {
            lastSavedRecordingID = nil
        }
    }

    mutating func close() {
        selection = nil
    }
}

// MARK: - Live Snapshot

struct LiveTranscriptSnapshot {
    private(set) var confirmed = ""
    private(set) var provisional = ""

    var text: String { confirmed + provisional }

    mutating func capture(confirmed: String, provisional: String) {
        self.confirmed = confirmed
        self.provisional = provisional
    }
}
