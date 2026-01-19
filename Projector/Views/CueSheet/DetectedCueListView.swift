import SwiftUI
import SwiftTimecodeCore

/// Displays detected cues in a simple numbered list
struct DetectedCueListView: View {
    let cues: [DetectedCue]
    let frameRate: TimecodeFrameRate
    let clipName: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Detected Cues")
                    .font(.headline)
                Spacer()
                Text(clipName)
                    .foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            if cues.isEmpty {
                ContentUnavailableView(
                    "No Activity Detected",
                    systemImage: "waveform.slash",
                    description: Text("The audio region appears to be silent.")
                )
            } else {
                // Column headers
                HStack(spacing: 0) {
                    Text("#")
                        .frame(width: 40, alignment: .leading)
                    Text("TC IN")
                        .frame(width: 120, alignment: .leading)
                    Text("TC OUT")
                        .frame(width: 120, alignment: .leading)
                    Text("DURATION")
                        .frame(width: 120, alignment: .leading)
                    Spacer()
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor))

                // Cue list
                List(cues) { cue in
                    HStack(spacing: 0) {
                        Text("\(cue.number)")
                            .frame(width: 40, alignment: .leading)
                            .monospacedDigit()
                        Text(cue.timecodeIn.stringValue())
                            .frame(width: 120, alignment: .leading)
                            .monospaced()
                        Text(cue.timecodeOut.stringValue())
                            .frame(width: 120, alignment: .leading)
                            .monospaced()
                        Text(cue.durationTimecode(at: frameRate).stringValue())
                            .frame(width: 120, alignment: .leading)
                            .monospaced()
                        Spacer()
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                }
                .listStyle(.plain)
            }

            Divider()

            // Footer
            HStack {
                Text("\(cues.count) cue\(cues.count == 1 ? "" : "s") detected")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 500, minHeight: 300)
    }
}
