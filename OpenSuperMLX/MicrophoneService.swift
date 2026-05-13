import AVFoundation
import Combine
import CoreAudio
import Foundation
import os

// MARK: - AudioDeviceChangeObserver

protocol AudioDeviceChangeObserver: AnyObject {
    func onDeviceDisappeared(deviceID: AudioDeviceID)
    func onEngineConfigurationChanged()
}

// MARK: - MicrophoneService

final class MicrophoneService: ObservableObject {
    static let shared = MicrophoneService()
    
    @Published var availableMicrophones: [AudioDevice] = []
    @Published var selectedMicrophone: AudioDevice?
    @Published var currentMicrophone: AudioDevice?
    @Published var speakerCaptureEnabled: Bool = false

    /// True iff the toggle is on AND the current output is a headphone (per
    /// OutputDeviceClassifier). Speaker output forces mic-only regardless of toggle.
    @MainActor
    var effectiveSpeakerCaptureActive: Bool {
        guard speakerCaptureEnabled,
              let uid = getCurrentOutputUID(),
              OutputDeviceClassifier.shared.classification(for: uid) == .headphone
        else { return false }
        return true
    }

    private var speakerCaptureCancellable: AnyCancellable?
    private var deviceChangeObserver: Any?
    private var timer: Timer?
    private let logger = Logger(subsystem: "OpenSuperMLX", category: "MicrophoneService")
    
    var isDeviceAlive: ((AudioDeviceID) -> Bool) = { deviceID in
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        return status == noErr
    }
    
    struct AudioDevice: Identifiable, Equatable, Codable {
        let id: String
        let name: String
        let manufacturer: String?
        let isBuiltIn: Bool
        
        static func == (lhs: AudioDevice, rhs: AudioDevice) -> Bool {
            return lhs.id == rhs.id
        }
        
        var displayName: String {
            return name
        }
    }
    
    private init() {
        loadSavedMicrophone()
        speakerCaptureEnabled = AppPreferences.shared.speakerCaptureEnabled
        refreshAvailableMicrophones()
        setupDeviceMonitoring()
        updateCurrentMicrophone()
        setupSpeakerCaptureSync()
        setupOutputDeviceListener()
    }
    
    deinit {
        speakerCaptureCancellable?.cancel()
        if let observer = deviceChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        timer?.invalidate()
    }

    // MARK: - Speaker Capture Sync

    private func setupSpeakerCaptureSync() {
        speakerCaptureCancellable = $speakerCaptureEnabled
            .dropFirst()
            .sink { newValue in
                AppPreferences.shared.speakerCaptureEnabled = newValue
            }
    }

    // MARK: - Output Device Listener

    #if os(macOS)
    private func setupOutputDeviceListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            nil
        ) { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.markCurrentOutputAsUsed()
                }
                NotificationCenter.default.post(name: .outputDeviceDidChange, object: nil)
            }
        }
        if status != noErr {
            logger.warning("Failed to register output device change listener (status \(status, privacy: .public))")
        }
        // Initial mark on construction so an already-classified default device gets its
        // lastUsedAt refreshed on every app launch. `MicrophoneService.shared` is first
        // touched from `OpenSuperMLXApp.init`, which runs on the main thread.
        MainActor.assumeIsolated {
            self.markCurrentOutputAsUsed()
        }
    }

    @MainActor
    private func markCurrentOutputAsUsed() {
        guard let id = getSystemDefaultOutputDeviceID(),
              let uid = getDeviceUID(id) else { return }
        let displayName = getDeviceDisplayName(id) ?? String(uid.prefix(16))
        OutputDeviceClassifier.shared.markUsed(uid: uid, displayName: displayName)
    }

    func getCurrentOutputUID() -> String? {
        getSystemDefaultOutputDeviceID().flatMap { getDeviceUID($0) }
    }

    func getCurrentOutputDisplayName() -> String? {
        guard let id = getSystemDefaultOutputDeviceID() else { return nil }
        return getDeviceDisplayName(id)
    }

    func getDeviceDisplayName(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name)
        guard status == noErr, let cf = name?.takeRetainedValue() else { return nil }
        return cf as String
    }
    #else
    private func setupOutputDeviceListener() {}
    func getCurrentOutputUID() -> String? { nil }
    func getCurrentOutputDisplayName() -> String? { nil }
    func getDeviceDisplayName(_ deviceID: AudioDeviceID) -> String? { nil }
    #endif
    
    private func setupDeviceMonitoring() {
        deviceChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasConnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let wasSelectedAvailable = self.selectedMicrophone.map { self.isDeviceAvailable($0) } ?? false
            self.refreshAvailableMicrophones()
            self.updateCurrentMicrophone()

            if let selected = self.selectedMicrophone,
               !wasSelectedAvailable,
               self.isDeviceAvailable(selected) {
                self.logger.info("Selected microphone reconnected: \(selected.name, privacy: .public)")
                NotificationCenter.default.post(
                    name: .microphoneDidChange,
                    object: nil,
                    userInfo: ["device": selected]
                )
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasDisconnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let previousMic = self.currentMicrophone
            self.refreshAvailableMicrophones()
            self.updateCurrentMicrophone()

            if let previous = previousMic, !self.isDeviceAvailable(previous) {
                self.logger.warning("Active microphone disconnected: \(previous.name, privacy: .public)")
                NotificationCenter.default.post(
                    name: .microphoneDisconnected,
                    object: nil,
                    userInfo: ["device": previous]
                )
            }
        }
    }
    
    func refreshAvailableMicrophones() {
        let deviceTypes: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            deviceTypes = [.microphone, .external]
        } else {
            deviceTypes = [.microphone, .external, .builtInMicrophone]
        }
        
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .audio,
            position: .unspecified
        )
        
        let allDevices = discoverySession.devices
            .map { device in
                let isBuiltIn = isBuiltInDevice(device)
                return AudioDevice(
                    id: device.uniqueID,
                    name: device.localizedName,
                    manufacturer: device.manufacturer,
                    isBuiltIn: isBuiltIn
                )
            }

        availableMicrophones = allDevices.filter { device in
            !isAggregateDevice(device) && hasRealInputStream(device) && !isConferencingVirtualDevice(device)
        }

        var seenKeys = Set<String>()
        availableMicrophones = availableMicrophones.filter { device in
            let transport = getTransportType(for: device)
            let key = "\(device.name)|\(transport)"
            return seenKeys.insert(key).inserted
        }

        if AppPreferences.shared.debugMode {
            logger.debug("[DEBUG] Discovered \(self.availableMicrophones.count, privacy: .public) microphones: \(self.availableMicrophones.map { $0.name }.joined(separator: ", "), privacy: .public)")
        }
        
        if availableMicrophones.isEmpty {
            selectedMicrophone = nil
            currentMicrophone = nil
        }
    }
    
    private func isBuiltInDevice(_ device: AVCaptureDevice) -> Bool {
        #if os(macOS)
        if #available(macOS 14.0, *) {
            if device.deviceType == .microphone {
                let uniqueID = device.uniqueID.lowercased()
                if uniqueID.contains("builtin") || uniqueID.contains("internal") {
                    return true
                }
            }
        } else {
            if device.deviceType == .builtInMicrophone {
                return true
            }
        }
        
        let manufacturer = device.manufacturer
        let mfr = manufacturer.lowercased()
        if mfr.contains("apple") {
            let uniqueID = device.uniqueID.lowercased()
            let name = device.localizedName.lowercased()
            
            let isContinuity = name.contains("iphone") || name.contains("continuity") || name.contains("handoff") ||
                               uniqueID.contains("iphone") || uniqueID.contains("continuity") || uniqueID.contains("handoff")
            
            if uniqueID.contains("builtin") || 
               uniqueID.contains("internal") ||
               (!uniqueID.contains("usb") &&
               !uniqueID.contains("bluetooth") &&
               !uniqueID.contains("airpods") &&
               !isContinuity) {
                return true
            }
        }
        
        return false
        #else
        return device.deviceType == .builtInMicrophone
        #endif
    }
    
    private func updateCurrentMicrophone() {
        guard let selected = selectedMicrophone else {
            currentMicrophone = getDefaultMicrophone()
            return
        }
        
        if isDeviceAvailable(selected) {
            currentMicrophone = selected
        } else {
            currentMicrophone = getDefaultMicrophone()
        }
    }
    
    func isDeviceAvailable(_ device: AudioDevice) -> Bool {
        return availableMicrophones.contains(where: { $0.id == device.id })
    }
    
    func getDefaultMicrophone() -> AudioDevice? {
        firstPhysicalMicrophone() ?? availableMicrophones.first
    }

    private func firstPhysicalMicrophone() -> AudioDevice? {
        availableMicrophones.first(where: { $0.isBuiltIn && !isVirtualDevice($0) })
            ?? availableMicrophones.first(where: { !isVirtualDevice($0) })
    }
    
    func selectMicrophone(_ device: AudioDevice) {
        selectedMicrophone = device
        saveMicrophone(device)
        updateCurrentMicrophone()
        if AppPreferences.shared.debugMode {
            logger.debug("[DEBUG] Microphone selected: name=\(device.name, privacy: .public), id=\(device.id, privacy: .public), isBuiltIn=\(device.isBuiltIn, privacy: .public), manufacturer=\(device.manufacturer ?? "unknown", privacy: .public)")
        }
        
        NotificationCenter.default.post(
            name: .microphoneDidChange,
            object: nil,
            userInfo: ["device": device]
        )
    }
    
    func getActiveMicrophone() -> AudioDevice? {
        return currentMicrophone
    }
    
    func activateForRecording() -> AudioDevice? {
        guard let device = getActiveMicrophone() else { return nil }
        if AppPreferences.shared.debugMode {
            logger.debug("[DEBUG] Activating microphone for recording: name=\(device.name, privacy: .public)")
        }
        return device
    }
    
    func isVirtualDevice(_ device: AudioDevice) -> Bool {
        guard getCoreAudioDeviceID(for: device) != nil else {
            logger.warning("Cannot map device to CoreAudio: \(device.name, privacy: .public), treating as physical")
            return false
        }
        let transportType = UInt32(bitPattern: getTransportType(for: device))
        return transportType == kAudioDeviceTransportTypeVirtual
            || transportType == kAudioDeviceTransportTypeAggregate
            || transportType == kAudioDeviceTransportTypeAutoAggregate
    }

    func isActiveMicrophoneBluetooth() -> Bool {
        guard let device = getActiveMicrophone() else { return false }
        return isBluetoothMicrophone(device)
    }
    
    func isActiveMicrophoneRequiresConnection() -> Bool {
        guard let device = getActiveMicrophone() else { return false }
        return isBluetoothMicrophone(device) || isContinuityMicrophone(device)
    }
    
    func isBluetoothMicrophone(_ device: AudioDevice) -> Bool {
        if let avDevice = AVCaptureDevice(uniqueID: device.id) {
            let transportType = avDevice.transportType
            if transportType == 1651275109 {
                return true
            }
        }
        
        let name = device.name.lowercased()
        let id = device.id.lowercased()
        let hasBluetoothInName = name.contains("bluetooth")
        let hasBluetoothInID = id.contains("bluetooth")
        let macAddressPattern = "^[0-9A-Fa-f]{2}-[0-9A-Fa-f]{2}-[0-9A-Fa-f]{2}-[0-9A-Fa-f]{2}-[0-9A-Fa-f]{2}-[0-9A-Fa-f]{2}"
        let hasMACAddress = id.range(of: macAddressPattern, options: .regularExpression) != nil
        
        if hasBluetoothInName || hasBluetoothInID {
            return true
        }
        
        if hasMACAddress {
            let transportType = getTransportType(for: device)
            return transportType == 1651275109
        }
        
        return false
    }
    
    private func getTransportType(for device: AudioDevice) -> Int32 {
        guard let deviceID = getCoreAudioDeviceID(for: device) else { return 0 }
        
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var transportType: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)
        
        let status = AudioObjectGetPropertyData(
            AudioObjectID(deviceID),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &transportType
        )
        
        return status == noErr ? Int32(transportType) : 0
    }

    private func canBeDefaultInputDevice(_ device: AudioDevice) -> Bool {
        guard let deviceID = getCoreAudioDeviceID(for: device) else { return false }

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceCanBeDefaultDevice,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var canBeDefault: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(deviceID),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &canBeDefault
        )

        return status == noErr && canBeDefault == 1
    }

    private func isAggregateDevice(_ device: AudioDevice) -> Bool {
        let transportType = UInt32(bitPattern: getTransportType(for: device))
        return transportType == kAudioDeviceTransportTypeAggregate
            || transportType == kAudioDeviceTransportTypeAutoAggregate
    }

    private func isConferencingVirtualDevice(_ device: AudioDevice) -> Bool {
        let transportType = UInt32(bitPattern: getTransportType(for: device))
        guard transportType == kAudioDeviceTransportTypeVirtual else { return false }
        let nameLower = device.name.lowercased()
        let conferencingKeywords = ["zoom", "teams", "webex", "meet", "skype", "slack", "discord"]
        return conferencingKeywords.contains { nameLower.contains($0) }
    }

    // MARK: - Stream Inspection

    private func hasRealInputStream(_ device: AudioDevice) -> Bool {
        guard let deviceID = getCoreAudioDeviceID(for: device) else { return false }

        var streamsAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var streamsSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &streamsAddress, 0, nil, &streamsSize) == noErr,
              streamsSize > 0 else { return false }

        let streamCount = Int(streamsSize) / MemoryLayout<AudioStreamID>.size
        var streamIDs = [AudioStreamID](repeating: 0, count: streamCount)
        guard AudioObjectGetPropertyData(deviceID, &streamsAddress, 0, nil, &streamsSize, &streamIDs) == noErr else {
            return false
        }

        for streamID in streamIDs {
            var dirAddress = AudioObjectPropertyAddress(
                mSelector: kAudioStreamPropertyDirection,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var direction: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(streamID, &dirAddress, 0, nil, &size, &direction) == noErr else {
                continue
            }
            guard direction == 1 else { continue }

            var termAddress = AudioObjectPropertyAddress(
                mSelector: kAudioStreamPropertyTerminalType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var terminal: UInt32 = 0
            size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(streamID, &termAddress, 0, nil, &size, &terminal) == noErr else {
                continue
            }

            if terminal != 0 {
                return true
            }
        }

        return false
    }

    func isActiveMicrophoneContinuity() -> Bool {
        guard let device = getActiveMicrophone() else { return false }
        return isContinuityMicrophone(device)
    }
    
    func isContinuityMicrophone(_ device: AudioDevice) -> Bool {
        let name = device.name.lowercased()
        let id = device.id.lowercased()
        let manufacturer = (device.manufacturer ?? "").lowercased()
        let isApple = manufacturer.contains("apple")
        let hasContinuityName = name.contains("continuity") || id.contains("continuity")
        let hasIPhoneName = name.contains("iphone") || id.contains("iphone")
        let hasHandoffName = name.contains("handoff") || id.contains("handoff")
        return isApple && (hasContinuityName || hasIPhoneName || hasHandoffName)
    }
    
    func getAVCaptureDevice() -> AVCaptureDevice? {
        guard let active = getActiveMicrophone() else { return nil }
        return AVCaptureDevice(uniqueID: active.id)
    }
    
    private func saveMicrophone(_ device: AudioDevice) {
        if let encoded = try? JSONEncoder().encode(device) {
            AppPreferences.shared.selectedMicrophoneData = encoded
        }
    }
    
    private func loadSavedMicrophone() {
        guard let data = AppPreferences.shared.selectedMicrophoneData,
              let device = try? JSONDecoder().decode(AudioDevice.self, from: data) else {
            return
        }
        selectedMicrophone = device
    }
    
    func resetToDefault() {
        selectedMicrophone = nil
        AppPreferences.shared.selectedMicrophoneData = nil
        updateCurrentMicrophone()
    }
    
    #if os(macOS)
    func getCoreAudioDeviceID(for device: AudioDevice) -> AudioDeviceID? {
        var deviceID = device.id as CFString
        var audioDeviceID = AudioDeviceID()
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        
        var translationAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDeviceForUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var translation = AudioValueTranslation(
            mInputData: &deviceID,
            mInputDataSize: UInt32(MemoryLayout<CFString>.size),
            mOutputData: &audioDeviceID,
            mOutputDataSize: UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        
        propertySize = UInt32(MemoryLayout<AudioValueTranslation>.size)
        
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &translationAddress,
            0,
            nil,
            &propertySize,
            &translation
        )
        
        return status == noErr ? audioDeviceID : nil
    }
    
    func getCurrentSystemDefaultInputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID()
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &deviceID
        )
        
        return status == noErr ? deviceID : nil
    }
    
    func getInputVolume(for deviceID: AudioDeviceID) -> Float? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: 1
        )
        
        var hasProperty = AudioObjectHasProperty(deviceID, &propertyAddress)
        
        if !hasProperty {
            propertyAddress.mElement = kAudioObjectPropertyElementMain
            hasProperty = AudioObjectHasProperty(deviceID, &propertyAddress)
        }
        
        guard hasProperty else {
            return nil
        }
        
        var volume: Float32 = 0.0
        var propertySize = UInt32(MemoryLayout<Float32>.size)
        
        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &volume
        )
        
        return status == noErr ? volume : nil
    }
    
    func setInputVolume(_ volume: Float, for deviceID: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: 1
        )
        
        var hasProperty = AudioObjectHasProperty(deviceID, &propertyAddress)
        
        if !hasProperty {
            propertyAddress.mElement = kAudioObjectPropertyElementMain
            hasProperty = AudioObjectHasProperty(deviceID, &propertyAddress)
        }
        
        guard hasProperty else {
            return false
        }
        
        var isSettable: DarwinBoolean = false
        var status = AudioObjectIsPropertySettable(deviceID, &propertyAddress, &isSettable)
        
        guard status == noErr, isSettable.boolValue else {
            return false
        }
        
        var mutableVolume = max(0.0, min(1.0, volume))
        status = AudioObjectSetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            UInt32(MemoryLayout<Float32>.size),
            &mutableVolume
        )
        
        return status == noErr
    }
    
    func getInputVolume(for device: AudioDevice) -> Float? {
        guard let deviceID = getCoreAudioDeviceID(for: device) else {
            return nil
        }
        return getInputVolume(for: deviceID)
    }
    
    func setInputVolume(_ volume: Float, for device: AudioDevice) -> Bool {
        guard let deviceID = getCoreAudioDeviceID(for: device) else {
            return false
        }
        return setInputVolume(volume, for: deviceID)
    }
    
    func getInputChannelCount(for device: AudioDevice) -> Int {
        guard let deviceID = getCoreAudioDeviceID(for: device) else { return 0 }
        return getInputChannelCount(for: deviceID)
    }

    private func getInputChannelCount(for deviceID: AudioDeviceID) -> Int {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var propertySize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &propertySize)
        guard sizeStatus == noErr, propertySize > 0 else { return 0 }
        
        let bufferListRawPointer = UnsafeMutableRawPointer.allocate(byteCount: Int(propertySize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufferListRawPointer.deallocate() }
        
        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &propertySize, bufferListRawPointer)
        guard status == noErr else { return 0 }
        
        let bufferList = bufferListRawPointer.assumingMemoryBound(to: AudioBufferList.self)
        let bufferCount = Int(bufferList.pointee.mNumberBuffers)
        
        var totalChannels = 0
        withUnsafeMutablePointer(to: &bufferList.pointee.mBuffers) { firstBufferPtr in
            let buffers = UnsafeMutableBufferPointer<AudioBuffer>(start: firstBufferPtr, count: bufferCount)
            for buffer in buffers {
                totalChannels += Int(buffer.mNumberChannels)
            }
        }
        
        return totalChannels
    }

    func getSystemDefaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID()
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &propertySize,
            &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    func getDeviceUID(_ deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var propertySize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(
            deviceID, &propertyAddress, 0, nil, &propertySize, &uid
        )
        guard status == noErr, let cf = uid?.takeRetainedValue() else { return nil }
        return cf as String
    }
    #endif
}

extension Notification.Name {
    static let microphoneDidChange = Notification.Name("microphoneDidChange")
}

// MARK: - AudioDeviceChangeObserver

extension MicrophoneService: AudioDeviceChangeObserver {
    func onDeviceDisappeared(deviceID: AudioDeviceID) {
        logger.warning("Device disappeared: \(deviceID, privacy: .public)")
        refreshAvailableMicrophones()
        updateCurrentMicrophone()
    }
    
    func onEngineConfigurationChanged() {
        logger.info("Engine configuration changed, refreshing devices")
        refreshAvailableMicrophones()
        updateCurrentMicrophone()
    }
}

