// MicProbeCommand.swift
// OpenSuperMLX

import AVFoundation
import CoreAudio
import Foundation

import ArgumentParser

// MARK: - Results

struct MicProbeTrial: Encodable {
    let firstDeliveryMS: Double?
    let idleCallbacks: Int
    let idleHardwareRunning: Bool

    enum CodingKeys: String, CodingKey {
        case firstDeliveryMS = "first_delivery_ms"
        case idleCallbacks = "idle_callbacks"
        case idleHardwareRunning = "idle_hardware_running"
    }
}

struct MicProbeResult: Encodable {
    let trials: [MicProbeTrial]
    var passed: Bool {
        !trials.isEmpty && trials.allSatisfy {
            guard let latency = $0.firstDeliveryMS else { return false }
            return latency.isFinite && latency < 100
                && $0.idleCallbacks == 0 && !$0.idleHardwareRunning
        }
    }

    enum CodingKeys: String, CodingKey { case trials, passed }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(trials, forKey: .trials)
        try container.encode(passed, forKey: .passed)
    }
}

// MARK: - Probe command

struct MicProbeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "probe",
        abstract: "Measure paused microphone startup without saving audio"
    )

    @OptionGroup var globalOptions: GlobalOptions
    @Option var iterations: Int = 20

    func validate() throws {
        guard iterations > 0 else { throw ValidationError("Iterations must be greater than zero.") }
    }

    func run() throws {
        let json = globalOptions.json
        let iterations = iterations
        runAsync {
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                  let device = MicrophoneService.shared.activateForRecording(),
                  let deviceID = MicrophoneService.shared.getCoreAudioDeviceID(for: device) else {
                CLIOutput.printError(command: "mic probe", error: .microphoneUnavailable, json: json)
                throw ExitCode(1)
            }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try Self.measure(deviceID: deviceID, iterations: iterations)
                }.value
                CLIOutput.printSuccess(command: "mic probe", data: result, json: json)
                if !result.passed { throw ExitCode(1) }
            } catch let error as ExitCode {
                throw error
            } catch {
                CLIOutput.printError(command: "mic probe", error: .microphoneUnavailable, json: json)
                throw ExitCode(1)
            }
        }
    }

    private static func measure(deviceID: AudioDeviceID, iterations: Int) throws -> MicProbeResult {
        let input = try PreparedMicrophoneInput(targetDeviceID: deviceID)
        defer { input.stop() }
        guard case .commit = input.prepare() else { throw CLIError.microphoneUnavailable }
        var trials: [MicProbeTrial] = []
        for _ in 0..<iterations {
            input.pause()
            Thread.sleep(forTimeInterval: 0.1)
            let idleCount = input.buffer.callbackCount
            Thread.sleep(forTimeInterval: 0.15)
            let idleCallbacks = input.buffer.callbackCount - idleCount
            let idleHardwareRunning = input.hardwareIsRunning
            let verdict = input.start(at: DispatchTime.now().uptimeNanoseconds)
            guard case .commit = verdict else { throw CLIError.microphoneUnavailable }
            let deadline = ContinuousClock.now + .milliseconds(300)
            while !input.buffer.hasReceivedAudio && ContinuousClock.now < deadline {
                Thread.sleep(forTimeInterval: 0.001)
            }
            trials.append(MicProbeTrial(
                firstDeliveryMS: input.buffer.firstBufferLatencyMilliseconds,
                idleCallbacks: idleCallbacks,
                idleHardwareRunning: idleHardwareRunning
            ))
        }
        return MicProbeResult(trials: trials)
    }
}
