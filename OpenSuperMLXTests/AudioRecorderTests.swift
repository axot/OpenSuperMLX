// AudioRecorderTests.swift
// OpenSuperMLXTests

import AVFoundation
import XCTest

@testable import OpenSuperMLX

final class AudioRecorderTests: XCTestCase {

    func testPrepareFailureDoesNotStartRecording() throws {
        let context = try makeContext(prepareResult: false, recordResult: true)

        let started = context.recorder.startRecordingWithRecorder(
            fileURL: context.outputURL,
            monitorConnection: false
        )

        XCTAssertFalse(started)
        XCTAssertFalse(context.backend.recordCalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.outputURL.path))
    }

    func testRecordFailureDoesNotStartRecording() throws {
        let context = try makeContext(prepareResult: true, recordResult: false)

        let started = context.recorder.startRecordingWithRecorder(
            fileURL: context.outputURL,
            monitorConnection: false
        )

        XCTAssertFalse(started)
        XCTAssertTrue(context.backend.recordCalled)
    }

    func testSuccessfulFinishReturnsPlayableURL() async throws {
        let context = try makeContext(prepareResult: true, recordResult: true)
        XCTAssertTrue(context.recorder.startRecordingWithRecorder(
            fileURL: context.outputURL,
            monitorConnection: false
        ))
        try writeTwoSeconds(to: context.outputURL)
        let stopCalled = expectation(description: "backend stop")
        context.backend.onStop = { stopCalled.fulfill() }

        let stopTask = Task { await context.recorder.stopRecording() }
        await fulfillment(of: [stopCalled], timeout: 1)
        context.recorder.audioRecorderDidFinishRecording(
            context.delegateRecorder,
            successfully: true
        )

        let result = await stopTask.value
        XCTAssertEqual(result, context.outputURL)
    }

    func testUnsuccessfulFinishRemovesFileAndReturnsNil() async throws {
        let context = try makeContext(prepareResult: true, recordResult: true)
        XCTAssertTrue(context.recorder.startRecordingWithRecorder(
            fileURL: context.outputURL,
            monitorConnection: false
        ))
        try writeTwoSeconds(to: context.outputURL)
        let stopCalled = expectation(description: "backend stop")
        context.backend.onStop = { stopCalled.fulfill() }

        let stopTask = Task { await context.recorder.stopRecording() }
        await fulfillment(of: [stopCalled], timeout: 1)
        context.recorder.audioRecorderDidFinishRecording(
            context.delegateRecorder,
            successfully: false
        )

        let result = await stopTask.value
        XCTAssertNil(result)
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.outputURL.path))
    }

    func testEncodingErrorRemovesFileAndReturnsNil() async throws {
        let context = try makeContext(prepareResult: true, recordResult: true)
        XCTAssertTrue(context.recorder.startRecordingWithRecorder(
            fileURL: context.outputURL,
            monitorConnection: false
        ))
        try writeTwoSeconds(to: context.outputURL)
        let stopCalled = expectation(description: "backend stop")
        context.backend.onStop = { stopCalled.fulfill() }

        let stopTask = Task { await context.recorder.stopRecording() }
        await fulfillment(of: [stopCalled], timeout: 1)
        context.recorder.audioRecorderEncodeErrorDidOccur(
            context.delegateRecorder,
            error: CocoaError(.fileWriteOutOfSpace)
        )

        let result = await stopTask.value
        XCTAssertNil(result)
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.outputURL.path))
    }

    func testRestartIsRejectedUntilStopDelegateCompletes() async throws {
        let context = try makeContext(prepareResult: true, recordResult: true)
        XCTAssertTrue(context.recorder.startRecordingWithRecorder(
            fileURL: context.outputURL,
            monitorConnection: false
        ))
        try writeTwoSeconds(to: context.outputURL)
        let stopCalled = expectation(description: "backend stop")
        context.backend.onStop = { stopCalled.fulfill() }

        let stopTask = Task { await context.recorder.stopRecording() }
        await fulfillment(of: [stopCalled], timeout: 1)
        context.backend.onStop = nil

        XCTAssertFalse(context.recorder.startRecordingWithRecorder(
            fileURL: context.directory.appendingPathComponent("second.m4a"),
            monitorConnection: false
        ))

        context.recorder.audioRecorderDidFinishRecording(
            context.delegateRecorder,
            successfully: true
        )
        _ = await stopTask.value
        XCTAssertTrue(context.recorder.startRecordingWithRecorder(
            fileURL: context.directory.appendingPathComponent("second.m4a"),
            monitorConnection: false
        ))
        context.recorder.cancelRecording()
    }

    func testConcurrentStopsShareOneBackendStopAndResult() async throws {
        let waitersRegistered = expectation(description: "stop waiters registered")
        waitersRegistered.expectedFulfillmentCount = 2
        let context = try makeContext(
            prepareResult: true,
            recordResult: true,
            onStopWaiterRegistered: { _ in waitersRegistered.fulfill() }
        )
        XCTAssertTrue(context.recorder.startRecordingWithRecorder(
            fileURL: context.outputURL,
            monitorConnection: false
        ))
        try writeTwoSeconds(to: context.outputURL)
        let stopCalled = expectation(description: "backend stop")
        stopCalled.assertForOverFulfill = true
        context.backend.onStop = { stopCalled.fulfill() }

        let first = Task { await context.recorder.stopRecording() }
        let second = Task { await context.recorder.stopRecording() }
        await fulfillment(of: [stopCalled], timeout: 1)
        await fulfillment(of: [waitersRegistered], timeout: 1)
        context.recorder.audioRecorderDidFinishRecording(
            context.delegateRecorder,
            successfully: true
        )

        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertEqual(firstResult, context.outputURL)
        XCTAssertEqual(secondResult, context.outputURL)
        XCTAssertEqual(context.backend.stopCallCount, 1)
    }

    func testCallbackFromDifferentRecorderIsIgnored() async throws {
        let context = try makeContext(prepareResult: true, recordResult: true)
        XCTAssertTrue(context.recorder.startRecordingWithRecorder(
            fileURL: context.outputURL,
            monitorConnection: false
        ))
        try writeTwoSeconds(to: context.outputURL)
        let stopCalled = expectation(description: "backend stop")
        context.backend.onStop = { stopCalled.fulfill() }

        let stopTask = Task { await context.recorder.stopRecording() }
        await fulfillment(of: [stopCalled], timeout: 1)
        let unrelatedRecorder = try AVAudioRecorder(
            url: context.directory.appendingPathComponent("unrelated.m4a"),
            settings: RecordingAudioFormat.aacSettings
        )
        context.recorder.audioRecorderDidFinishRecording(
            unrelatedRecorder,
            successfully: false
        )
        context.recorder.audioRecorderDidFinishRecording(
            context.delegateRecorder,
            successfully: true
        )

        let result = await stopTask.value
        XCTAssertEqual(result, context.outputURL)
    }

    private func makeContext(
        prepareResult: Bool,
        recordResult: Bool,
        onStopWaiterRegistered: @escaping @Sendable (Int) -> Void = { _ in }
    ) throws -> (
        recorder: AudioRecorder,
        backend: FakeAudioRecordingBackend,
        delegateRecorder: AVAudioRecorder,
        directory: URL,
        outputURL: URL
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioRecorderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let delegateRecorder = try makeDelegateRecorder(in: directory)
        let backend = FakeAudioRecordingBackend(
            prepareResult: prepareResult,
            recordResult: recordResult,
            callbackIdentity: ObjectIdentifier(delegateRecorder)
        )
        let recorder = AudioRecorder(
            temporaryDirectory: directory,
            recorderFactory: { _, _ in backend },
            onStopWaiterRegistered: onStopWaiterRegistered
        )
        return (
            recorder,
            backend,
            delegateRecorder,
            directory,
            directory.appendingPathComponent("recording.m4a")
        )
    }

    private func writeTwoSeconds(to url: URL) throws {
        let writer = try AACRecordingWriter(url: url)
        try writer.writeChunk([Float](repeating: 0.1, count: 32_000))
        _ = try writer.finalize()
    }

    private func makeDelegateRecorder(in directory: URL) throws -> AVAudioRecorder {
        try AVAudioRecorder(
            url: directory.appendingPathComponent("delegate.m4a"),
            settings: RecordingAudioFormat.aacSettings
        )
    }
}

private final class FakeAudioRecordingBackend: AudioRecordingBackend {
    weak var delegate: AVAudioRecorderDelegate?
    var isMeteringEnabled = false
    let callbackIdentity: ObjectIdentifier
    private let prepareResult: Bool
    private let recordResult: Bool
    private(set) var recordCalled = false
    private(set) var stopCallCount = 0
    var onStop: (() -> Void)?

    init(
        prepareResult: Bool,
        recordResult: Bool,
        callbackIdentity: ObjectIdentifier
    ) {
        self.prepareResult = prepareResult
        self.recordResult = recordResult
        self.callbackIdentity = callbackIdentity
    }

    func prepareToRecord() -> Bool {
        prepareResult
    }

    func record() -> Bool {
        recordCalled = true
        return recordResult
    }

    func stop() {
        stopCallCount += 1
        onStop?()
    }
}
