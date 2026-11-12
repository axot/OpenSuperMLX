// IndicatorWindowTests.swift
// OpenSuperMLXTests

import XCTest

@testable import OpenSuperMLX

final class IndicatorWindowTests: XCTestCase {
    func testCapturingStatesIncludeConnectionAndRecording() {
        XCTAssertTrue(RecordingState.connecting.isCapturing)
        XCTAssertTrue(RecordingState.recording.isCapturing)
        for state in [RecordingState.idle, .decoding, .correcting, .busy] {
            XCTAssertFalse(state.isCapturing)
        }
    }

    func testProcessingStatesIncludeDecodingAndCorrection() {
        XCTAssertTrue(RecordingState.decoding.isProcessing)
        XCTAssertTrue(RecordingState.correcting.isProcessing)
        for state in [RecordingState.idle, .connecting, .recording, .busy] {
            XCTAssertFalse(state.isProcessing)
        }
    }

    func testBusyOverlayDoesNotCreateARecordingSession() {
        XCTAssertFalse(RecordingState.idle.hasRecordingSession)
        XCTAssertFalse(RecordingState.busy.hasRecordingSession)
        for state in [RecordingState.connecting, .recording, .decoding, .correcting] {
            XCTAssertTrue(state.hasRecordingSession)
        }
    }

    // MARK: - Level History

    func testAppendingLevelDropsOldestSampleAtCapacity() {
        let history = IndicatorViewModel.appendingLevel(0.9, to: [0.1, 0.2, 0.3], capacity: 3)

        XCTAssertEqual(history, [0.2, 0.3, 0.9])
    }

    func testAppendingLevelGrowsUntilCapacity() {
        let history = IndicatorViewModel.appendingLevel(0.5, to: [0.1], capacity: 3)

        XCTAssertEqual(history, [0.1, 0.5])
    }

    // MARK: - Elapsed Time

    func testFormatElapsedShowsMinutesAndSeconds() {
        XCTAssertEqual(IndicatorViewModel.formatElapsed(0), "0:00")
        XCTAssertEqual(IndicatorViewModel.formatElapsed(7.9), "0:07")
        XCTAssertEqual(IndicatorViewModel.formatElapsed(83), "1:23")
    }

    func testFormatElapsedAddsHoursPastOneHour() {
        XCTAssertEqual(IndicatorViewModel.formatElapsed(3723), "1:02:03")
    }
}

// MARK: - Voice Command

@MainActor
final class IndicatorViewModelCommandTests: XCTestCase {

    func testDictationInsertsTranscript() async {
        var inserted: [String] = []
        let viewModel = IndicatorViewModel(textInserter: { inserted.append($0) }, commandRunner: { _, _ in
            XCTFail("Dictation must not run a command"); return .applied
        })

        await viewModel.deliver("hello world")

        XCTAssertEqual(inserted, ["hello world"])
    }

    func testCommandModeSendsTranscriptAsInstructionInsteadOfInserting() async {
        var inserted: [String] = []
        var received: (String, String?)?
        let viewModel = IndicatorViewModel(textInserter: { inserted.append($0) }, commandRunner: { instruction, selection in
            received = (instruction, selection?.text)
            return .applied
        })
        let selection = PromptPresetService.Selection(text: "hello world", target: .init(selectedText: "hello world"))

        viewModel.prepareCommand(selection: selection)
        await viewModel.deliver("translate this to Farsi")

        XCTAssertTrue(inserted.isEmpty)
        XCTAssertEqual(received?.0, "translate this to Farsi")
        XCTAssertEqual(received?.1, "hello world")
    }

    func testCommandLabelSaysWhetherASelectionWasCaptured() {
        let viewModel = IndicatorViewModel(textInserter: { _ in })
        XCTAssertNil(viewModel.commandLabel)

        viewModel.prepareCommand(selection: nil)
        XCTAssertEqual(viewModel.commandLabel, "New text")

        viewModel.prepareCommand(selection: .init(text: "hi", target: .init(selectedText: "hi")))
        XCTAssertEqual(viewModel.commandLabel, "Edit selection")
    }
}
