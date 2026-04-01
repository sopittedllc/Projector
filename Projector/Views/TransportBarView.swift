import SwiftUI
import SwiftTimecodeCore

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
                .padding(.horizontal, Spacing.md)
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
            .padding(.horizontal, Spacing.md)
            .frame(height: controlBoxHeight)
            .glassControl()

            // Transport controls
            HStack(spacing: Spacing.sm) {
                Button(action: { playbackEngine.stepBackward() }) {
                    Image(systemName: "backward.fill")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(GlassTransportButtonStyle())
                .disabled(!playbackEngine.hasContent)

                Button(action: { playbackEngine.togglePlayback() }) {
                    Image(systemName: playbackEngine.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(GlassTransportButtonStyle(isActive: playbackEngine.isPlaying))
                .disabled(!playbackEngine.hasContent)
                .keyboardShortcut(.space, modifiers: [])

                Button(action: { playbackEngine.stepForward() }) {
                    Image(systemName: "forward.fill")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(GlassTransportButtonStyle())
                .disabled(!playbackEngine.hasContent)

                Button(action: { playbackEngine.stop() }) {
                    Image(systemName: "stop.fill")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(GlassTransportButtonStyle())
                .disabled(!playbackEngine.hasContent)
            }
            .padding(.horizontal, Spacing.md)
            .frame(height: controlBoxHeight)
            .glassControl()

            // Audio meter with toggle
            HStack(spacing: Spacing.sm) {
                Button(action: {
                    if playbackEngine.isMeteringEnabled {
                        playbackEngine.disableMetering()
                    } else {
                        playbackEngine.enableMetering()
                    }
                }) {
                    Image(systemName: playbackEngine.isMeteringEnabled ? "speaker.wave.2.fill" : "speaker.wave.2")
                        .frame(width: 16, height: 16)
                        .foregroundColor(playbackEngine.isMeteringEnabled ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help(playbackEngine.isMeteringEnabled ? "Disable audio metering" : "Enable audio metering")

                if playbackEngine.isMeteringEnabled {
                    AudioMeterView(
                        leftLevel: playbackEngine.meterLevelLeft,
                        rightLevel: playbackEngine.meterLevelRight,
                        isEnabled: playbackEngine.isMeteringEnabled
                    )
                }
            }
            .padding(.horizontal, Spacing.sm)
            .frame(height: controlBoxHeight)
            .glassControl()

            Spacer()

            // Right: Settings
            Button(action: onSettingsPressed) {
                Image(systemName: "gearshape")
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
