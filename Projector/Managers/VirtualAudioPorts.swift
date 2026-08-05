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

    /// Channels needed to carry everything Projector routes by default.
    ///
    /// Three stereo outputs - the full mix, DX/SFX and MX - so six channels. All of
    /// them live on the loopback device, because the interface's own channels belong
    /// to the DAW; see ``AggregateChannelMap``.
    ///
    /// A floor, not a target: the 2-channel build of BlackHole is common and carries
    /// one stereo pair, which is the case worth telling the user about rather than
    /// silently routing a third of their audio.
    static let minimumChannels = AggregateChannelMap.requiredVirtualChannels

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

    /// Where the installer writes its driver bundles.
    private static let driverDirectory = "/Library/Audio/Plug-Ins/HAL"

    /// Whether a wide enough driver bundle exists on disk.
    ///
    /// Separate from whether a *device* exists, because the two come apart: the
    /// installer writes the bundle immediately, but CoreAudio only publishes the
    /// device once `coreaudiod` reloads its plug-ins. If another application is
    /// holding audio open - a DAW, or Projector itself - that reload can be deferred
    /// until the machine restarts.
    ///
    /// Observed on a real machine: `BlackHole16ch.driver` present in this directory
    /// while the device list still showed only the 2-channel build.
    static var driverBundleInstalled: Bool {
        let bundle = "\(driverDirectory)/BlackHole\(preferredChannelCount)ch.driver"
        return FileManager.default.fileExists(atPath: bundle)
    }

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

        /// The driver is on disk but macOS has not published its device yet.
        ///
        /// The remedy is a restart, not another download. Without this case the setup
        /// flow waits for a device that will never arrive in this boot, having just
        /// told the user it would continue on its own.
        case installedPendingRestart

        /// No BlackHole build is installed.
        case missing
    }

    /// Assesses the loopback devices available.
    ///
    /// - Parameters:
    ///   - devices: Every output device currently known to the system.
    ///   - driverOnDisk: Whether a wide enough driver bundle is installed. Defaults to
    ///     inspecting the filesystem; passed explicitly by tests so the answer does
    ///     not depend on what happens to be installed on the machine running them.
    /// - Returns: What is installed and whether it will do.
    /// - Note: Prefers the widest build when several are installed, since a machine
    ///   carrying both 2ch and 16ch should use the one that fits.
    static func readiness(
        in devices: [AudioDevice],
        driverOnDisk: Bool = driverBundleInstalled
    ) -> Readiness {
        let candidates = devices
            .filter(isVirtualPortDevice)
            .sorted { $0.outputChannelCount > $1.outputChannelCount }

        if let widest = candidates.first, widest.outputChannelCount >= minimumChannels {
            return .ready(widest)
        }

        // Checked before reporting the narrow build or nothing at all: a machine can
        // hold a freshly installed wide driver and still be showing only the old
        // narrow device, and telling that user to install again would be wrong twice
        // over - they already have it, and downloading it again will not help.
        if driverOnDisk {
            return .installedPendingRestart
        }

        guard let widest = candidates.first else { return .missing }
        return .insufficientChannels(
            device: widest,
            found: widest.outputChannelCount,
            required: minimumChannels
        )
    }
}
