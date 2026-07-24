import Foundation
import CoreAudio
import AVFoundation
import Combine

@MainActor
protocol AudioOutputSettingsStore: AnyObject {
    var selectedAudioOutput: String { get set }
    func mappedOutputs(for deviceUID: String?) -> [MappedAudioOutput]
    func setMappedOutputs(_ outputs: [MappedAudioOutput], for deviceUID: String?)
}

extension AppSettings: AudioOutputSettingsStore {}

// MARK: - AudioDevice

/// Represents an audio output device available on the system.
///
/// This struct encapsulates the CoreAudio device information needed for
/// device selection and display in the UI.
///
/// ## Example
/// ```swift
/// let devices = audioManager.availableDevices
/// for device in devices {
///     print("\(device.name) - \(device.isSystemDefault ? "Default" : "")")
/// }
/// ```
struct AudioDevice: Identifiable, Hashable {
    /// The CoreAudio device ID
    let id: AudioDeviceID

    /// The unique identifier string for this device
    let uid: String

    /// The human-readable device name
    let name: String

    /// Whether this device is the current system default output
    var isSystemDefault: Bool = false

    /// Number of output channels for this device
    var outputChannelCount: Int = 0
}

// MARK: - AudioOutputManager

/// Manages audio output device enumeration and selection for the application.
///
/// This manager provides a SwiftUI-compatible interface for discovering and selecting
/// audio output devices. It monitors the system for device changes and automatically
/// updates the available devices list.
///
/// ## Overview
///
/// Use `AudioOutputManager` to:
/// - Get a list of available audio output devices
/// - Select a specific output device for playback
/// - Respond to device connection/disconnection events
///
/// ## Architecture
///
/// ```
/// ┌─────────────────────────────────────────────────────────────────────────┐
/// │                         SwiftUI Views                                    │
/// │  SettingsView, AudioRoutingView                                         │
/// │  - Use @ObservedObject var audioManager: AudioOutputManager             │
/// └─────────────────────────────────────────────────────────────────────────┘
///                               │
///                               ▼
/// ┌─────────────────────────────────────────────────────────────────────────┐
/// │                    AudioOutputManager (this file)                        │
/// │  - @MainActor for UI thread safety                                       │
/// │  - @Published availableDevices, selectedDeviceUID                        │
/// │  - CoreAudio device enumeration                                          │
/// │  - Device change listener                                                │
/// └─────────────────────────────────────────────────────────────────────────┘
///                               │
///                               ▼
/// ┌─────────────────────────────────────────────────────────────────────────┐
///│                      CoreAudio Framework                                 │
/// │  - AudioObjectGetPropertyData                                            │
/// │  - AudioObjectAddPropertyListenerBlock                                   │
/// └─────────────────────────────────────────────────────────────────────────┘
/// ```
///
/// ## Thread Safety
///
/// This class is confined to the main thread via `@MainActor`. The device change
/// listener runs on a private dispatch queue but dispatches updates back to the
/// main thread.
///
/// ## Example
///
/// ```swift
/// @StateObject private var audioManager = AudioOutputManager()
///
/// var body: some View {
///     Picker("Output Device", selection: $audioManager.selectedDeviceUID) {
///         Text("System Default").tag(nil as String?)
///         ForEach(audioManager.availableDevices) { device in
///             Text(device.name).tag(device.uid as String?)
///         }
///     }
/// }
/// ```
@MainActor
final class AudioOutputManager: ObservableObject {
    // MARK: - Published Properties

    /// Available audio output devices
    @Published private(set) var availableDevices: [AudioDevice] = []

    /// Currently selected device UID (nil = system default)
    @Published var selectedDeviceUID: String? {
        didSet {
            onDeviceChanged?(selectedDeviceUID)
            settings.selectedAudioOutput = selectedDeviceUID ?? ""
            loadMappedOutputs()
            updateSelectedDeviceChannelCount()
        }
    }

    /// Mapped outputs for the selected device
    @Published private(set) var mappedOutputs: [MappedAudioOutput] = []

    /// Output channel count for the selected device
    @Published private(set) var selectedDeviceChannelCount: Int = 0

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
    private let settings: any AudioOutputSettingsStore

    // MARK: - Initialization

    init(settings: any AudioOutputSettingsStore = AppSettings.shared) {
        self.settings = settings
        refreshDevices()
        setupDeviceChangeListener()
        loadMappedOutputs()
        updateSelectedDeviceChannelCount()
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

    /// Refreshes the list of available audio output devices.
    ///
    /// This method queries CoreAudio for all audio devices with output channels
    /// and updates the `availableDevices` array. The devices are sorted with
    /// the system default device first, followed by alphabetical order.
    ///
    /// This method is called automatically:
    /// - On initialization
    /// - When the system notifies of device changes (connection/disconnection)
    ///
    /// You may also call this manually if needed, though it's rarely necessary.
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
            device.outputChannelCount = outputChannelCount(deviceID: deviceID)
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
        updateSelectedDeviceChannelCount()
    }

    private func hasOutputChannels(deviceID: AudioDeviceID) -> Bool {
        outputChannelCount(deviceID: deviceID) > 0
    }

    private func outputChannelCount(deviceID: AudioDeviceID) -> Int {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var propertySize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &propertySize)

        guard status == noErr, propertySize > 0 else { return 0 }

        let bufferListPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(propertySize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferListPointer.deallocate() }

        let result = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &propertySize, bufferListPointer)
        guard result == noErr else { return 0 }

        let audioBufferList = bufferListPointer.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private func loadMappedOutputs() {
        let saved = settings.mappedOutputs(for: selectedDeviceUID)
        if !saved.isEmpty {
            mappedOutputs = saved
            return
        }

        // Auto-generate default stereo outputs based on device channel count
        let channelCount = selectedDevice?.outputChannelCount ?? 2
        var defaults: [MappedAudioOutput] = []

        // Create stereo pairs (or mono if odd number at end)
        var channel = 0
        var outputIndex = 1
        while channel < channelCount {
            let remaining = channelCount - channel
            let count = min(2, remaining)  // Stereo pair or remaining mono
            let name = count == 2 ? "Output \(outputIndex)-\(outputIndex + 1)" : "Output \(outputIndex)"
            defaults.append(MappedAudioOutput(
                id: UUID(),
                name: name,
                channelStart: channel,
                channelCount: count
            ))
            channel += count
            outputIndex += count
        }

        mappedOutputs = defaults
    }

    private func updateSelectedDeviceChannelCount() {
        selectedDeviceChannelCount = selectedDevice?.outputChannelCount ?? 0
    }

    var selectedDevice: AudioDevice? {
        if let uid = selectedDeviceUID,
           let device = availableDevices.first(where: { $0.uid == uid }) {
            return device
        }
        return availableDevices.first(where: { $0.isSystemDefault })
    }

    func saveMappedOutputs(_ outputs: [MappedAudioOutput], for deviceUID: String?) {
        settings.setMappedOutputs(outputs, for: deviceUID)
        if deviceUID == selectedDeviceUID || (deviceUID == nil && selectedDeviceUID == nil) {
            mappedOutputs = outputs
        }
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
