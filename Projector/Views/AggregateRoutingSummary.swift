//
//  AggregateRoutingSummary.swift
//  Projector
//
//  Two lines that say which outputs reach the room and which reach the DAW.
//

import SwiftUI

/// A compact picture of where an aggregate device sends each output.
///
/// The thing users get wrong is not the channel numbers, it is the *sides*: which
/// outputs come out of the speakers and which travel to the DAW. So the summary is
/// organised by destination rather than by output, and each side is one line however
/// many outputs it holds.
///
/// Two numbering systems appear because the user meets both. An output on the loopback
/// half is channel 35 of the aggregate and input 3 of the loopback device; the DAW
/// only knows the second. Loopback outputs are therefore labelled with the DAW's
/// numbering, which is the number the user has to type.
///
/// Deliberately small - two lines, no borders around each entry, no diagram. It sits
/// under a device picker in a fixed-size settings window, so it earns its place by
/// being glanceable rather than complete; the per-output rows below it carry the
/// detail.
struct AggregateRoutingSummary: View {

    /// Where the outputs sit on the aggregate.
    let map: AggregateChannelMap

    /// The outputs currently mapped on the device.
    let outputs: [MappedAudioOutput]

    /// Width of the destination label column, so both rows align.
    private static let destinationWidth: CGFloat = 74

    /// Most chips shown before the rest are summarised as a count.
    private static let maximumChips = 3

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            destinationRow(
                icon: "hifispeaker",
                title: "Speakers",
                outputs: outputs.filter { !reachesDAW($0) },
                emptyNote: "nothing"
            )
            destinationRow(
                icon: "slider.horizontal.3",
                title: "Your DAW",
                outputs: outputs.filter(reachesDAW),
                emptyNote: "nothing yet"
            )
        }
    }

    // MARK: - Rows

    private func destinationRow(
        icon: String,
        title: String,
        outputs: [MappedAudioOutput],
        emptyNote: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .frame(width: Self.destinationWidth, alignment: .leading)

            if outputs.isEmpty {
                Text(emptyNote)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                HStack(spacing: Spacing.xs) {
                    ForEach(outputs.prefix(Self.maximumChips)) { output in
                        chip(for: output)
                    }
                    if outputs.count > Self.maximumChips {
                        Text("+\(outputs.count - Self.maximumChips)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// One output, named and numbered the way its destination counts channels.
    private func chip(for output: MappedAudioOutput) -> some View {
        let firstChannel = output.channelStart + 1
        let label: String
        if reachesDAW(output) {
            let firstInput = map.loopbackChannel(forAggregateChannel: firstChannel)
            label = "\(output.name) in \(channelRange(from: firstInput, count: output.channelCount))"
        } else {
            label = "\(output.name) out \(channelRange(from: firstChannel, count: output.channelCount))"
        }

        return Text(label)
            .font(.caption2)
            .monospacedDigit()
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.12))
            .cornerRadius(Spacing.xs)
    }

    // MARK: - Helpers

    private func reachesDAW(_ output: MappedAudioOutput) -> Bool {
        map.reachesDAW(firstChannel: output.channelStart + 1)
    }

    private func channelRange(from first: Int, count: Int) -> String {
        count > 1 ? "\(first)-\(first + count - 1)" : "\(first)"
    }
}
