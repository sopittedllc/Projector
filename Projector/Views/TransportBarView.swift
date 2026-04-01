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
                .glassControl()

            // Timecode display
            HStack(spacing: Spacing.xs) {
                Text("TC:")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)

                Text(playbackEngine.currentTimecode.stringValue())
                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                    .foregroundColor(.primary)
            }
            .padding(.horizontal, 10)
            .frame(height: controlBoxHeight)
            .glassControl()

            // Transport controls
            HStack(spacing: Spacing.sm) {
                Button(action: { playbackEngine.stepBackward() }) {
                    Iconoir.skipPrev.asImage
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(GlassTransportButtonStyle())
                .disabled(!playbackEngine.hasContent)

                Button(action: { playbackEngine.togglePlayback() }) {
                    (playbackEngine.isPlaying ? Iconoir.pauseSolid.asImage : Iconoir.playSolid.asImage)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(GlassTransportButtonStyle(isActive: playbackEngine.isPlaying))
                .disabled(!playbackEngine.hasContent)
                .keyboardShortcut(.space, modifiers: [])

                Button(action: { playbackEngine.stepForward() }) {
                    Iconoir.skipNext.asImage
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(GlassTransportButtonStyle())
                .disabled(!playbackEngine.hasContent)

                Button(action: { playbackEngine.stop() }) {
                    Iconoir.square.asImage
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(GlassTransportButtonStyle())
                .disabled(!playbackEngine.hasContent)
            }
            .padding(.horizontal, 10)
            .frame(height: controlBoxHeight)
            .glassControl()

            Spacer()

            // Right: Settings
            Button(action: onSettingsPressed) {
                Iconoir.settings.asImage
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(GlassTransportButtonStyle())
        }
        .padding(Spacing.sm)
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
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.sm)
            .glassControl()
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
