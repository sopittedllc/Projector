//
//  AggregateDeviceManager.swift
//  Projector
//
//  Builds the CoreAudio aggregate device that carries Projector's stems to a DAW.
//

import CoreAudio
import Foundation

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
    /// - Parameter interfaceName: Name of the user's own interface.
    /// - Returns: A name that says what the device is and what it is built from.
    static func aggregateName(interfaceName: String) -> String {
        "Projector + \(interfaceName)"
    }

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
        // Order matters: this array is the channel map.
        let subDevices: [[String: Any]] = [
            [
                kAudioSubDeviceUIDKey: interfaceUID,
                kAudioSubDeviceDriftCompensationKey: 0
            ],
            [
                kAudioSubDeviceUIDKey: virtualUID,
                // The virtual device follows the interface's clock. Quality is set
                // high because a sync application cannot trade accuracy for CPU here.
                kAudioSubDeviceDriftCompensationKey: 1,
                kAudioSubDeviceDriftCompensationQualityKey: driftCompensationHighQuality
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
    ///   - interfaceName: Its name, used to build the aggregate's own name.
    ///   - virtualUID: UID of the loopback device.
    /// - Returns: The UID of the created device.
    /// - Throws: ``AggregateError/creationFailed(_:)`` if CoreAudio refuses.
    func createAggregate(
        interfaceUID: String,
        interfaceName: String,
        virtualUID: String
    ) throws -> String {
        // Rebuild rather than duplicate. A stale aggregate built against a different
        // interface would otherwise sit alongside the new one wearing the same name.
        _ = try? removeAggregate()

        let description = Self.description(
            name: Self.aggregateName(interfaceName: interfaceName),
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
