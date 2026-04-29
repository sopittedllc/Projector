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
                .font(Typography.monoLarge)
                .foregroundColor(.primary)
                .padding(.horizontal, Spacing.md)
                .frame(height: controlBoxHeight)
                .glassControl()
                .accessibilityLabel("Frame rate: \(Int(playbackEngine.frameRate.fps)) frames per second")

            // Timecode display
            HStack(spacing: Spacing.xs) {
                Text("TC:")
                    .font(Typography.label)
                    .foregroundColor(.secondary)

                Text(playbackEngine.currentTimecode.stringValue())
                    .font(Typography.monoLarge)
                    .foregroundColor(.primary)
            }
            .padding(.horizontal, Spacing.md)
            .frame(height: controlBoxHeight)
            .glassControl()
            .accessibilityLabel("Current timecode: \(playbackEngine.currentTimecode.stringValue())")

            // Transport controls
            HStack(spacing: Spacing.sm) {
                Button(action: { playbackEngine.stepBackward() }) {
                    Image(systemName: "backward.fill")
                        .font(Typography.icon)
                }
                .buttonStyle(GlassTransportButtonStyle())
                .disabled(!playbackEngine.hasContent)
                .accessibilityLabel("Step backward one frame")
                .help("Step backward (←)")

                Button(action: { playbackEngine.togglePlayback() }) {
                    Image(systemName: playbackEngine.isPlaying ? "pause.fill" : "play.fill")
                        .font(Typography.icon)
                }
                .buttonStyle(GlassTransportButtonStyle(isActive: playbackEngine.isPlaying))
                .disabled(!playbackEngine.hasContent)
                .keyboardShortcut(.space, modifiers: [])
                .accessibilityLabel(playbackEngine.isPlaying ? "Pause" : "Play")
                .help(playbackEngine.isPlaying ? "Pause (Space)" : "Play (Space)")

                Button(action: { playbackEngine.stepForward() }) {
                    Image(systemName: "forward.fill")
                        .font(Typography.icon)
                }
                .buttonStyle(GlassTransportButtonStyle())
                .disabled(!playbackEngine.hasContent)
                .accessibilityLabel("Step forward one frame")
                .help("Step forward (→)")

                Button(action: { playbackEngine.stop() }) {
                    Image(systemName: "stop.fill")
                        .font(Typography.icon)
                }
                .buttonStyle(GlassTransportButtonStyle())
                .disabled(!playbackEngine.hasContent)
                .accessibilityLabel("Stop and return to start")
                .help("Stop")
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
                        .font(Typography.icon)
                        .foregroundColor(playbackEngine.isMeteringEnabled ? .accentColor : .secondary)
                }
                .buttonStyle(GlassIconButtonStyle(size: 16, isActive: playbackEngine.isMeteringEnabled))
                .accessibilityLabel(playbackEngine.isMeteringEnabled ? "Disable audio metering" : "Enable audio metering")
                .help(playbackEngine.isMeteringEnabled ? "Disable audio metering" : "Enable audio metering")

                if playbackEngine.isMeteringEnabled {
                    AudioMeterView(
                        leftLevel: playbackEngine.meterLevelLeft,
                        rightLevel: playbackEngine.meterLevelRight,
                        isEnabled: playbackEngine.isMeteringEnabled
                    )
                }
            }
            .padding(.horizontal, Spacing.md)
            .frame(height: controlBoxHeight)
            .glassControl()

            Spacer()

            // Right: Settings
            Button(action: onSettingsPressed) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(GlassIconButtonStyle(size: 20))
            .accessibilityLabel("Settings")
            .help("Open settings")
        }
        .padding(Spacing.sm)
        .glassPanel(cornerRadius: PanelLayout.cornerRadius)
    }
}

/// Simple styled timecode display (non-editable, for overlays)
struct TimecodeDisplayView: View {
    let timecode: Timecode

    /// Large monospace font for overlay timecode display (28pt)
    private static let overlayTimecodeFont = Font.system(size: 28, weight: .medium, design: .monospaced)

    var body: some View {
        Text(timecode.stringValue())
            .font(Self.overlayTimecodeFont)
            .foregroundColor(.primary)
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.sm)
            .glassControl()
            .accessibilityLabel("Timecode: \(timecode.stringValue())")
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
