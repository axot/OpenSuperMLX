// StreamingInferenceSessionTests.swift
// OpenSuperMLXTests

import XCTest

import MLX
@testable import MLXAudioSTT

final class StreamingInferenceSessionTests: XCTestCase {
    func testEOSOnlyFinalFallbackDoesNotRepeatCommittedTextAfterEmptyDecodes() {
        for emptyChunks in 1...4 {
            assertFinalReplay(
                emptyChunks: emptyChunks, finalTokens: [],
                expectedText: "ABCDEFGHIJKLMNO", expectedDelta: ""
            )
        }
    }

    func testRejectedFinalFallbackDoesNotRepeatCommittedTextAfterEmptyDecodes() {
        assertFinalReplay(
            emptyChunks: 2, finalTokens: Array(repeating: 99, count: 20),
            expectedText: "ABCDEFGHIJKLMNO", expectedDelta: "",
            expectedGuardAction: .recoveryReset
        )
    }

    func testFinalRevisionEmitsOnlyTextBeyondCommittedPrefixAfterRollback() {
        assertFinalReplay(
            emptyChunks: 2, finalTokens: Array(70...81),
            expectedText: "ABCDEFGHIJKLMNOPQ", expectedDelta: "PQ"
        )
    }

    func testShorterFinalTailRevisionStillEmitsNewText() {
        assertFinalReplay(
            emptyChunks: 0, finalTokens: [86, 87],
            expectedText: "ABCDEFGHIJKLMNOVW", expectedDelta: "VW"
        )
    }

    func testFinalDeltaHandlesUnicodeAfterConfirmedTextContracts() {
        for (finalText, expectedDelta) in [
            ("甲乙丙丁戊己庚", ""),
            ("甲乙丙丁戊己庚辛壬癸追加", "追加"),
        ] {
            var state = TextEmissionState()
            _ = state.consume("甲乙丙丁戊己庚辛壬癸")
            _ = state.consume("甲乙丙丁戊己庚")
            _ = state.consume("甲乙丙丁戊")

            XCTAssertEqual(state.consume(finalText, isFinal: true), expectedDelta)
            XCTAssertEqual(state.mergedText, "甲乙丙丁戊己庚辛壬癸" + expectedDelta)
        }
    }

    func testResetAllowsRepeatedPrefixInNextSegmentToFinish() {
        for action in [ChunkAction.periodicReset, .recoveryReset] {
            var state = TextEmissionState()
            _ = state.consume("ABCDE")
            _ = state.consume("ABCDE", action: action)
            _ = state.consume("AB")

            XCTAssertEqual(state.consume("ABC", isFinal: true), "C")
            XCTAssertEqual(state.mergedText, "ABCDEABC")
        }
    }

    func testNonfinalDeltaContinuesToUsePreviousChunk() {
        var state = TextEmissionState()
        _ = state.consume("ABCDEFGHIJKLMNO")
        _ = state.consume("ABCDE")

        XCTAssertEqual(state.consume("ABCDEFGHIJ"), "FGHIJ")
    }

    func testDivergentConfirmedRevisionUpdatesFinalBaseline() {
        var state = TextEmissionState()
        _ = state.consume("ABCDEF")
        XCTAssertEqual(state.consume("AX"), "X")

        XCTAssertEqual(state.consume("AXY", isFinal: true), "Y")
        XCTAssertEqual(state.mergedText, "ABCDEFXY")
    }

    // MARK: - Helpers

    private func assertFinalReplay(
        emptyChunks: Int,
        finalTokens: [Int],
        expectedText: String,
        expectedDelta: String,
        expectedGuardAction: GuardAction? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let config = StreamingConfig()
        var history: [Int] = []
        var committer = StreamingTextCommitter()
        var degenerationGuard = StreamingDegenerationGuard(
            blockPatternMaxPeriod: config.blockPatternMaxPeriod
        )
        var state = TextEmissionState()
        let chunks = [Array(65...84), Array(80...84), Array(80...84)]
            + Array(repeating: [Int](), count: emptyChunks)
        for tokens in chunks {
            let action = degenerationGuard.evaluateChunk(
                prefixTokens: history, newChunkTokens: tokens,
                stableTokenCount: committer.stableTokens.count,
                hitMaxTokens: false, isFinal: false
            )
            guard case .ok(let newTokens) = action else {
                return XCTFail("Unexpected nonfinal rejection", file: file, line: line)
            }
            history = Array(history.dropLast(min(config.rollbackTokens, history.count))) + newTokens
            let result = committer.processChunkTokens(history, isFinal: false)
            _ = state.consume(decode(result.confirmedTokens))
        }
        XCTAssertEqual(state.mergedText, "ABCDEFGHIJKLMNO", file: file, line: line)

        let action = degenerationGuard.evaluateChunk(
            prefixTokens: history, newChunkTokens: finalTokens,
            stableTokenCount: committer.stableTokens.count,
            hitMaxTokens: false, isFinal: true
        )
        XCTAssertEqual(
            action, expectedGuardAction ?? .ok(filteredNewTokens: finalTokens),
            file: file, line: line
        )
        let result = ContinuousChunkProcessor.finalizeDecodedTokens(
            history: &history, guardAction: action,
            committer: &committer, config: config
        )
        let delta = state.consume(decode(result.confirmedTokens), isFinal: true, action: result.action)

        XCTAssertEqual(delta, expectedDelta, file: file, line: line)
        XCTAssertEqual(state.mergedText, expectedText, file: file, line: line)
    }

    private func decode(_ tokens: [Int]) -> String {
        String(tokens.map { Character(UnicodeScalar($0)!) })
    }

    private struct TextEmissionState {
        var previousText = ""
        var finalizationBaseline = ""
        var mergedText = ""

        mutating func consume(
            _ confirmedText: String,
            isFinal: Bool = false,
            action: ChunkAction = .normal
        ) -> String {
            let delta = StreamingInferenceSession.consumeConfirmedText(
                confirmedText,
                previousText: &previousText,
                finalizationBaseline: &finalizationBaseline,
                isFinal: isFinal,
                action: action
            )
            mergedText = TextMergeUtilities.mergeWithOverlapRemoval(
                prefix: mergedText, newText: delta
            )
            return delta
        }
    }
}

final class StreamingInferenceSessionRecoveryTests: XCTestCase {
    func testRecoveryDoesNotEmitAnAlreadyConfirmedTailAgainAfterRollback() async {
        let probe = RecoveryProbe(fails: false, shrinksRecoveryPrefix: true)
        let session = makeSession(probe)
        let eventsTask = Task { await collect(session.events) }
        session.feedAudio(samples: Array(repeating: 0.01, count: 208_000))
        session.stop()
        let events = await eventsTask.value
        XCTAssertEqual(endedText(events), ["before tail replacement tail!"])
    }

    func testPeriodicResetAfterRecoveryDoesNotReemitItsCarriedText() async {
        let probe = RecoveryProbe(fails: false, resetsRecovery: true)
        let session = makeSession(probe)
        let eventsTask = Task { await collect(session.events) }
        session.feedAudio(samples: Array(repeating: 0.01, count: 208_000))
        session.stop()
        let events = await eventsTask.value
        XCTAssertEqual(endedText(events), ["before tail replacement carried continued!"])
    }

    func testRecoveryPendingTailSurvivesStopEvenWhenItRepeatsTheCheckpoint() async {
        await assertPendingRecovery("tail", expected: "before tailtail")
        await assertPendingRecovery("tail", expected: "before tailtail", batches: [128_000, 352_000])
        await assertPostWatchdogContinuation("tail", expected: "before tailtailtail")
        let probe = RecoveryProbe(fails: false, pendingRecoveryText: "tail")
        let session = makeSession(probe)
        let eventsTask = Task { await collect(session.events) }
        session.feedAudio(samples: Array(repeating: 0.01, count: 128_000))
        session.feedAudio(samples: Array(repeating: 0.01, count: 832_000))
        session.stop()
        let events = await eventsTask.value
        XCTAssertGreaterThan(probe.factoryOffsets.filter { $0 == 0 }.count, 1)
        let processedFrames = probe.calls.filter { !$0.isRecovery }.reduce(0) { $0 + $1.end - $1.start }
        XCTAssertGreaterThanOrEqual(processedFrames, 6000)
        XCTAssertLessThanOrEqual(processedFrames, 6001)
        XCTAssertTrue(endedText(events).first?.hasPrefix("before tailtail") == true)
    }

    func testRecoveryPendingTailKeepsItsLeadingSpaceAtStop() async {
        await assertPendingRecovery(" word", expected: "before tail word")
        await assertPostWatchdogContinuation(" word", expected: "before tailtail word")
    }

    func testCheckpointDoesNotAppendPendingTextThatWasAlreadyConfirmed() async {
        let probe = RecoveryProbe(fails: true, shrinksConfirmedPrefix: true)
        let session = makeSession(probe)
        let eventsTask = Task { await collect(session.events) }
        session.feedAudio(samples: Array(repeating: 0.01, count: 160_000))
        session.stop()
        let events = await eventsTask.value
        XCTAssertEqual(endedText(events), ["before tail"])
    }

    func testRecoveryReplacesSuffixAndProcessesQueuedMelOnce() async {
        let probe = RecoveryProbe(fails: false)
        let session = makeSession(probe)
        let eventsTask = Task { await collect(session.events) }
        session.feedAudio(samples: Array(repeating: 0.01, count: 192_000))
        session.stop()
        let events = await eventsTask.value

        XCTAssertEqual(probe.factoryOffsets, [0, 800])
        let retries = probe.calls.filter(\.isRecovery)
        XCTAssertEqual(retries.count, 1)
        XCTAssertEqual(retries.first?.start, 800)
        XCTAssertEqual(retries.first?.end, 1000)
        let continued = probe.calls.filter { !$0.isRecovery && $0.start >= 1000 }
        XCTAssertEqual(continued.count, 1)
        XCTAssertEqual(continued.first?.start, 1000)
        XCTAssertGreaterThanOrEqual(continued.first?.end ?? 0, 1200)
        XCTAssertEqual(endedText(events), ["before tail replacement continued!"])
        XCTAssertFalse(events.contains {
            if case .displayUpdate(let confirmed, _) = $0 { return confirmed.contains("CORRUPT") }
            return false
        })
    }

    func testFailedRecoverySkipsRejectedWindowAndContinuesQueuedAndFutureAudio() async {
        let probe = RecoveryProbe(fails: true)
        let session = makeSession(probe)
        let eventsTask = Task { await collect(session.events) }
        session.feedAudio(samples: Array(repeating: 0.01, count: 192_000))
        session.feedAudio(samples: Array(repeating: 0.01, count: 32_000))
        session.stop()
        let events = await eventsTask.value

        XCTAssertEqual(probe.factoryOffsets, [0, 800, 1000])
        let continued = probe.calls.filter { !$0.isRecovery && $0.start >= 1000 }
        XCTAssertEqual(continued.first?.start, 1000)
        XCTAssertGreaterThanOrEqual(continued.last?.end ?? 0, 1400)
        for (previous, next) in zip(continued, continued.dropFirst()) {
            XCTAssertEqual(previous.end, next.start)
        }
        XCTAssertEqual(endedText(events), ["before tail continued!"])
        XCTAssertFalse(events.contains {
            if case .displayUpdate(let confirmed, let pending) = $0 {
                return (confirmed + pending).contains("UNACCEPTED")
                    || (confirmed + pending).contains("CORRUPT")
            }
            return false
        })
        let complete = events.compactMap { event -> Bool? in
            if case .stats(let stats) = event { return stats.isComplete }
            return nil
        }
        XCTAssertEqual(complete.last, false)
    }

    func testCancelledSessionRejectsMoreAudioAndStopCannotFinishAgain() async {
        let probe = RecoveryProbe(fails: false)
        let session = makeSession(probe)
        let eventsTask = Task { await collect(session.events) }
        session.feedAudio(samples: Array(repeating: 0.01, count: 160_000))
        session.cancel()
        let callsAtCancel = probe.calls.count
        session.feedAudio(samples: Array(repeating: 0.01, count: 192_000))
        session.stop()
        let events = await eventsTask.value
        XCTAssertEqual(probe.calls.count, callsAtCancel)
        XCTAssertEqual(probe.finalizations, 0)
        XCTAssertTrue(endedText(events).isEmpty)
    }

}

final class StreamingInferenceSessionGapTests: XCTestCase {
    func testGapReportsSavedAudioPositionAndTheRejectionReasonOnce() async {
        let probe = RecoveryProbe(fails: true)
        let session = makeSession(probe)
        let eventsTask = Task { await collect(session.events) }
        session.feedAudio(samples: Array(repeating: 0.01, count: 224_000), skippedSamples: 32_000)
        session.stop()
        let events = await eventsTask.value
        let gaps = recoveryGaps(events)

        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps.first?.startSeconds, 10)
        XCTAssertEqual(gaps.first?.endSeconds, 12)
        XCTAssertEqual(gaps.first?.reason, "token_limit generated_tokens=256 eos=false")
        XCTAssertEqual(endedText(events), ["before tail continued!"])
        let completeness = events.compactMap { event -> Bool? in
            if case .stats(let stats) = event { return stats.isComplete }
            return nil
        }
        let afterGap = completeness.drop(while: { $0 })
        XCTAssertGreaterThan(afterGap.count, 1)
        XCTAssertTrue(afterGap.allSatisfy { !$0 })
    }

    func testASecondFailedRecoveryContinuesFromItsOwnEndFrame() async {
        let probe = RecoveryProbe(fails: true)
        probe.additionalFailureFrames = [1400]
        let session = makeSession(probe)
        let eventsTask = Task { await collect(session.events) }
        session.feedAudio(samples: Array(repeating: 0.01, count: 288_000))
        session.stop()
        let events = await eventsTask.value
        let gaps = recoveryGaps(events)

        XCTAssertEqual(gaps.map(\.startSeconds), [8, 10])
        XCTAssertEqual(gaps.map(\.endSeconds), [10, 14])
        XCTAssertEqual(endedText(events), ["before tail continued!"])
        let normal = probe.calls.filter { !$0.isRecovery }
        for (previous, next) in zip(normal, normal.dropFirst()) {
            XCTAssertEqual(previous.end, next.start)
        }
        XCTAssertGreaterThanOrEqual(normal.last?.end ?? 0, 1800)
    }

    func testUnavailableRecoveryInputsReportTheirReasonAndContinue() async {
        for reason in ["checkpoint_unavailable", "recovery_mel_unavailable", "processor_unavailable"] {
            let probe = RecoveryProbe(fails: true)
            probe.unavailableReason = reason
            let session = makeSession(probe)
            let eventsTask = Task { await collect(session.events) }
            session.feedAudio(samples: Array(repeating: 0.01, count: 224_000))
            session.stop()
            let events = await eventsTask.value

            XCTAssertEqual(recoveryGaps(events).first?.reason, reason)
            XCTAssertEqual(recoveryGaps(events).first?.startSeconds, 8)
            XCTAssertEqual(recoveryGaps(events).first?.endSeconds, 10)
            XCTAssertEqual(endedText(events), ["before tail continued!"])
        }
    }

    func testGapTimesDoNotRestartAtZeroAfterWatchdogReset() async {
        let probe = RecoveryProbe(fails: true)
        let session = makeSession(probe)
        let eventsTask = Task { await collect(session.events) }
        session.feedAudio(samples: Array(repeating: 0.01, count: 768_000))
        session.stop()
        let gaps = recoveryGaps(await eventsTask.value)

        XCTAssertEqual(probe.factoryOffsets.filter { $0 == 0 }.count, 2)
        XCTAssertEqual(gaps.map(\.startSeconds), [8, 42])
        XCTAssertEqual(gaps.map(\.endSeconds), [10, 44])
    }

    func testRepeatedRecoveryRetainsOffsetsForTheOldestReachableCheckpoint() async {
        let probe = RecoveryProbe(fails: false)
        probe.failedRecoveryFrames = [5600]
        var config = StreamingConfig()
        config.chunkDurationSeconds = 7
        let session = makeSession(probe, config: config)
        let eventsTask = Task { await collect(session.events) }
        session.feedAudio(samples: Array(repeating: 0.01, count: 16_000), skippedSamples: 32_000)
        session.feedAudio(samples: Array(repeating: 0.01, count: 104_000), skippedSamples: 16_000)
        for _ in 0..<8 {
            session.feedAudio(samples: Array(repeating: 0.01, count: 112_000))
        }
        session.stop()
        let gaps = recoveryGaps(await eventsTask.value)

        XCTAssertEqual(gaps.map(\.startSeconds), [2])
        XCTAssertEqual(gaps.map(\.endSeconds), [59])
        let recoveries = probe.calls.filter(\.isRecovery)
        XCTAssertEqual(recoveries.map(\.start), Array(repeating: 0, count: 7))
        XCTAssertEqual(recoveries.map(\.end), Array(stride(from: 1400, through: 5600, by: 700)))
        XCTAssertTrue(probe.calls.contains { !$0.isRecovery && $0.start == 5600 && $0.end == 6300 })
    }

    func testCancellationAfterFailedRecoverySuppressesCompletion() async {
        let probe = RecoveryProbe(fails: true)
        let session = makeSession(probe)
        let eventsTask = Task { await collect(session.events) }
        session.feedAudio(samples: Array(repeating: 0.01, count: 176_000))
        session.cancel()
        let callsAtCancel = probe.calls.count
        session.feedAudio(samples: Array(repeating: 0.01, count: 32_000))
        session.stop()
        let events = await eventsTask.value
        XCTAssertEqual(recoveryGaps(events).count, 1)
        XCTAssertEqual(probe.calls.count, callsAtCancel)
        XCTAssertTrue(endedText(events).isEmpty)
    }

    func testPaddingFailuresDoNotAddEmptyGapsOrChangeSourceCompleteness() async {
        for (sourceSamples, expectedGapCount) in [(128_000, 0), (160_000, 1)] {
            let probe = RecoveryProbe(fails: true)
            probe.additionalFailureFrames = [1400]
            let session = makeSession(probe, sourceSampleLimit: sourceSamples)
            let eventsTask = Task { await collect(session.events) }
            session.feedAudio(samples: Array(repeating: 0.01, count: 288_000))
            session.stop()
            let events = await eventsTask.value
            let gaps = recoveryGaps(events)
            XCTAssertEqual(gaps.count, expectedGapCount)
            XCTAssertTrue(gaps.allSatisfy { $0.startSeconds < $0.endSeconds })
            let completeness = events.compactMap { event -> Bool? in
                if case .stats(let stats) = event { return stats.isComplete }
                return nil
            }
            XCTAssertEqual(completeness.last, expectedGapCount == 0)
            XCTAssertTrue(probe.factoryOffsets.contains(1400))
        }
    }

    private func recoveryGaps(_ events: [TranscriptionEvent]) -> [StreamingTranscriptionGap] {
        events.compactMap {
            if case .stats(let stats) = $0 { return stats.recoveryGap }
            return nil
        }
    }
}

// MARK: - Model-free Session

private func assertPostWatchdogContinuation(_ text: String, expected: String) async {
    let probe = RecoveryProbe(fails: false, pendingRecoveryText: "tail", resumeAfterWatchdog: text)
    let session = makeSession(probe)
    let eventsTask = Task { await collect(session.events) }
    session.feedAudio(samples: Array(repeating: 0.01, count: 128_000))
    session.feedAudio(samples: Array(repeating: 0.01, count: 512_000))
    session.stop()
    let events = await eventsTask.value
    XCTAssertEqual(probe.factoryOffsets.filter { $0 == 0 }.count, 2)
    XCTAssertEqual(endedText(events), [expected])
}

private func assertPendingRecovery(
    _ text: String, expected: String, batches: [Int] = [176_000]
) async {
    let probe = RecoveryProbe(fails: false, pendingRecoveryText: text)
    let session = makeSession(probe)
    let eventsTask = Task { await collect(session.events) }
    for count in batches {
        session.feedAudio(samples: Array(repeating: 0.01, count: count))
    }
    session.stop()
    let events = await eventsTask.value
    XCTAssertEqual(endedText(events), [expected])
    let processedFrames = probe.calls.filter { !$0.isRecovery }.reduce(0) { $0 + $1.end - $1.start }
    let inputFrames = batches.reduce(0, +) / 160
    XCTAssertGreaterThanOrEqual(processedFrames, inputFrames)
    XCTAssertLessThanOrEqual(processedFrames, inputFrames + 1)
}

private func makeSession(
    _ probe: RecoveryProbe, sourceSampleLimit: Int? = nil, config: StreamingConfig = StreamingConfig()
) -> StreamingInferenceSession {
    StreamingInferenceSession(
        config: config, sampleRate: 16000, melBins: 128,
        sourceSampleLimit: sourceSampleLimit,
        decodeTokens: { String(String.UnicodeScalarView($0.map { Unicode.Scalar($0)! })) },
        makeProcessor: { config, offset in
            probe.factoryOffsets.append(offset)
            if probe.unavailableReason == "processor_unavailable" && config.coldStartChunks == 0 {
                return nil
            }
            return RecoveryProcessor(probe: probe, offset: offset)
        }
    )
}

private func collect(_ stream: AsyncStream<TranscriptionEvent>) async -> [TranscriptionEvent] {
    var events: [TranscriptionEvent] = []
    for await event in stream { events.append(event) }
    return events
}

private func endedText(_ events: [TranscriptionEvent]) -> [String] {
    events.compactMap {
        if case .ended(let text) = $0 { return text }
        return nil
    }
}

private final class RecoveryProbe: @unchecked Sendable {
    struct Call {
        let start: Int
        let end: Int
        let isRecovery: Bool
    }

    let fails: Bool
    let shrinksConfirmedPrefix: Bool
    let pendingRecoveryText: String?
    let shrinksRecoveryPrefix: Bool
    let resetsRecovery: Bool
    let resumeAfterWatchdog: String?
    var factoryOffsets: [Int] = []
    var calls: [Call] = []
    var finalizations = 0
    var additionalFailureFrames: Set<Int> = []
    var failedRecoveryFrames: Set<Int> = []
    var unavailableReason: String?

    init(
        fails: Bool, shrinksConfirmedPrefix: Bool = false, pendingRecoveryText: String? = nil,
        shrinksRecoveryPrefix: Bool = false, resetsRecovery: Bool = false,
        resumeAfterWatchdog: String? = nil
    ) {
        self.fails = fails
        self.shrinksConfirmedPrefix = shrinksConfirmedPrefix
        self.pendingRecoveryText = pendingRecoveryText
        self.shrinksRecoveryPrefix = shrinksRecoveryPrefix
        self.resetsRecovery = resetsRecovery
        self.resumeAfterWatchdog = resumeAfterWatchdog
    }
}

private final class RecoveryProcessor: StreamingChunkProcessing {
    let probe: RecoveryProbe
    var melFrameOffset: Int
    var endMelFrame: Int
    var chunkIndex = 0
    var encodedWindowCount = 0
    var allDecodedTokens: [Int] = []
    private var lastConfirmed: [Int] = []

    init(probe: RecoveryProbe, offset: Int) {
        self.probe = probe
        self.melFrameOffset = offset
        self.endMelFrame = offset
    }

    func processChunk(
        melFrames: MLXArray, language: String, isFinal: Bool, isRecovery: Bool
    ) -> ChunkProcessingResult {
        let start = endMelFrame
        endMelFrame += melFrames.dim(0)
        chunkIndex += 1
        probe.calls.append(.init(start: start, end: endMelFrame, isRecovery: isRecovery))
        if melFrameOffset == 0 && probe.factoryOffsets.filter({ $0 == 0 }).count > 1,
           let text = probe.resumeAfterWatchdog {
            return result(text, pending: "", action: .normal)
        }
        if !isRecovery && ((melFrameOffset == 0 && endMelFrame >= 1000)
            || probe.additionalFailureFrames.contains(endMelFrame)) {
            if probe.unavailableReason == "checkpoint_unavailable" { melFrameOffset = 900 }
            return result("CORRUPT", pending: "UNACCEPTED", action: .repetitionDetected)
        }
        if isRecovery && (probe.fails || probe.failedRecoveryFrames.contains(endMelFrame)) {
            return result("UNACCEPTED", pending: "", action: .recoveryFailed)
        }
        if probe.fails && melFrameOffset >= 1000 {
            return result(
                " continued" + (isFinal ? "!" : ""),
                pending: isFinal ? "" : "!", action: .normal
            )
        }
        if melFrameOffset > 0 {
            if probe.shrinksRecoveryPrefix {
                if isFinal { return result(" replacement tail!", pending: "", action: .normal) }
                return result(
                    isRecovery ? " replacement tail" : " replacement",
                    pending: isRecovery ? " EXTRA" : " tail", action: .normal
                )
            }
            if probe.resetsRecovery && !isRecovery {
                if isFinal { return result(" carried continued!", pending: "", action: .normal) }
                let reset = result(" replacement carried", pending: "", action: .periodicReset)
                allDecodedTokens = " carried".unicodeScalars.map { Int($0.value) }
                return reset
            }
            if let pending = probe.pendingRecoveryText {
                return result(
                    isFinal ? pending : "", pending: isFinal ? "" : pending, action: .normal
                )
            }
            let text = isRecovery ? " replacement" : " replacement continued"
            return result(text + (isFinal ? "!" : ""), pending: isFinal ? "" : "!", action: .normal)
        }
        if probe.shrinksConfirmedPrefix && endMelFrame < 600 {
            return result("before tail", pending: " EXTRA", action: .normal)
        }
        return result("before", pending: " tail", action: .normal)
    }

    func recoveryMel(from startFrame: Int) -> MLXArray? {
        if probe.unavailableReason == "recovery_mel_unavailable" { return nil }
        return MLXArray.zeros([endMelFrame - startFrame, 128])
    }

    func finalizeAccepted() -> ChunkProcessingResult {
        probe.finalizations += 1
        return ChunkProcessingResult(
            confirmedTokens: allDecodedTokens, provisionalTokens: [],
            newlyEmittedTokens: [], action: .normal
        )
    }

    private func result(_ text: String, pending: String, action: ChunkAction) -> ChunkProcessingResult {
        let confirmed = text.unicodeScalars.map { Int($0.value) }
        let provisional = pending.unicodeScalars.map { Int($0.value) }
        let commonPrefix = zip(lastConfirmed, confirmed).prefix(while: { $0 == $1 }).count
        let newlyEmitted = Array(confirmed.dropFirst(commonPrefix))
        lastConfirmed = confirmed
        allDecodedTokens = confirmed + provisional
        return ChunkProcessingResult(
            confirmedTokens: confirmed, provisionalTokens: provisional,
            newlyEmittedTokens: newlyEmitted, action: action,
            rejectionReason: action == .recoveryFailed ? "token_limit generated_tokens=256 eos=false" : nil
        )
    }
}
