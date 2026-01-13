import SwiftUI

/// Sheet view for embedded timecode detection with placement options
struct EmbeddedTimecodeSheetView: View {
    let formattedTimecode: String
    let sourceDescription: String
    let showSetTimelineStartOption: Bool
    let onPlaceAtTimecode: (Bool) -> Void  // Bool = setTimelineStart
    let onPlaceAtDropLocation: () -> Void
    let onCancel: () -> Void

    @State private var setTimelineStart = false

    var body: some View {
        VStack(spacing: 16) {
            // Header
            Image(systemName: "clock.badge.checkmark")
                .font(.system(size: 40))
                .foregroundColor(.accentColor)

            Text("Embedded Timecode Detected")
                .font(.headline)

            Text("This file contains embedded timecode **\(formattedTimecode)** from \(sourceDescription).")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Text("Where would you like to place it?")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Divider()

            // Checkbox for setting timeline start (only for first video)
            if showSetTimelineStartOption {
                Toggle(isOn: $setTimelineStart) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Set timeline start to this timecode")
                            .font(.body)
                        Text("The timeline will begin at \(formattedTimecode)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                .padding(.horizontal)

                Divider()
            }

            // Buttons
            HStack(spacing: 12) {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.escape)

                Button("Place at Drop Location") {
                    onPlaceAtDropLocation()
                }

                Button("Place at \(formattedTimecode)") {
                    onPlaceAtTimecode(setTimelineStart)
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 8)
        }
        .padding(24)
        .frame(width: 480)
    }
}

#Preview {
    EmbeddedTimecodeSheetView(
        formattedTimecode: "00:59:55:00",
        sourceDescription: "QuickTime timecode track",
        showSetTimelineStartOption: true,
        onPlaceAtTimecode: { setStart in
            print("Place at timecode, setStart: \(setStart)")
        },
        onPlaceAtDropLocation: {
            print("Place at drop location")
        },
        onCancel: {
            print("Cancel")
        }
    )
}
