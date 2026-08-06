//
//  AggregateDeviceManager.swift
//  Projector
//
//  Builds the CoreAudio aggregate device that carries Projector's stems to a DAW.
//

import CoreAudio
import Foundation

/// Where each of Projector's outputs sits on an aggregate device.
///
/// CoreAudio concatenates an aggregate's channels in sub-device order, and that order is
/// the only thing deciding which half starts at channel 1.
///
/// ## The loopback half comes first
///
/// The stems are what a DAW has to find, so they occupy channels 1-4 and the user's
/// interface follows above them. The alternative was tried and failed in practice: with a
/// 32-channel interface first, the stems landed on inputs 33-36, and a DAW listing
/// forty-eight ports gave no clue which four mattered. Cubase compounded it by ignoring
/// channel names entirely and generating "Projector Aggregate Device 1…48", so the only
/// reliable way to say *which* ports carry the stems is for them to be the first ones.
///
/// Sub-device order is independent of the clock: the interface stays the clock master
/// through `kAudioAggregateDeviceMainSubDeviceKey`, whatever position it holds in the
/// list. Conflating the two is what previously made this look unchangeable.
///
/// ## Monitoring stays on the interface
///
/// Stereo Out sits on the interface's first pair, where a monitor path is normally wired,
/// so the room still hears the reel - now at aggregate channel 17 rather than 1, because
/// the loopback half precedes it.
///
/// Every channel here is **1-based**, matching what the user is shown and what
/// `AudioOutputManager.addOrReplaceOutput(name:firstChannelNumber:isStereo:roleId:)`
/// expects. The 0-based conversion happens there, once, as it always has.
struct AggregateChannelMap: Equatable {

    /// Output channels on the loopback device.
    let virtualChannelCount: Int

    /// Output channels on the user's own interface.
    let interfaceChannelCount: Int

    /// Whether the loopback half holds the low channels.
    ///
    /// True for every device Projector builds now. False describes one built before the
    /// stems were moved down, which still exists on machines that set up earlier - the
    /// order is read back from the device rather than assumed, so those keep working and
    /// keep being described correctly until they are rebuilt.
    let virtualComesFirst: Bool

    /// Channels used by each seeded stereo output.
    private static let channelsPerOutput = 2

    /// How many seeded outputs live on the loopback half.
    private static let loopbackOutputCount = 2

    init(virtualChannelCount: Int, interfaceChannelCount: Int, virtualComesFirst: Bool = true) {
        self.virtualChannelCount = virtualChannelCount
        self.interfaceChannelCount = interfaceChannelCount
        self.virtualComesFirst = virtualComesFirst
    }

    /// First aggregate channel belonging to the loopback half.
    var virtualFirstChannel: Int { virtualComesFirst ? 1 : interfaceChannelCount + 1 }

    /// First aggregate channel belonging to the user's interface.
    ///
    /// The number to quote when telling someone where their own inputs and outputs start.
    var interfaceFirstChannel: Int { virtualComesFirst ? virtualChannelCount + 1 : 1 }

    /// Monitoring, on the interface's first pair - where the speakers already are.
    var stereoOutFirstChannel: Int { interfaceFirstChannel }

    /// Dialogue and effects, on the first pair of loopback channels.
    var dialogueEffectsFirstChannel: Int { virtualFirstChannel }

    /// Music, on the second pair.
    var musicFirstChannel: Int { dialogueEffectsFirstChannel + Self.channelsPerOutput }

    /// Where a user-added output would land next, leaving the seeded outputs alone.
    var firstAdditionalChannel: Int { musicFirstChannel + Self.channelsPerOutput }

    /// The loopback channel an output occupies, counted from the loopback device's
    /// own channel 1.
    ///
    /// Identical to the aggregate channel while the loopback half comes first, which is
    /// the point of putting it there: the number Projector quotes is the number the DAW
    /// lists.
    ///
    /// - Parameter aggregateChannel: A 1-based channel on the aggregate.
    /// - Returns: The corresponding 1-based channel on the loopback device.
    func loopbackChannel(forAggregateChannel aggregateChannel: Int) -> Int {
        aggregateChannel - virtualFirstChannel + 1
    }

    /// The channel an output occupies, counted from the interface's own channel 1.
    ///
    /// - Parameter aggregateChannel: A 1-based channel on the aggregate.
    /// - Returns: The corresponding 1-based channel on the interface.
    func interfaceChannel(forAggregateChannel aggregateChannel: Int) -> Int {
        aggregateChannel - interfaceFirstChannel + 1
    }

    /// Whether an output sits on the loopback half, and so reaches the DAW.
    ///
    /// - Parameter firstChannel: The output's first 1-based channel on the aggregate.
    /// - Returns: `true` when the channel belongs to the loopback device.
    func reachesDAW(firstChannel: Int) -> Bool {
        firstChannel >= virtualFirstChannel
            && firstChannel < virtualFirstChannel + virtualChannelCount
    }

    /// Loopback channels the seeded outputs consume.
    static var requiredVirtualChannels: Int { channelsPerOutput * loopbackOutputCount }
}

/// Names an aggregate's channels after the device that actually carries them.
///
/// An aggregate presents one flat run of channels, so "33-34" is all the user is
/// offered when picking where an output goes - a number that appears nowhere in their
/// DAW and belongs to no device they own. Naming the half it lands on, and numbering it
/// the way that half counts, turns the choice back into one about equipment: the
/// interface's outputs 1-2 go to the room, and the virtual device's inputs 1-2 arrive in
/// the DAW.
///
/// Only meaningful for Projector's own aggregate. An ordinary interface has a single
/// origin, where repeating its name against every channel would say nothing.
struct AggregateChannelOrigin: Equatable {

    /// Where the two halves meet.
    let map: AggregateChannelMap

    /// The user's own interface, which owns the low channels.
    let interfaceName: String

    /// The loopback half, which owns the high channels and reaches the DAW.
    let virtualName: String

    /// How many channels the aggregate has in total, across both halves.
    let totalChannelCount: Int

    /// Shown in place of the interface's name when its sub-device cannot be resolved.
    ///
    /// Reachable when the aggregate exists but its first sub-device is not in the
    /// current device list - an interface unplugged since the device was built.
    static let unknownInterfaceName = "Your interface"

    /// Reads the current composition of Projector's aggregate, if it has one.
    ///
    /// The single place this is worked out. Both the settings rows and the channel
    /// names published to the DAW have to agree about which device owns which channel,
    /// and they can only disagree if they each derive it.
    ///
    /// - Parameter devices: Every output device currently known to the system.
    /// - Returns: How the aggregate's channels divide, or `nil` when Projector has no
    ///   aggregate or its halves cannot be told apart.
    static func current(in devices: [AudioDevice]) -> AggregateChannelOrigin? {
        guard let aggregate = devices.first(where: {
            $0.uid == AggregateDeviceManager.aggregateUID
        }) else { return nil }

        guard case .ready(let virtual) = VirtualAudioPorts.readiness(in: devices) else {
            return nil
        }

        let interfaceChannels = aggregate.outputChannelCount - virtual.outputChannelCount
        guard interfaceChannels > 0 else { return nil }

        // Read the order back rather than assuming it. A device built before the stems
        // moved to the low channels is still interface-first, and describing it by the
        // current layout would put every label and every route in the wrong half.
        let subDevices = AggregateDeviceManager.subDeviceUIDs()
        let virtualComesFirst = subDevices.first == virtual.uid

        let interfaceUID = virtualComesFirst ? subDevices.dropFirst().first : subDevices.first
        let interfaceName = interfaceUID
            .flatMap { uid in devices.first { $0.uid == uid }?.name }

        return AggregateChannelOrigin(
            map: AggregateChannelMap(
                virtualChannelCount: virtual.outputChannelCount,
                interfaceChannelCount: interfaceChannels,
                virtualComesFirst: virtualComesFirst
            ),
            interfaceName: interfaceName ?? unknownInterfaceName,
            virtualName: AggregateDeviceManager.virtualHalfName,
            totalChannelCount: aggregate.outputChannelCount
        )
    }

    /// Describes a run of channels as the device carrying it would.
    ///
    /// - Parameters:
    ///   - firstChannel: First 1-based channel on the aggregate.
    ///   - channelCount: How many channels the run covers.
    /// - Returns: The owning device's name followed by its own channel numbering.
    func label(firstChannel: Int, channelCount: Int) -> String {
        let reachesDAW = map.reachesDAW(firstChannel: firstChannel)
        let first = reachesDAW
            ? map.loopbackChannel(forAggregateChannel: firstChannel)
            : map.interfaceChannel(forAggregateChannel: firstChannel)
        let name = reachesDAW ? virtualName : interfaceName

        guard channelCount > 1 else { return "\(name) \(first)" }
        return "\(name) \(first)-\(first + channelCount - 1)"
    }
}

/// Creates and removes the aggregate device that lets a DAW receive Projector's stems.
///
/// ## Why an aggregate is needed
///
/// Projector renders every output to channel ranges on a single device. To reach a DAW
/// the stems must arrive as *inputs* somewhere, and macOS has no way to loop an output
/// back to an input on its own. An aggregate device bundles the user's interface with a
/// loopback-capable virtual device, so one device carries both: low channels feed the
/// speakers, high channels feed the virtual device the DAW listens to.
///
/// ## Channel layout is the sub-device order
///
/// CoreAudio concatenates sub-device channels in list order, so the interface must come
/// first and the virtual device second. With a 32-channel interface and a 16-channel
/// virtual device, aggregate outputs 1-32 are the interface and 33-48 are the virtual
/// device. Nothing else in the app needs to know this - ``MappedAudioOutput`` already
/// addresses the device by channel offset.
///
/// ## Clock
///
/// The interface is the clock master and the virtual device gets drift compensation.
/// A virtual device has no hardware clock of its own, so without compensation the two
/// halves slide apart over the length of a reel - which is exactly the failure this
/// application exists to prevent.
actor AggregateDeviceManager {

    // MARK: - Identity

    /// Stable identifier for the device Projector builds.
    ///
    /// Fixed so that a second run finds and rebuilds the existing device rather than
    /// leaving a trail of near-identical aggregates in Audio MIDI Setup.
    static let aggregateUID = "com.keegandewitt.projector.aggregate"

    /// Name shown in Audio MIDI Setup and in every app's device list.
    ///
    /// Fixed rather than built from the interface it wraps. The device is addressed by
    /// ``aggregateUID`` everywhere it matters, so the name's only job is to be
    /// recognisable in another application's device menu - and a name that changes with
    /// the interface makes the user hunt for a different string each time it is rebuilt.
    static let aggregateName = "Projector Aggregate Device"

    /// How the loopback half is named to the user.
    ///
    /// The user chose Projector's routing, not a third-party driver, so the half that
    /// carries stems to the DAW is presented as Projector's own. The underlying device
    /// is still BlackHole and still says so in Audio MIDI Setup; this name appears only
    /// where Projector is explaining its own channel layout.
    static let virtualHalfName = "Projector Virtual"

    // MARK: - Errors

    /// A failure while building or removing the aggregate device.
    enum AggregateError: LocalizedError, Equatable {
        /// CoreAudio refused to create the device.
        case creationFailed(OSStatus)
        /// CoreAudio refused to remove the device.
        case removalFailed(OSStatus)
        /// The sub-devices disagree about sample rate.
        case sampleRateMismatch(interface: Double, virtual: Double)

        var errorDescription: String? {
            switch self {
            case .creationFailed(let status):
                return "Could not create the audio device (CoreAudio error \(status))."
            case .removalFailed(let status):
                return "Could not remove the audio device (CoreAudio error \(status))."
            case .sampleRateMismatch(let interface, let virtual):
                return "Sample rates do not match: the interface runs at "
                    + "\(Int(interface)) Hz and the virtual device at \(Int(virtual)) Hz."
            }
        }
    }

    // MARK: - Drift Compensation

    /// Drift compensation quality for the virtual sub-device.
    ///
    /// CoreAudio documents this as a continuous range from
    /// `kAudioSubDeviceDriftCompensationMinQuality` (0) to `…MaxQuality` (0x7F), with
    /// named waypoints. The named constants are annotated `macos(13.0)` and cannot be
    /// referenced while the app still supports macOS 12, so the documented value for
    /// the high setting is spelled out here instead - the key itself
    /// (`"drift quality"`) is a plain `#define` and carries no availability limit.
    ///
    /// High rather than default: a sync application cannot trade clock accuracy for a
    /// little CPU.
    private static let driftCompensationHighQuality = 0x60

    // MARK: - Description

    /// Builds the description dictionary passed to CoreAudio.
    ///
    /// Separated from the call that consumes it so the layout can be tested without
    /// creating a real device on the machine running the tests.
    ///
    /// - Parameters:
    ///   - name: Display name for the aggregate.
    ///   - interfaceUID: UID of the user's interface. Becomes the clock master and
    ///     occupies the low channels.
    ///   - virtualUID: UID of the loopback device. Occupies the high channels and is
    ///     drift-compensated.
    /// - Returns: A dictionary suitable for `AudioHardwareCreateAggregateDevice`.
    static func description(
        name: String,
        interfaceUID: String,
        virtualUID: String
    ) -> [String: Any] {
        // Order matters: this array is the channel map. The loopback device leads so the
        // stems are the DAW's first inputs rather than its thirty-third - see
        // ``AggregateChannelMap``. This says nothing about the clock; the interface is
        // still the main sub-device below.
        let subDevices: [[String: Any]] = [
            [
                kAudioSubDeviceUIDKey: virtualUID,
                // The virtual device follows the interface's clock. Quality is set
                // high because a sync application cannot trade accuracy for CPU here.
                kAudioSubDeviceDriftCompensationKey: 1,
                kAudioSubDeviceDriftCompensationQualityKey: driftCompensationHighQuality
            ],
            [
                kAudioSubDeviceUIDKey: interfaceUID,
                kAudioSubDeviceDriftCompensationKey: 0
            ]
        ]

        return [
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
            kAudioAggregateDeviceMainSubDeviceKey: interfaceUID,
            // Public, deliberately. A private aggregate is invisible to other
            // processes, which would defeat the entire purpose - the DAW has to see
            // it - and CoreAudio's private flag is documented as unreliable besides.
            kAudioAggregateDeviceIsPrivateKey: 0,
            // Not stacked: sub-devices sit side by side as separate channels rather
            // than being summed on top of each other.
            kAudioAggregateDeviceIsStackedKey: 0
        ]
    }

    // MARK: - Lifecycle

    /// Creates the aggregate device, replacing any previous one Projector built.
    ///
    /// - Parameters:
    ///   - interfaceUID: UID of the user's interface.
    ///   - virtualUID: UID of the loopback device.
    /// - Returns: The UID of the created device.
    /// - Throws: ``AggregateError/creationFailed(_:)`` if CoreAudio refuses.
    func createAggregate(
        interfaceUID: String,
        virtualUID: String
    ) throws -> String {
        // Rebuild rather than duplicate. A stale aggregate built against a different
        // interface would otherwise sit alongside the new one wearing the same name.
        _ = try? removeAggregate()

        let description = Self.description(
            name: Self.aggregateName,
            interfaceUID: interfaceUID,
            virtualUID: virtualUID
        )

        var deviceID = AudioObjectID(0)
        let status = AudioHardwareCreateAggregateDevice(
            description as CFDictionary,
            &deviceID
        )

        guard status == noErr, deviceID != 0 else {
            throw AggregateError.creationFailed(status)
        }

        // Hold on to the identifier CoreAudio just handed back.
        //
        // It cannot be recovered by enumerating devices straight afterwards: the
        // system's device list is published asynchronously, so a lookup by UID
        // milliseconds after a successful create still reports nothing. Measured -
        // creation returned noErr and the device was plainly there in Audio MIDI
        // Setup, while an immediate lookup found it missing, which left an orphaned
        // device behind because removal believed there was nothing to remove.
        createdDeviceID = deviceID
        return Self.aggregateUID
    }

    /// The device this manager created, when it created one in this session.
    ///
    /// Preferred over looking the device up by UID, which is only reliable once the
    /// system's device list has caught up.
    private var createdDeviceID: AudioObjectID?

    /// Removes the aggregate device Projector built.
    ///
    /// - Returns: `true` if a device was found and removed, `false` if there was
    ///   nothing to remove. Reported rather than swallowed so a caller cannot mistake
    ///   "nothing was there" for "it has been cleaned up".
    /// - Throws: ``AggregateError/removalFailed(_:)`` if CoreAudio refuses.
    @discardableResult
    func removeAggregate() throws -> Bool {
        guard let deviceID = createdDeviceID ?? Self.findAggregate() else {
            return false
        }

        let status = AudioHardwareDestroyAggregateDevice(deviceID)
        guard status == noErr else {
            throw AggregateError.removalFailed(status)
        }
        createdDeviceID = nil
        return true
    }

    // MARK: - Lookup

    /// Finds Projector's aggregate device among the system's devices.
    ///
    /// - Returns: Its `AudioObjectID`, or `nil` when it does not exist.
    static func findAggregate() -> AudioObjectID? {
        deviceID(forUID: aggregateUID)
    }

    /// Reads the UIDs of the devices an aggregate is built from, in channel order.
    ///
    /// The order is the channel map: CoreAudio documents this array's order as
    /// significant and uses it to lay out the aggregate's streams, so the first entry
    /// owns the low channels and the second follows on from it.
    ///
    /// Read from the device rather than remembered, because the aggregate outlives the
    /// session that built it - after a relaunch this is the only account of which
    /// interface its low channels belong to.
    ///
    /// - Parameter uid: UID of the aggregate to inspect. Defaults to Projector's own.
    /// - Returns: Sub-device UIDs in channel order, or an empty array if the device does
    ///   not exist or carries no sub-device list.
    static func subDeviceUIDs(forAggregate uid: String = aggregateUID) -> [String] {
        guard let deviceID = deviceID(forUID: uid) else { return [] }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyFullSubDeviceList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        // Received unmanaged and retained explicitly: CoreAudio documents the caller as
        // responsible for releasing this CFArray. Same reasoning as `uidString(for:)`.
        var size = UInt32(MemoryLayout<Unmanaged<CFArray>>.size)
        let listPtr = UnsafeMutablePointer<Unmanaged<CFArray>?>.allocate(capacity: 1)
        listPtr.initialize(to: nil)
        defer {
            listPtr.deinitialize(count: 1)
            listPtr.deallocate()
        }

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, listPtr)
        guard status == noErr, let list = listPtr.pointee?.takeRetainedValue() else {
            return []
        }
        return (list as? [String]) ?? []
    }

    /// Resolves a device UID to its CoreAudio object ID.
    ///
    /// - Parameter uid: The device's unique identifier.
    /// - Returns: The matching object ID, or `nil` if no device carries that UID.
    static func deviceID(forUID uid: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr else { return nil }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return nil }

        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs
        ) == noErr else { return nil }

        return deviceIDs.first { uidString(for: $0) == uid }
    }

    /// Reads a device's unique identifier.
    ///
    /// - Parameter deviceID: The device to inspect.
    /// - Returns: Its UID, or `nil` if it cannot be read.
    /// - Note: Reads into an `Unmanaged<CFString>` box rather than a `CFString` variable.
    ///   Taking a raw pointer to a Swift `CFString` hands CoreAudio the address of an
    ///   object reference; the value has to be received unmanaged and retained
    ///   explicitly. Mirrors `AudioOutputManager.getDeviceUID(deviceID:)`.
    private static func uidString(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
        let uidPtr = UnsafeMutablePointer<Unmanaged<CFString>?>.allocate(capacity: 1)
        uidPtr.initialize(to: nil)
        defer {
            uidPtr.deinitialize(count: 1)
            uidPtr.deallocate()
        }

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, uidPtr)
        guard status == noErr, let uid = uidPtr.pointee?.takeRetainedValue() else {
            return nil
        }
        return uid as String
    }
}
