import SwiftUI
import SwiftTimecodeCore
import Iconoir

/// Shared height for transport bar control boxes
private let controlBoxHeight: CGFloat = TransportLayout.controlBoxHeight

/// Bottom transport bar with timecode display and controls
struct TransportBarView: View {
    @ObservedObject var playbackEngine: PlaybackEngine
    let onSettingsPressed: () -> Void

    var body: some View {
        HStack {
            // Frame rate display
            Text("\(Int(playbackEngine.frameRate.fps))fps")
                .font(.system(size: 16, weight: .medium, design: .monospaced))
                .foregroundColor(.primary)
                .padding(.horizontal, 10)
                .frame(height: controlBoxHeight)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                )

            // Timecode display
            HStack(spacing: 4) {
                Text("TC:")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)

                Text(playbackEngine.currentTimecode.stringValue())
                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                    .foregroundColor(.primary)
            }
            .padding(.horizontal, 10)
            .frame(height: controlBoxHeight)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
            )

            // Transport controls
            HStack(spacing: 8) {
                Button(action: { playbackEngine.stepBackward() }) {
                    Iconoir.skipPrev.asImage
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .disabled(!playbackEngine.hasContent)

                Button(action: { playbackEngine.togglePlayback() }) {
                    (playbackEngine.isPlaying ? Iconoir.pauseSolid.asImage : Iconoir.playSolid.asImage)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .disabled(!playbackEngine.hasContent)
                .keyboardShortcut(.space, modifiers: [])

                Button(action: { playbackEngine.stepForward() }) {
                    Iconoir.skipNext.asImage
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .disabled(!playbackEngine.hasContent)

                Button(action: { playbackEngine.stop() }) {
                    Iconoir.square.asImage
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .disabled(!playbackEngine.hasContent)
            }
            .padding(.horizontal, 10)
            .frame(height: controlBoxHeight)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
            )

            Spacer()

            // Right: Settings
            Button(action: onSettingsPressed) {
                Iconoir.settings.asImage
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

/// Simple styled timecode display (non-editable, for overlays)
struct TimecodeDisplayView: View {
    let timecode: Timecode

    var body: some View {
        Text(timecode.stringValue())
            .font(.system(size: 28, weight: .medium, design: .monospaced))
            .foregroundColor(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
            )
    }
}

// Backward compatibility alias
typealias TransportBarViewForEngine = TransportBarView

#Preview {
    TransportBarView(
        playbackEngine: PlaybackEngine(),
        onSettingsPressed: {}
    )
    .frame(width: 600)
}
