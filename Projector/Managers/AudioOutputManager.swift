import Foundation
import CoreAudio
import AVFoundation
import Combine

/// Represents an audio output device
struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String

    var isSystemDefault: Bool = false
}

/// Manages audio output device enumeration and selection
@MainActor
final class AudioOutputManager: ObservableObject {
    // MARK: - Published Properties

    /// Available audio output devices
    @Published private(set) var availableDevices: [AudioDevice] = []

    /// Currently selected device UID (nil = system default)
    @Published var selectedDeviceUID: String? {
        didSet {
            onDeviceChanged?(selectedDeviceUID)
        }
    }

    /// Currently selected device name for display
    var selectedDeviceName: String {
        if let uid = selectedDeviceUID,
           let device = availableDevices.first(where: { $0.uid == uid }) {
            return device.name
        }
        return "System Default"
    }

    // MARK: - Callbacks

    /// Called when the selected device changes
    var onDeviceChanged: ((String?) -> Void)?

    // MARK: - Private Properties

    private nonisolated(unsafe) var deviceListenerBlock: AudioObjectPropertyListenerBlock?
    private nonisolated(unsafe) var listenerQueue = DispatchQueue(label: "com.projector.audiodevicelistener")

    // MARK: - Initialization

    init() {
        refreshDevices()
        setupDeviceChangeListener()
    }

    deinit {
        // Capture values directly to avoid actor isolation issues
        let listener = deviceListenerBlock
        let queue = listenerQueue

        guard let listenerBlock = listener else { return }

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            queue,
            listenerBlock
        )
    }

    // MARK: - Device Enumeration

    func refreshDevices() {
        var devices: [AudioDevice] = []

        // Get default output device
        var defaultDeviceID = AudioDeviceID()
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &defaultDeviceID
        )

        // Get all output devices
        propertyAddress.mSelector = kAudioHardwarePropertyDevices
        propertySize = 0

        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize
        )

        guard status == noErr else { return }

        let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &deviceIDs
        )

        guard status == noErr else { return }

        for deviceID in deviceIDs {
            // Check if device has output channels
            guard hasOutputChannels(deviceID: deviceID) else { continue }

            // Get device name
            guard let name = getDeviceName(deviceID: deviceID) else { continue }

            // Get device UID
            guard let uid = getDeviceUID(deviceID: deviceID) else { continue }

            var device = AudioDevice(id: deviceID, uid: uid, name: name)
            device.isSystemDefault = (deviceID == defaultDeviceID)
            devices.append(device)
        }

        // Sort: system default first, then alphabetically
        devices.sort { lhs, rhs in
            if lhs.isSystemDefault != rhs.isSystemDefault {
                return lhs.isSystemDefault
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        self.availableDevices = devices
    }

    private func hasOutputChannels(deviceID: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var propertySize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &propertySize)

        guard status == noErr, propertySize > 0 else { return false }

        let bufferListPointer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(propertySize))
        defer { bufferListPointer.deallocate() }

        let result = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &propertySize, bufferListPointer)
        guard result == noErr else { return false }

        let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPointer)
        var channelCount: UInt32 = 0
        for buffer in bufferList {
            channelCount += buffer.mNumberChannels
        }

        return channelCount > 0
    }

    private func getDeviceName(deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var propertySize = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
        let namePtr = UnsafeMutablePointer<Unmanaged<CFString>?>.allocate(capacity: 1)
        namePtr.initialize(to: nil)
        defer {
            namePtr.deinitialize(count: 1)
            namePtr.deallocate()
        }

        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &propertySize,
            namePtr
        )
        guard status == noErr, let name = namePtr.pointee?.takeRetainedValue() else { return nil }

        return name as String
    }

    private func getDeviceUID(deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var propertySize = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
        let uidPtr = UnsafeMutablePointer<Unmanaged<CFString>?>.allocate(capacity: 1)
        uidPtr.initialize(to: nil)
        defer {
            uidPtr.deinitialize(count: 1)
            uidPtr.deallocate()
        }

        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &propertySize,
            uidPtr
        )
        guard status == noErr, let uid = uidPtr.pointee?.takeRetainedValue() else { return nil }

        return uid as String
    }

    // MARK: - Device Change Listener

    private func setupDeviceChangeListener() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        deviceListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                self?.refreshDevices()
            }
        }

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            listenerQueue,
            deviceListenerBlock!
        )
    }
}
