// CallDetectionService.swift
// OpenSuperMLX

import AppKit
import CoreAudio
import Foundation
import os.log

private let logger = Logger(subsystem: "OpenSuperMLX", category: "CallDetectionService")

struct CallDetectionResult {
    let isCallActive: Bool
    let callingApp: String?
    let bundleID: String?
}

final class CallDetectionService {
    static let shared = CallDetectionService()

    private let ownPID = ProcessInfo.processInfo.processIdentifier

    private init() {}

    // MARK: - Public API

    func detectActiveCall() -> CallDetectionResult {
        let processObjects = allAudioProcessObjects()
        logger.debug("Found \(processObjects.count) audio process objects")

        for objectID in processObjects {
            guard isRunningInput(objectID), isRunningOutput(objectID) else { continue }
            guard let pid = processPID(for: objectID) else { continue }

            let rawBundleID = processBundleID(for: objectID)
            guard let bundleID = rawBundleID else { continue }

            if isExcludedProcess(bundleID: bundleID, pid: pid) { continue }

            let resolved = resolveParentBundleID(bundleID)
            let appName = resolveAppName(for: resolved)

            logger.info("Active call detected: \(resolved, privacy: .public) (\(appName ?? "unknown", privacy: .public))")

            return CallDetectionResult(
                isCallActive: true,
                callingApp: appName,
                bundleID: resolved
            )
        }

        logger.debug("No active call detected")
        return CallDetectionResult(isCallActive: false, callingApp: nil, bundleID: nil)
    }

    // MARK: - Bundle ID Resolution

    func resolveParentBundleID(_ bundleID: String) -> String {
        guard let helperRange = bundleID.range(of: ".helper", options: .literal) else {
            return bundleID
        }
        return String(bundleID[bundleID.startIndex..<helperRange.lowerBound])
    }

    // MARK: - Process Filtering

    func isExcludedProcess(bundleID: String, pid: pid_t) -> Bool {
        if pid == ownPID { return true }
        if bundleID.contains("com.apple.screencapturekit") { return true }
        if bundleID.contains("com.apple.replayd") { return true }
        return false
    }

    // MARK: - CoreAudio Queries

    private func allAudioProcessObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var propertySize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &propertySize
        ) == noErr, propertySize > 0 else {
            return []
        }

        let count = Int(propertySize) / MemoryLayout<AudioObjectID>.size
        var objects = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &propertySize, &objects
        ) == noErr else {
            return []
        }

        return objects
    }

    private func processPID(for objectID: AudioObjectID) -> pid_t? {
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectGetPropertyData(
            objectID, &address, 0, nil, &size, &pid
        ) == noErr else {
            return nil
        }

        return pid
    }

    private func processBundleID(for objectID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let buffer = UnsafeMutablePointer<UnsafeRawPointer?>.allocate(capacity: 1)
        defer { buffer.deallocate() }
        buffer.initialize(to: nil)

        var size = UInt32(MemoryLayout<UnsafeRawPointer?>.size)
        guard AudioObjectGetPropertyData(
            objectID, &address, 0, nil, &size, buffer
        ) == noErr, let raw = buffer.pointee else {
            return nil
        }

        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    private func isRunningInput(_ objectID: AudioObjectID) -> Bool {
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &isRunning)
        return isRunning != 0
    }

    private func isRunningOutput(_ objectID: AudioObjectID) -> Bool {
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &isRunning)
        return isRunning != 0
    }

    // MARK: - App Name Resolution

    private func resolveAppName(for bundleID: String) -> String? {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        return apps.first?.localizedName
    }
}
