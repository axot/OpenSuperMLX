// PreparedMicrophoneInput.swift
// OpenSuperMLX

import AVFoundation
import CoreAudio
import Foundation

protocol MicrophoneInputEngine: AnyObject {
    var isRunning: Bool { get }
    var boundDeviceID: AudioDeviceID? { get }
    var format: EngineInitFormat? { get }
    var configurationObject: AnyObject { get }
    var hardwareIsRunning: Bool { get }
    func prepare()
    func start() throws
    func pause()
    func stop()
}

final class PreparedMicrophoneInput: @unchecked Sendable {
    let targetDeviceID: AudioDeviceID
    let buffer: MicrophoneCaptureBuffer
    private let engine: any MicrophoneInputEngine
    private var preparedFormat: EngineInitFormat?

    convenience init(targetDeviceID: AudioDeviceID) throws {
        let buffer = MicrophoneCaptureBuffer(capacity: 48_000 * 30)
        let engine = try NativeMicrophoneInputEngine(targetDeviceID: targetDeviceID, buffer: buffer)
        self.init(targetDeviceID: targetDeviceID, engine: engine, buffer: buffer)
    }

    init(
        targetDeviceID: AudioDeviceID,
        engine: any MicrophoneInputEngine,
        buffer: MicrophoneCaptureBuffer
    ) {
        self.targetDeviceID = targetDeviceID
        self.engine = engine
        self.buffer = buffer
    }

    var isRunning: Bool { engine.isRunning }
    var boundDeviceID: AudioDeviceID? { engine.boundDeviceID }
    var format: EngineInitFormat? { engine.format }
    var configurationObject: AnyObject { engine.configurationObject }
    var hardwareIsRunning: Bool { engine.hardwareIsRunning }
    var preparedVerdict: EngineInitVerdict {
        EngineInitTransaction.evaluate(observation(), requireRunning: false)
    }

    private func observation(startError: String? = nil) -> EngineInitObservation {
        EngineInitObservation(
            engineRunning: engine.isRunning,
            startErrorDescription: startError,
            boundDeviceID: engine.boundDeviceID,
            targetDeviceID: targetDeviceID,
            deviceSideFormat: engine.format
        )
    }

    func prepare() -> EngineInitVerdict {
        engine.prepare()
        let verdict = EngineInitTransaction.evaluate(observation(), requireRunning: false)
        if case .commit = verdict { preparedFormat = engine.format }
        return verdict
    }

    func start(at hostTime: UInt64) -> EngineInitVerdict {
        buffer.begin(at: hostTime)
        return resume()
    }

    func resume() -> EngineInitVerdict {
        guard buffer.isCapturing else {
            pause()
            return .abandon
        }
        let prepared = preparedVerdict
        guard case .commit = prepared else {
            pause()
            return prepared
        }
        if let preparedFormat, preparedFormat != engine.format {
            pause()
            return .failExplicit(.invalidGraphFormat)
        }
        do {
            if !engine.isRunning {
                try engine.start()
            }
            guard buffer.isCapturing else {
                pause()
                return .abandon
            }
            let verdict = EngineInitTransaction.evaluate(observation())
            if case .commit = verdict { return verdict }
            pause()
            return verdict
        } catch {
            pause()
            return .failExplicit(.engineStartFailed(String(describing: error)))
        }
    }

    func pause() {
        buffer.close()
        engine.pause()
    }

    func restart() -> EngineInitVerdict {
        guard buffer.isCapturing else { return .abandon }
        engine.pause()
        return resume()
    }

    func stop() {
        buffer.close()
        engine.stop()
    }
}

// MARK: - Native input

private final class NativeMicrophoneInputEngine: MicrophoneInputEngine {
    private let engine = AVAudioEngine()
    private var configurationObserver: NSObjectProtocol?
    private var isPrepared = false

    init(targetDeviceID: AudioDeviceID, buffer: MicrophoneCaptureBuffer) throws {
        let input = engine.inputNode
        guard let unit = input.audioUnit else { throw EngineInitFailure.deviceUnresolvable }
        let priorDevice = Self.deviceID(unit)
        let configurationSettled = DispatchSemaphore(value: 0)
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { _ in configurationSettled.signal() }

        var deviceID = targetDeviceID
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else { throw EngineInitFailure.bindFailed(status) }
        guard Self.deviceID(unit) == targetDeviceID else { throw EngineInitFailure.deviceReverted }
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              !format.isInterleaved, format.commonFormat == .pcmFormatFloat32 else {
            throw EngineInitFailure.invalidGraphFormat
        }
        let sampleRate = format.sampleRate
        let sink = AVAudioSinkNode { timestamp, frameCount, inputData in
            let deliveredAt = DispatchTime.now().uptimeNanoseconds
            guard frameCount > 0, inputData.pointee.mNumberBuffers > 0,
                  timestamp.pointee.mHostTime > 0,
                  let data = inputData.pointee.mBuffers.mData else { return noErr }
            let count = min(
                Int(frameCount), Int(inputData.pointee.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
            )
            buffer.receive(
                UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count),
                hostTime: UInt64(AVAudioTime.seconds(forHostTime: timestamp.pointee.mHostTime) * 1_000_000_000),
                sampleRate: sampleRate, deliveredAt: deliveredAt
            )
            return noErr
        }
        engine.attach(sink)
        engine.connect(input, to: sink, format: format)
        prepare()
        // Binding changes are handled asynchronously; finish that transaction before enabling I/O.
        if priorDevice != targetDeviceID,
           configurationSettled.wait(timeout: .now() + .milliseconds(500)) == .timedOut {
            throw EngineInitFailure.engineStartFailed("Microphone configuration did not settle")
        }
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        engine.stop()
    }

    var isRunning: Bool { engine.isRunning }
    var boundDeviceID: AudioDeviceID? {
        engine.inputNode.audioUnit.flatMap(Self.deviceID)
    }
    var format: EngineInitFormat? {
        let format = engine.inputNode.inputFormat(forBus: 0)
        return EngineInitFormat(
            sampleRate: format.sampleRate, channelCount: Int(format.channelCount),
            isInterleaved: format.isInterleaved
        )
    }
    var configurationObject: AnyObject { engine }
    var hardwareIsRunning: Bool {
        guard let unit = engine.inputNode.audioUnit else { return false }
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioUnitGetProperty(
            unit, kAudioOutputUnitProperty_IsRunning, kAudioUnitScope_Global, 0,
            &running, &size
        )
        return status == noErr && running != 0
    }

    func prepare() {
        if !isPrepared {
            engine.prepare()
            isPrepared = true
        }
    }

    func start() throws { try engine.start() }
    func pause() { engine.pause() }

    func stop() {
        engine.stop()
        isPrepared = false
    }

    private static func deviceID(_ unit: AudioUnit) -> AudioDeviceID? {
        var deviceID = AudioDeviceID()
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &deviceID, &size
        )
        return status == noErr ? deviceID : nil
    }
}
