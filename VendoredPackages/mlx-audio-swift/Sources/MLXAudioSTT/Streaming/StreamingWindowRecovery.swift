// StreamingWindowRecovery.swift
// MLXAudioSTT

struct StreamingWindowRecovery: Sendable {
    struct Checkpoint: Sendable {
        let frame: Int
        let text: String
    }

    private let windowFrames: Int
    private let maximumWindows: Int
    private var checkpoints = [Checkpoint(frame: 0, text: "")]
    private var lastAccepted = Checkpoint(frame: 0, text: "")
    private(set) var activeCheckpoint: Checkpoint?

    var checkpointCount: Int { checkpoints.count }
    var acceptedText: String { lastAccepted.text }

    init(windowFrames: Int, maximumWindows: Int) {
        precondition(windowFrames > 0 && maximumWindows > 0)
        self.windowFrames = windowFrames
        self.maximumWindows = maximumWindows
    }

    // MARK: - Checkpoints

    mutating func record(endFrame: Int, confirmed: String, pending: String) {
        let snapshot = Checkpoint(frame: endFrame, text: confirmed + pending)
        let boundary: Checkpoint?
        if endFrame % windowFrames == 0 {
            boundary = snapshot
        } else if endFrame / windowFrames > lastAccepted.frame / windowFrames {
            boundary = lastAccepted
        } else {
            boundary = nil
        }
        if let boundary, checkpoints.last?.frame != boundary.frame {
            checkpoints.append(boundary)
            if checkpoints.count > maximumWindows + 1 {
                checkpoints.removeFirst(checkpoints.count - maximumWindows - 1)
            }
        }
        lastAccepted = snapshot
    }

    mutating func begin(endFrame: Int, availableStartFrame: Int) -> Checkpoint? {
        guard endFrame > availableStartFrame else { return nil }
        let windowStart = (endFrame - 1) / windowFrames * windowFrames
        guard let checkpoint = checkpoints.last(where: {
            $0.frame <= windowStart && $0.frame >= availableStartFrame
        }) else { return nil }
        activeCheckpoint = checkpoint
        checkpoints.removeAll { $0.frame > checkpoint.frame }
        lastAccepted = checkpoint
        return checkpoint
    }

    mutating func reset(confirmedPrefix: String = "") {
        let checkpoint = Checkpoint(frame: 0, text: confirmedPrefix)
        checkpoints = [checkpoint]
        lastAccepted = checkpoint
        activeCheckpoint = checkpoint
    }

    // MARK: - Replacement

    func render(_ newText: String) -> String? {
        guard let checkpoint = activeCheckpoint else { return nil }
        return checkpoint.text + newText
    }
}
