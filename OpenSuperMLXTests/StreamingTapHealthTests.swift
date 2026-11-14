import XCTest
@testable import OpenSuperMLX

final class StreamingTapHealthTests: XCTestCase {
    func testFreshTapStateNeedsRecovery() {
        let health = MicrophoneCaptureBuffer(capacity: 8)

        XCTAssertFalse(health.hasReceivedAudio)
    }

    func testCallbackClearsRecoveryNeed() {
        let health = MicrophoneCaptureBuffer(capacity: 8)
        health.begin(at: 10)
        [Float(0)].withUnsafeBufferPointer {
            health.receive($0, hostTime: 10, sampleRate: 48000, deliveredAt: 20)
        }
        XCTAssertTrue(health.hasReceivedAudio)
        XCTAssertEqual(health.callbackCount, 1)
    }

    func testRecordedSamplesMarkSessionCaptureAvailable() {
        var health = StreamingCaptureHealth()

        health.recordSamplesCaptured(1600)
        health.recordSamplesCaptured(-10)

        XCTAssertTrue(health.hasCapturedSamples)
        XCTAssertEqual(health.samplesCaptured, 1600)
    }

    func testTapResetDoesNotEraseSessionCaptureState() {
        let tapHealth = MicrophoneCaptureBuffer(capacity: 8)
        var captureHealth = StreamingCaptureHealth()

        tapHealth.begin(at: 10)
        captureHealth.recordSamplesCaptured(1600)
        tapHealth.close()
        tapHealth.begin(at: 30)

        XCTAssertFalse(tapHealth.hasReceivedAudio)
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
}
