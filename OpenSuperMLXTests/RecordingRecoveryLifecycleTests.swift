// RecordingRecoveryLifecycleTests.swift
// OpenSuperMLXTests

import AppKit
import XCTest

@testable import OpenSuperMLX

@MainActor
final class RecordingRecoveryLifecycleTests: XCTestCase {

    func testCoordinatorBlocksRecordingWhileSaveIsPending() async {
        let coordinator = await makePendingCoordinator()

        XCTAssertTrue(coordinator.blocksNewRecording)
        XCTAssertTrue(coordinator.hasPendingSave)
    }

    func testSaveReservationBlocksBeforeOutcomeIsPrepared() {
        let coordinator = RecordingSaveCoordinator(dependencies: makeFailingDependencies())

        XCTAssertTrue(coordinator.reserveSave())
        XCTAssertTrue(coordinator.blocksNewRecording)
        guard case .saving = coordinator.state else {
            return XCTFail("Expected saving reservation")
        }

        coordinator.releaseSaveReservation()
        XCTAssertTrue(coordinator.isIdle)
    }

    func testContentViewModelShowsRecoveryInsteadOfStarting() async {
        let coordinator = await makePendingCoordinator()
        var presentationCount = 0
        let viewModel = ContentViewModel(
            saveCoordinator: coordinator,
            recoveryPresenter: { presentationCount += 1 }
        )

        viewModel.startRecording()

        XCTAssertEqual(viewModel.state, .idle)
        XCTAssertEqual(presentationCount, 1)
    }

    func testIndicatorViewModelShowsRecoveryInsteadOfStarting() async {
        let coordinator = await makePendingCoordinator()
        var presentationCount = 0
        let viewModel = IndicatorViewModel(
            saveCoordinator: coordinator,
            recoveryPresenter: { presentationCount += 1 }
        )

        viewModel.startRecording()

        XCTAssertEqual(viewModel.state, .idle)
        XCTAssertEqual(presentationCount, 1)
    }

    func testAppDelegateCancelsTerminationAndPresentsRecovery() async {
        let coordinator = await makePendingCoordinator()
        var presentationCount = 0
        let delegate = AppDelegate(
            saveCoordinator: coordinator,
            recoveryPresenter: { presentationCount += 1 }
        )

        let reply = delegate.applicationShouldTerminate(NSApplication.shared)

        XCTAssertEqual(reply, .terminateCancel)
        XCTAssertEqual(presentationCount, 1)
    }

    func testAppDelegateAllowsTerminationWhenNoSaveIsPending() {
        let coordinator = RecordingSaveCoordinator(dependencies: makeFailingDependencies())
        let delegate = AppDelegate(
            saveCoordinator: coordinator,
            recoveryPresenter: {}
        )

        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
    }

    func testCancelledNonStreamingSaveDoesNotInsertText() async {
        let persistStarted = expectation(description: "persistence started")
        let gate = RecoveryCancellationGate()
        let dependencies = RecordingSaveDependencies(
            recordingsDirectory: FileManager.default.temporaryDirectory,
            stagingDirectory: FileManager.default.temporaryDirectory,
            encode: { _, _ in },
            validate: { _, _ in },
            install: { _, _, _ in },
            persist: { _ in
                persistStarted.fulfill()
                await gate.wait()
            },
            deleteRecording: { _ in },
            containsRecording: { _ in false },
            isFileNameTaken: { _ in false },
            removeFile: { _ in },
            fileExists: { _ in false },
            copyText: { _ in true }
        )
        let coordinator = RecordingSaveCoordinator(dependencies: dependencies)
        XCTAssertTrue(coordinator.reserveSave())
        var insertedTexts: [String] = []
        let viewModel = IndicatorViewModel(
            saveCoordinator: coordinator,
            recoveryPresenter: {},
            textInserter: { insertedTexts.append($0) }
        )
        let request = EncodedRecordingSaveRequest(
            text: "do not paste",
            duration: 2,
            audioURL: URL(fileURLWithPath: "/tmp/cancelled-save.m4a"),
            recordingID: UUID(),
            timestamp: Date(),
            fileName: "cancelled-save.m4a"
        )

        let task = Task {
            await viewModel.completeNonStreamingSave(
                request,
                finalText: "do not paste"
            )
        }
        await fulfillment(of: [persistStarted], timeout: 1)
        task.cancel()
        await gate.open()
        await task.value

        XCTAssertTrue(insertedTexts.isEmpty)
    }

    private func makePendingCoordinator() async -> RecordingSaveCoordinator {
        let coordinator = RecordingSaveCoordinator(dependencies: makeFailingDependencies())
        var buffer = PCMRetryBuffer()
        buffer.append([0.1, 0.2])
        let id = UUID()
        let outcome = StreamingCaptureOutcome(
            text: "pending transcript",
            duration: 2,
            audioURL: nil,
            storageError: RecordingStorageError.classify(RecoveryLifecycleTestError.failure),
            retryBuffer: buffer,
            recordingID: id,
            timestamp: Date(),
            fileName: "pending-\(id.uuidString.suffix(4)).m4a"
        )
        _ = await coordinator.save(outcome)
        return coordinator
    }

    private func makeFailingDependencies() -> RecordingSaveDependencies {
        RecordingSaveDependencies(
            recordingsDirectory: FileManager.default.temporaryDirectory,
            stagingDirectory: FileManager.default.temporaryDirectory,
            encode: { _, _ in throw RecoveryLifecycleTestError.failure },
            validate: { _, _ in },
            install: { _, _, _ in },
            persist: { _ in },
            deleteRecording: { _ in },
            containsRecording: { _ in false },
            isFileNameTaken: { _ in false },
            removeFile: { _ in },
            fileExists: { _ in false },
            copyText: { _ in true }
        )
    }
}

private enum RecoveryLifecycleTestError: Error {
    case failure
}

private actor RecoveryCancellationGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}
