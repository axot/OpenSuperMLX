import AVFoundation
import XCTest

@testable import OpenSuperMLX

@MainActor
final class StreamingAudioServiceGraphTests: XCTestCase {
    func testInputOnlyEngineIsPlainMicGraph() {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        let status = StreamingAudioService.plainMicGraphStatus(
            engine: engine,
            inputNode: inputNode
        )

        XCTAssertTrue(status.isPlainMicGraph)
        XCTAssertTrue(status.unexpectedNodeTypes.isEmpty)
        XCTAssertEqual(status.outputConnectionCount, 0)
    }

    func testOutputNodeMakesGraphNonPlain() {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        _ = engine.outputNode

        let status = StreamingAudioService.plainMicGraphStatus(
            engine: engine,
            inputNode: inputNode
        )

        XCTAssertFalse(status.isPlainMicGraph)
        XCTAssertTrue(status.unexpectedNodeTypes.contains("AVAudioOutputNode"))
    }

    func testAttachedMixerMakesGraphNonPlain() {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let mixer = AVAudioMixerNode()
        engine.attach(mixer)

        let status = StreamingAudioService.plainMicGraphStatus(
            engine: engine,
            inputNode: inputNode
        )

        XCTAssertFalse(status.isPlainMicGraph)
        XCTAssertTrue(status.unexpectedNodeTypes.contains("AVAudioMixerNode"))
    }

    func testInputOutputConnectionMakesGraphNonPlain() {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let mixer = AVAudioMixerNode()
        engine.attach(mixer)
        engine.connect(inputNode, to: mixer, format: nil)

        let status = StreamingAudioService.plainMicGraphStatus(
            engine: engine,
            inputNode: inputNode
        )

        XCTAssertFalse(status.isPlainMicGraph)
        XCTAssertEqual(status.outputConnectionCount, 1)
    }
}
