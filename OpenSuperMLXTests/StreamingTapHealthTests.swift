import XCTest
@testable import OpenSuperMLX

final class StreamingTapHealthTests: XCTestCase {
    func testFreshTapStateNeedsRecovery() {
        let health = StreamingTapHealth()

        XCTAssertTrue(health.needsRecovery)
    }

    func testCallbackClearsRecoveryNeed() {
        var health = StreamingTapHealth()

        health.recordCallback()

        XCTAssertFalse(health.needsRecovery)
        XCTAssertEqual(health.callbacks, 1)
    }

    func testRecordedSamplesMarkSessionCaptureAvailable() {
        var health = StreamingCaptureHealth()

        health.recordSamplesWritten(1600)
        health.recordSamplesWritten(-10)

        XCTAssertTrue(health.hasCapturedSamples)
        XCTAssertEqual(health.samplesWritten, 1600)
    }

    func testTapResetDoesNotEraseSessionCaptureState() {
        var tapHealth = StreamingTapHealth()
        var captureHealth = StreamingCaptureHealth()

        tapHealth.recordCallback()
        captureHealth.recordSamplesWritten(1600)
        tapHealth = StreamingTapHealth()

        XCTAssertTrue(tapHealth.needsRecovery)
        XCTAssertTrue(captureHealth.hasCapturedSamples)
    }

    func testFeedLoopContinuesOnlyWhileNotCancelledAndNotStopped() {
        XCTAssertTrue(StreamingAudioService.shouldContinueFeedLoop(
            isCancelled: false,
            shouldStop: false
        ))
        XCTAssertFalse(StreamingAudioService.shouldContinueFeedLoop(
            isCancelled: true,
            shouldStop: false
        ))
        XCTAssertFalse(StreamingAudioService.shouldContinueFeedLoop(
            isCancelled: false,
            shouldStop: true
        ))
        XCTAssertFalse(StreamingAudioService.shouldContinueFeedLoop(
            isCancelled: true,
            shouldStop: true
        ))
    }

    func testFeedLoopSleepReturnsFalseWhenCancelled() async {
        let task = Task {
            await StreamingAudioService.waitForNextFeedIteration()
        }

        task.cancel()

        let didSleep = await task.value
        XCTAssertFalse(didSleep)
    }

    func testSpeechDetectionPublishesOnlyOnChange() {
        XCTAssertTrue(StreamingAudioService.shouldPublishSpeechDetection(
            lastPublished: nil,
            current: false
        ))
        XCTAssertFalse(StreamingAudioService.shouldPublishSpeechDetection(
            lastPublished: false,
            current: false
        ))
        XCTAssertTrue(StreamingAudioService.shouldPublishSpeechDetection(
            lastPublished: false,
            current: true
        ))
        XCTAssertTrue(StreamingAudioService.shouldPublishSpeechDetection(
            lastPublished: true,
            current: false
        ))
    }
}
