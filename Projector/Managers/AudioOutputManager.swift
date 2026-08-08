import Foundation
import CoreAudio
import AVFoundation
import Combine

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
    private let settings = AppSettings.shared

    // MARK: - Constants

    /// The output every unconfigured device starts with.
    private enum DefaultOutput {
        /// Fills the built-in stereo role, so Settings shows it in that role's
        /// fixed row rather than listing it as an extra output.
        static let name = "Stereo Out"

        static let roleId = MappedAudioOutput.stereoOutRoleId

        /// One-based, matching how channels are labelled in the UI.
        static let firstChannelNumber = 1

        static let channelCount = 2
    }

    // MARK: - Initialization

    init() {
        refreshDevices()

        // Restored here rather than by the first view that appears. Doing it on
        // appearance meant the manager spent the opening frames reporting the system
        // default, so Settings opened on the wrong device with the wrong mappings
        // beneath it and corrected itself a moment later - the panel briefly asserting
        // something untrue. Assigning through the property runs its `didSet`, which
        // reloads the mappings for the restored device.
        let saved = settings.selectedAudioOutput
        if !saved.isEmpty, availableDevices.contains(where: { $0.uid == saved }) {
            selectedDeviceUID = saved
        }

        setupDeviceChangeListener()
        loadMappedOutputs()
        updateSelectedDeviceChannelCount()
    }

    /// Hand the device-change listener back to CoreAudio.
    ///
    /// `deinit` below does the same thing and remains the backstop, but it is not
    /// a reliable moment: this object is a `@StateObject` owned by the view tree,
    /// and a process exiting does not have to deinitialise anything. So quitting is
    /// an explicit call - see `.projectorWillTerminate`.
    ///
    /// Idempotent. The block is dropped afterwards, so `deinit` finds nothing left
    /// to remove and CoreAudio is never asked twice.
    func cleanup() {
        removeDeviceChangeListener()
    }

    private func removeDeviceChangeListener() {
        guard let listenerBlock = deviceListenerBlock else { return }
        deviceListenerBlock = nil

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            listenerQueue,
            listenerBlock
        )
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

    /// Load the outputs the user has defined for the selected device, seeding a
    /// default `Stereo Out` the first time a device is seen.
    ///
    /// A device the user has never configured gets exactly **one** output: a
    /// stereo pair on the first two channels, so playback makes sound before
    /// anyone opens Settings. Everything beyond that is still a deliberate
    /// decision through the guided DX/SFX, MX and "add additional" flow, because
    /// a routing map is a decision about a session, not a fact about the
    /// hardware.
    ///
    /// Two failures from the earlier auto-creation are deliberately not repeated
    /// here. That version fabricated a pair for *every* channel ("Output 1-2",
    /// "Output 3-4", ...), filling Settings with entries nobody asked for - this
    /// one seeds a single pair. And it minted them in memory with a fresh `UUID`
    /// each launch without ever saving, so a lane assigned to one stored an id
    /// that referred to nothing on the next launch - this one is persisted
    /// through `setMappedOutputs` before being published, so the id is stable.
    ///
    /// Seeding is keyed on `hasConfiguredOutputs(for:)` rather than on the list
    /// being empty, so clearing `Stereo Out` removes it for good instead of
    /// having it reappear on the next device change.
    private func loadMappedOutputs() {
        seedDefaultOutputIfNeverConfigured()
        mappedOutputs = settings.mappedOutputs(for: selectedDeviceUID)

        // Republished on load, not only on change. The names live on the aggregate, so a
        // device rebuilt against a different interface comes back with none - and a
        // launch that changes no output would otherwise leave the DAW showing the
        // generated "Device 1…48" until the user happened to edit something.
        publishVirtualPortLabels(mappedOutputs, for: selectedDeviceUID)
    }

    /// Persist the default stereo output for a device seen for the first time.
    ///
    /// Reads the channel count from `selectedDevice` rather than the published
    /// `selectedDeviceChannelCount`, because `selectedDeviceUID.didSet` loads
    /// mappings *before* it refreshes that property - it would still hold the
    /// previous device's count here.
    ///
    /// A device that cannot carry a stereo pair is left empty rather than seeded
    /// with something narrower; Settings already explains that case.
    private func seedDefaultOutputIfNeverConfigured() {
        guard !settings.hasConfiguredOutputs(for: selectedDeviceUID) else { return }
        guard let device = selectedDevice,
              device.outputChannelCount >= DefaultOutput.channelCount else { return }

        let stereoOut = MappedAudioOutput(
            name: DefaultOutput.name,
            channelStart: DefaultOutput.firstChannelNumber - 1,
            channelCount: DefaultOutput.channelCount,
            roleId: DefaultOutput.roleId
        )
        settings.setMappedOutputs([stereoOut], for: selectedDeviceUID)
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
        publishVirtualPortLabels(outputs, for: deviceUID)
    }

    /// Republishes the channel names a DAW sees, whenever the outputs behind them change.
    ///
    /// Hooked to `saveMappedOutputs` rather than to each caller because that is the one
    /// funnel every add, replace, remove and reseed already passes through - the names
    /// cannot drift from the mapping they describe if there is nowhere else to change it.
    ///
    /// Does nothing unless the outputs being saved belong to Projector's aggregate. On an
    /// ordinary interface the channels are the user's own hardware, and renaming them
    /// would be Projector writing on equipment it does not own.
    private func publishVirtualPortLabels(
        _ outputs: [MappedAudioOutput],
        for deviceUID: String?
    ) {
        guard deviceUID == AggregateDeviceManager.aggregateUID,
              let origin = AggregateChannelOrigin.current(in: availableDevices)
        else { return }

        VirtualPortLabels.apply(outputs: outputs, origin: origin)
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

// MARK: - Output Editing

extension AudioOutputManager {
    /// Channels the selected device offers, 1-based for display.
    var availableChannelNumbers: [Int] {
        guard selectedDeviceChannelCount > 0 else { return [] }
        return Array(1...selectedDeviceChannelCount)
    }

    /// Whether a channel is already claimed by an existing output.
    ///
    /// - Parameter excluding: An output being edited, so it does not collide
    ///   with itself.
    func channelIsAssigned(_ channelNumber: Int, excluding outputId: UUID? = nil) -> Bool {
        let zeroBased = channelNumber - 1
        return mappedOutputs.contains { output in
            guard output.id != outputId else { return false }
            return zeroBased >= output.channelStart
                && zeroBased < output.channelStart + output.channelCount
        }
    }

    /// Add an output, or replace one of the same name.
    ///
    /// Replacing by name is what makes the DX/SFX and MX buttons idempotent -
    /// choosing DX/SFX twice re-points it rather than leaving two.
    func addOrReplaceOutput(
        name: String,
        firstChannelNumber: Int,
        isStereo: Bool,
        roleId: String? = nil
    ) {
        var outputs = mappedOutputs
        // Replace on role where there is one, otherwise on name. A role can be
        // re-pointed even if its previous mapping was named differently.
        let existingIndex = outputs.firstIndex {
            if let roleId { return $0.roleId == roleId || $0.name == name }
            return $0.name == name
        }
        let replacement = MappedAudioOutput(
            id: existingIndex.map { outputs[$0].id } ?? UUID(),
            name: name,
            channelStart: max(0, firstChannelNumber - 1),
            channelCount: isStereo ? 2 : 1,
            roleId: roleId
        )
        if let index = existingIndex {
            outputs[index] = replacement
        } else {
            outputs.append(replacement)
        }
        outputs.sort { $0.channelStart < $1.channelStart }
        saveMappedOutputs(outputs, for: selectedDeviceUID)
    }

    func removeOutput(id: UUID) {
        saveMappedOutputs(mappedOutputs.filter { $0.id != id }, for: selectedDeviceUID)
    }

    /// Lays out monitoring and stems across an aggregate device.
    ///
    /// Mappings are stored per device UID, so selecting a freshly built aggregate
    /// otherwise arrives with an empty bucket and picks up the lone "Stereo Out" that
    /// ``seedDefaultOutputIfNeverConfigured()`` seeds for any new device. That would
    /// leave the whole point of the aggregate - the stems - unrouted, and read to the
    /// user as though their routing had been lost.
    ///
    /// Monitoring stays on the interface's own channels so the speakers keep working;
    /// the stems go to the loopback channels above them, where a DAW can see them and
    /// the room cannot hear them.
    ///
    /// - Parameter map: Where each output belongs on the aggregate.
    /// - Important: Applies to the **currently selected** device, so select the
    ///   aggregate before calling this.
    func seedOutputsForAggregate(_ map: AggregateChannelMap) {
        addOrReplaceOutput(
            name: "Stereo Out",
            firstChannelNumber: map.stereoOutFirstChannel,
            isStereo: true,
            roleId: MappedAudioOutput.stereoOutRoleId
        )
        addOrReplaceOutput(
            name: "DX/SFX",
            firstChannelNumber: map.dialogueEffectsFirstChannel,
            isStereo: true,
            roleId: MappedAudioOutput.dialogueEffectsRoleId
        )
        addOrReplaceOutput(
            name: "MX",
            firstChannelNumber: map.musicFirstChannel,
            isStereo: true,
            roleId: MappedAudioOutput.musicRoleId
        )
    }

    /// Replace the current outputs with a profile's.
    ///
    /// New identities are minted so the routing authority re-binds lanes by
    /// channel range rather than matching stale ids - see
    /// `TimelineManager.reconcileOutputMappings(with:)`.
    func applyProfile(_ profile: AudioOutputProfile) {
        let outputs = profile.outputs.map {
            MappedAudioOutput(
                name: $0.name,
                channelStart: $0.channelStart,
                channelCount: $0.channelCount,
                roleId: $0.roleId
            )
        }
        saveMappedOutputs(outputs, for: selectedDeviceUID)
    }

    /// Whether a profile was built for a different device than the one selected.
    func profileWasBuiltElsewhere(_ profile: AudioOutputProfile) -> Bool {
        guard let origin = profile.createdForDeviceUID, !origin.isEmpty else { return false }
        return origin != (selectedDeviceUID ?? "")
    }

    /// Whether the selected device has enough channels for a profile.
    func deviceSatisfies(_ profile: AudioOutputProfile) -> Bool {
        profile.highestChannel <= selectedDeviceChannelCount
    }

    /// Capture the current outputs as a profile.
    func makeProfile(named name: String, id: UUID = UUID()) -> AudioOutputProfile {
        AudioOutputProfile(
            id: id,
            name: name,
            outputs: mappedOutputs,
            createdForDeviceUID: selectedDeviceUID,
            createdForDeviceName: selectedDevice?.name
        )
    }
}
