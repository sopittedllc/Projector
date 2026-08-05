//
//  VirtualAudioPorts.swift
//  Projector
//
//  Finds the loopback device that carries Projector's stems to a DAW.
//

import Foundation

/// The loopback device Projector routes stems through, and whether it is usable.
///
/// ## Why a loopback device is needed
///
/// Getting a stem into a DAW means it has to arrive as an *input*. macOS has no way
/// to loop an output back to an input on its own, and Apple does not grant the
/// DriverKit audio entitlement for virtual devices, so Projector cannot ship one.
/// It relies on BlackHole - free, open source, notarized - and installs it when it is
/// missing.
///
/// The device is only half the answer: it becomes reachable alongside the user's own
/// interface once ``AggregateDeviceManager`` combines the two.
enum VirtualAudioPorts {

    // MARK: - Requirements

    /// Channels needed to carry the stems Projector routes by default.
    ///
    /// Two stereo outputs - DX/SFX and MX - so four channels. This is a floor, not a
    /// target: the 2-channel build of BlackHole is common and carries only one stereo
    /// stem, which is precisely the case worth telling the user about rather than
    /// silently routing half their audio.
    static let minimumChannels = 4

    /// The build Projector installs when none is present.
    ///
    /// Sixteen channels rather than the minimum four, so that adding further outputs
    /// later needs no second install and no change to the channel map the user has
    /// already set up in their DAW.
    static let preferredChannelCount = 16

    // MARK: - Identification

    /// Marks a device as some build of BlackHole.
    ///
    /// Matched on the UID rather than the display name: UIDs are stable identifiers
    /// (`BlackHole16ch_UID`), whereas names are user-visible and can be renamed in
    /// Audio MIDI Setup.
    private static let deviceUIDPrefix = "BlackHole"

    /// Whether a device is a BlackHole build.
    ///
    /// - Parameter device: The device to test.
    /// - Returns: `true` when its UID identifies it as BlackHole.
    static func isVirtualPortDevice(_ device: AudioDevice) -> Bool {
        device.uid.hasPrefix(deviceUIDPrefix)
    }

    // MARK: - Readiness

    /// Whether a usable loopback device is present.
    enum Readiness: Equatable {
        /// A BlackHole build with enough channels is installed.
        case ready(AudioDevice)

        /// BlackHole is installed but too narrow to carry the default stems.
        ///
        /// Distinguished from ``missing`` because the remedy differs: the user is not
        /// short of software, they have the wrong build, and installing the wider one
        /// leaves both in the device list.
        case insufficientChannels(device: AudioDevice, found: Int, required: Int)

        /// No BlackHole build is installed.
        case missing
    }

    /// Assesses the loopback devices available.
    ///
    /// - Parameter devices: Every output device currently known to the system.
    /// - Returns: What is installed and whether it will do.
    /// - Note: Prefers the widest build when several are installed, since a machine
    ///   carrying both 2ch and 16ch should use the one that fits.
    static func readiness(in devices: [AudioDevice]) -> Readiness {
        let candidates = devices
            .filter(isVirtualPortDevice)
            .sorted { $0.outputChannelCount > $1.outputChannelCount }

        guard let widest = candidates.first else { return .missing }

        guard widest.outputChannelCount >= minimumChannels else {
            return .insufficientChannels(
                device: widest,
                found: widest.outputChannelCount,
                required: minimumChannels
            )
        }
        return .ready(widest)
    }
}
