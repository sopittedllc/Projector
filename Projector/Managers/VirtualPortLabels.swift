//
//  VirtualPortLabels.swift
//  Projector
//
//  Names the aggregate's inputs, so a DAW lists devices and stems rather than numbers.
//

import CoreAudio
import Foundation

/// Names the ports a DAW sees when it opens Projector's aggregate device.
///
/// ## The problem
///
/// A DAW opening the aggregate lists every one of its inputs, and a device that reports
/// no channel names gets a generated one - Cubase shows forty-eight rows reading
/// "Projector Aggregate Device 1" through "48". Nothing says which are the user's
/// interface, which reach Projector, or which pair carries dialogue.
///
/// ## What is written
///
/// Every input channel is named, so no port is left generic:
///
/// | Channel | Name |
/// |---|---|
/// | Carrying one of Projector's outputs | The output, per channel - "DX/SFX L" |
/// | Anything else | Its device and its own number - "Aurora(n)-TB3 7" |
///
/// The second form is deliberately the same string ``AggregateChannelOrigin/label(firstChannel:channelCount:)``
/// puts in the settings rows, so the port list in the DAW and the rows in Projector read
/// alike.
///
/// ## Written on the aggregate, not on the devices underneath it
///
/// `kAudioObjectPropertyElementName` is writable on the aggregate itself, and a name set
/// there overrides the one inherited from the sub-device - both measured, neither
/// promised in the headers. That matters: an earlier version wrote on the loopback device
/// instead, which worked, but renamed channels system-wide for every other application
/// using BlackHole. Writing on the aggregate keeps the change inside the device Projector
/// created, and leaves the user's own interface untouched.
///
/// The names still outlive this process, as the aggregate does. They go away with it.
enum VirtualPortLabels {

    /// Appended to the first and second channel of a stereo output.
    ///
    /// Spelled out per channel rather than left as "DX/SFX 1"/"DX/SFX 2", because a DAW
    /// shows these against a stereo input pair where L and R are the distinction that
    /// matters and a number is not.
    private static let stereoSuffixes = [" L", " R"]

    /// Names every input channel of the aggregate.
    ///
    /// - Parameters:
    ///   - outputs: Every output mapped on the aggregate. Those on the interface half are
    ///     ignored: they never reach the DAW, so the channel is better described by the
    ///     interface it belongs to than by what Projector sends there.
    ///   - origin: How the aggregate's channels divide between its two halves.
    static func apply(outputs: [MappedAudioOutput], origin: AggregateChannelOrigin) {
        guard let deviceID = AggregateDeviceManager.findAggregate(),
              origin.totalChannelCount > 0 else { return }

        var stems = [Int: String]()
        for output in outputs {
            let firstChannel = output.channelStart + 1
            guard origin.map.reachesDAW(firstChannel: firstChannel) else { continue }

            for offset in 0..<output.channelCount {
                stems[firstChannel + offset] = name(for: output, channelOffset: offset)
            }
        }

        for channel in 1...origin.totalChannelCount {
            let label = stems[channel]
                ?? origin.label(firstChannel: channel, channelCount: 1)
            setName(label, on: deviceID, channel: channel)
        }
    }

    /// Clears every name Projector wrote.
    ///
    /// Rarely needed - the names live on the aggregate and go away with it - but a device
    /// that survives while routing is switched off should not keep advertising stems.
    ///
    /// - Parameter channelCount: How many input channels the aggregate has.
    static func clear(channelCount: Int) {
        guard let deviceID = AggregateDeviceManager.findAggregate(), channelCount > 0 else {
            return
        }

        for channel in 1...channelCount {
            setName("", on: deviceID, channel: channel)
        }
    }

    // MARK: - Naming

    /// What one channel of an output is called.
    ///
    /// - Parameters:
    ///   - output: The output occupying the channel.
    ///   - channelOffset: Which of its channels this is, counted from zero.
    /// - Returns: The output's name, qualified when it spans more than one channel.
    static func name(for output: MappedAudioOutput, channelOffset: Int) -> String {
        guard output.channelCount > 1 else { return output.name }

        if output.channelCount == stereoSuffixes.count,
           channelOffset < stereoSuffixes.count {
            return output.name + stereoSuffixes[channelOffset]
        }
        // Wider than stereo: numbered, because L/R stops meaning anything.
        return "\(output.name) \(channelOffset + 1)"
    }

    // MARK: - CoreAudio

    /// Writes one channel's name.
    ///
    /// Failures are deliberately silent. A driver that refuses the write leaves the DAW
    /// showing plain numbers, which is exactly where it started - not worth interrupting
    /// a user who asked for routing, not for labels.
    private static func setName(_ name: String, on deviceID: AudioDeviceID, channel: Int) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyElementName,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: AudioObjectPropertyElement(channel)
        )

        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr,
              settable.boolValue else { return }

        var value = name as CFString
        _ = withUnsafePointer(to: &value) { pointer in
            AudioObjectSetPropertyData(
                deviceID, &address, 0, nil, UInt32(MemoryLayout<CFString>.size), pointer
            )
        }
    }
}
