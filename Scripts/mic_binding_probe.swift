// mic_binding_probe.swift — standalone feasibility probe (no app dependencies).
//
// Answers, against real hardware:
//   Q1: Does a non-default kAudioOutputUnitProperty_CurrentDevice binding on
//       AVAudioEngine.inputNode survive engine.start() when the system default
//       input is a different device?
//   Q2: What does inputNode.inputFormat(forBus: 0) report before bind vs after
//       start (does the format follow the bound device)?
//   Q3: Can CurrentDevice be read back from the AU (the verify primitive)?
//   Q4: Do late .AVAudioEngineConfigurationChange notifications arrive after a
//       successful bind+start?
//   Q5: Does a tap installed at the post-start live format deliver buffers?
//
// Build: swiftc Scripts/mic_binding_probe.swift -o /tmp/mic_binding_probe
// Run:   /tmp/mic_binding_probe [targetUID]

import AVFoundation
import CoreAudio
import Foundation

func deviceUID(_ id: AudioDeviceID) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var uid: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &uid)
    guard status == noErr, let cf = uid?.takeRetainedValue() else { return nil }
    return cf as String
}

func deviceName(_ id: AudioDeviceID) -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceNameCFString,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr,
          let cf = name?.takeRetainedValue() else { return "?" }
    return cf as String
}

func defaultInputDeviceID() -> AudioDeviceID? {
    var deviceID = AudioDeviceID()
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
    ) == noErr, deviceID != 0 else { return nil }
    return deviceID
}

func allInputDeviceIDs() -> [AudioDeviceID] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
    ) == noErr, size > 0 else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
    ) == noErr else { return [] }

    let streamsAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams,
        mScope: kAudioDevicePropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )
    return ids.filter { id in
        var streamSize: UInt32 = 0
        var addr = streamsAddress
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &streamSize) == noErr
            && streamSize > 0
    }
}

func boundDeviceID(of engine: AVAudioEngine) -> (AudioDeviceID, OSStatus) {
    guard let au = engine.inputNode.audioUnit else { return (0, -1) }
    var deviceID = AudioDeviceID()
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioUnitGetProperty(
        au,
        kAudioOutputUnitProperty_CurrentDevice,
        kAudioUnitScope_Global, 0,
        &deviceID, &size
    )
    return (deviceID, status)
}

func describe(_ format: AVAudioFormat?) -> String {
    guard let f = format else { return "nil" }
    return "\(Int(f.sampleRate))Hz x\(f.channelCount)ch \(f.commonFormat) interleaved=\(f.isInterleaved)"
}

final class Box: @unchecked Sendable {
    var count = 0
    var sampleRate: Double = 0
    let mutex = NSLock()
}

// MARK: - Probe

let args = CommandLine.arguments
let explicitTarget = args.count > 1 ? args[1] : nil

let defaultInput = defaultInputDeviceID()
print("system default input: id=\(defaultInput.map(String.init) ?? "nil") uid=\(defaultInput.flatMap(deviceUID) ?? "nil") name=\(defaultInput.map(deviceName) ?? "nil")")

let inputs = allInputDeviceIDs()
print("input-capable devices (\(inputs.count)):")
for id in inputs {
    let marker = id == defaultInput ? "  [default]" : ""
    print("  id=\(id) uid=\(deviceUID(id) ?? "nil") name=\(deviceName(id))\(marker)")
}

guard let defaultID = defaultInput else {
    print("PROBE FAIL: no default input device")
    exit(2)
}

// Pick a non-default target: explicit arg, else any other input-capable device.
let target: AudioDeviceID
if let explicitTarget,
   let resolved = inputs.first(where: { deviceUID($0) == explicitTarget }) {
    target = resolved
    print("explicit target: id=\(target) name=\(deviceName(target))")
} else {
    guard let other = inputs.first(where: { $0 != defaultID }) else {
        print("PROBE SKIP: only one input device; cannot test non-default binding")
        exit(0)
    }
    target = other
    print("chosen non-default target: id=\(target) name=\(deviceName(target))")
}

let permission = AVCaptureDevice.authorizationStatus(for: .audio)
print("mic permission: \(permission.rawValue) (0=notDetermined 1=denied 2=restricted 3=granted)")

let engine = AVAudioEngine()
let inputNode = engine.inputNode

print("\n--- pre-bind ---")
print("input format:  \(describe(inputNode.inputFormat(forBus: 0)))")
print("output format: \(describe(inputNode.outputFormat(forBus: 0)))")
let (preBindBound, preBindStatus) = boundDeviceID(of: engine)
print("AU CurrentDevice read: id=\(preBindBound) status=\(preBindStatus) (Q3: \(preBindStatus == noErr ? "readback works" : "READBACK FAILS"))")

print("\n--- bind (AudioUnitSetProperty CurrentDevice -> target) ---")
var targetID = target
let inputAU = inputNode.audioUnit
let bindStatus: OSStatus
if let inputAU {
    bindStatus = AudioUnitSetProperty(
        inputAU,
        kAudioOutputUnitProperty_CurrentDevice,
        kAudioUnitScope_Global, 0,
        &targetID, UInt32(MemoryLayout<AudioDeviceID>.size)
    )
} else {
    bindStatus = -1
}
print("bind status=\(bindStatus) (\(bindStatus == noErr ? "ok" : "BIND FAILED"))")
let (postBindBound, _) = boundDeviceID(of: engine)
print("post-bind AU device: id=\(postBindBound) target=\(target) match=\(postBindBound == target)")
print("post-bind input format:  \(describe(inputNode.inputFormat(forBus: 0)))")
print("post-bind output format: \(describe(inputNode.outputFormat(forBus: 0)))")

var configChangeCount = 0
let configLock = NSLock()
let observer = NotificationCenter.default.addObserver(
    forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
) { _ in
    configLock.lock()
    configChangeCount += 1
    let n = configChangeCount
    configLock.unlock()
    print(">>> configChange notification #\(n) at +\(Int(Date().timeIntervalSince(start)) * 1)s")
}

print("\n--- engine.start() ---")
let start = Date()
do {
    try engine.start()
    print("start ok (took \(Int(Date().timeIntervalSince(start) * 1000))ms)")
} catch {
    print("PROBE FAIL: engine.start threw: \(error)")
    exit(3)
}

let (postStartBound, postStartStatus) = boundDeviceID(of: engine)
print("post-start AU device: id=\(postStartBound) target=\(target) match=\(postStartBound == target) readStatus=\(postStartStatus)")
print("Q1 (binding survives start): \(postStartBound == target ? "YES" : "NO — REVERTED")")
print("post-start input format:  \(describe(inputNode.inputFormat(forBus: 0)))")
print("post-start output format: \(describe(inputNode.outputFormat(forBus: 0)))")
print("engine.isRunning=\(engine.isRunning)")

print("\n--- tap install at post-start live format (Q5) ---")
let liveFormat = inputNode.inputFormat(forBus: 0)
let box = Box()
inputNode.installTap(onBus: 0, bufferSize: 4096, format: liveFormat) { buffer, _ in
    box.mutex.lock()
    box.count += 1
    if box.sampleRate == 0 { box.sampleRate = buffer.format.sampleRate }
    box.mutex.unlock()
}
print("tap installed without exception at \(describe(liveFormat))")

let runSeconds: UInt32 = permission == .authorized ? 2 : 1
print("running \(runSeconds)s...")
sleep(runSeconds)

box.mutex.lock()
let callbacks = box.count
let tapRate = box.sampleRate
box.mutex.unlock()
print("tap callbacks in \(runSeconds)s: \(callbacks) bufferFormatRate=\(Int(tapRate))")
print("Q5 (tap delivers): \(callbacks > 0 ? "YES" : (permission == .authorized ? "NO" : "N/A — mic permission not granted, silence expected"))")

configLock.lock()
let changes = configChangeCount
configLock.unlock()
print("Q4 (late configChange after bind+start): \(changes == 0 ? "none" : "\(changes) received")")

inputNode.removeTap(onBus: 0)
engine.stop()
print("\nPROBE DONE result=\(postStartBound == target ? "BINDING_STABLE" : "BINDING_REVERTS")")
