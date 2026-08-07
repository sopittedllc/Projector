//
//  AggregateRoutingSummary.swift
//  Projector
//
//  The port list, as the DAW will show it.
//

import SwiftUI

/// Every port on the aggregate, in the order a DAW lists them.
///
/// One row per output rather than one row per destination. Grouped by destination it
/// read as a summary of Projector's intent; what the user needs while patching is the
/// port list itself, in port order, so the panel and the DAW can be compared line by
/// line without translating between them.
///
/// One numbering system, the aggregate's, because that is the only one the user can act
/// on - it is what their DAW prints beside each port. An earlier version showed loopback
/// numbering for the stems and aggregate numbering for the interface, so the same pair
/// appeared as "1-2" in one row and "17-18" in another.
///
/// Deliberately small - no borders around each entry, no diagram. It sits under a device
/// picker in a fixed-size settings window, so it earns its place by being glanceable.
struct AggregateRoutingSummary: View {

    /// Where the outputs sit on the aggregate.
    let map: AggregateChannelMap

    /// The outputs currently mapped on the device.
    let outputs: [MappedAudioOutput]

    /// Width of the destination column, so every row's channels line up.
    private static let destinationWidth: CGFloat = 74

    /// How the interface's destination is named, since a stem names itself.
    private static let speakersTitle = "Speakers"

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            instruction
            ForEach(orderedOutputs) { output in
                portRow(output)
            }
            interfaceStartNote
        }
    }

    /// What to do with the list that follows.
    ///
    /// The rows are only useful to someone who knows they describe ports in *another*
    /// application, and which device to open there. Naming the device here is the whole
    /// instruction - everything below it is the answer to "set them how?".
    private var instruction: some View {
        Text("Select \u{201C}\(AggregateDeviceManager.aggregateName)\u{201D} in your DAW "
             + "and set the in/outs as follows:")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, Spacing.xs)
    }

    /// The outputs in the order a DAW lists their ports.
    ///
    /// Sorted by channel rather than by destination, so this reads as the port list it
    /// describes. Grouping by destination put the stems in a different order here than
    /// in the DAW, which is the confusion the whole panel exists to remove.
    private var orderedOutputs: [MappedAudioOutput] {
        outputs.sorted { $0.channelStart < $1.channelStart }
    }

    /// One port: where it goes, what it carries, and the channels a DAW will show.
    ///
    /// Outputs on the interface name their destination ("Speakers") and then the output,
    /// because "Speakers" is the fact worth reading first and the output's own name is
    /// the detail. A stem is its own destination, so it is named once.
    private func portRow(_ output: MappedAudioOutput) -> some View {
        let toDAW = reachesDAW(output)

        return HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            Label(
                toDAW ? output.name : Self.speakersTitle,
                systemImage: toDAW ? "slider.horizontal.3" : "hifispeaker"
            )
            .labelStyle(.titleAndIcon)
            .frame(width: Self.destinationWidth, alignment: .leading)

            // Only when it says something the destination has not: a stem row would
            // otherwise print its own name twice.
            Text(toDAW ? "" : output.name)
                .foregroundStyle(.secondary)

            Spacer(minLength: Spacing.sm)

            Text(channelRange(from: output.channelStart + 1, count: output.channelCount))
                .monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// Where the user's own hardware begins on the combined device.
    ///
    /// The stems take the low channels so a DAW finds them first, which pushes the
    /// interface's own channels up by the width of the loopback device. That offset is
    /// invisible and would otherwise be discovered by patching the wrong input: the
    /// interface's channel 1 is no longer the device's channel 1.
    @ViewBuilder
    private var interfaceStartNote: some View {
        if map.interfaceFirstChannel > 1 {
            Text("Your interface's own channels begin at \(map.interfaceFirstChannel).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Helpers

    private func reachesDAW(_ output: MappedAudioOutput) -> Bool {
        map.reachesDAW(firstChannel: output.channelStart + 1)
    }

    private func channelRange(from first: Int, count: Int) -> String {
        count > 1 ? "\(first)-\(first + count - 1)" : "\(first)"
    }
}
