import SwiftUI
import Iconoir
import DSWaveformImageViews
import DSWaveformImage

/// Visual representation of a single audio clip on an audio lane
struct AudioClipView: View {
    let clip: AudioClip
    let lane: AudioLane
    let isActive: Bool
    let pixelsPerFrame: CGFloat
    let waveformData: WaveformData?
    let isSelected: Bool
    let isLoadingWaveform: Bool
    let onSelect: () -> Void
    let onDoubleClick: () -> Void

    /// Track height for audio clips
    private let trackHeight: CGFloat = 50
    /// Header height for filename
    private let headerHeight: CGFloat = 18

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Background
            RoundedRectangle(cornerRadius: 4)
                .fill(backgroundFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(borderColor, lineWidth: isSelected ? 2 : 1)
                )

            VStack(spacing: 0) {
                // Header with filename
                HStack(spacing: 4) {
                    Text(clip.displayName)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    // Muted indicator
                    if clip.isMuted {
                        Iconoir.soundOff.asImage
                            .frame(width: 10, height: 10)
                            .foregroundColor(.red)
                    }

                    // Volume indicator if not default
                    if clip.volume != 1.0 && !clip.isMuted {
                        Text(String(format: "%.0f%%", clip.volume * 100))
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
                .padding(.horizontal, 6)
                .frame(height: headerHeight)
                .background(laneColor.opacity(0.9))

                // Waveform area - use DSWaveformImage's native view
                ZStack {
                    waveformLayer
                        .clipShape(
                            UnevenRoundedRectangle(
                                topLeadingRadius: 0,
                                bottomLeadingRadius: 4,
                                bottomTrailingRadius: 4,
                                topTrailingRadius: 0
                            )
                        )
                }
                .frame(height: trackHeight - headerHeight)
            }
        }
        .frame(width: clipWidth, height: trackHeight)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .opacity(clip.isMuted || lane.isMuted ? 0.5 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            onSelect()
            onDoubleClick()
        }
        .help(clip.sourceURL.lastPathComponent)
    }

    // MARK: - Computed Properties

    private var clipWidth: CGFloat {
        max(40, CGFloat(clip.durationFrames) * pixelsPerFrame)
    }

    private var backgroundFill: some ShapeStyle {
        let baseColor = laneColor
        if isActive {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [baseColor.opacity(0.9), baseColor.opacity(0.7)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        return AnyShapeStyle(
            LinearGradient(
                colors: [baseColor.opacity(0.7), baseColor.opacity(0.5)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var laneColor: Color {
        // Use lane ID to get consistent color
        let colors: [Color] = [
            .blue, .green, .orange, .purple, .pink, .cyan, .mint, .indigo
        ]
        let index = abs(lane.id.hashValue) % colors.count
        return colors[index]
    }

    private var borderColor: Color {
        if isSelected {
            return .white
        }
        if isActive {
            return .white.opacity(0.3)
        }
        return .white.opacity(0.1)
    }

    // MARK: - Waveform Layer using DSWaveformImage

    @ViewBuilder
    private var waveformLayer: some View {
        // Use DSWaveformImage's native WaveformView for proper rendering
        WaveformView(
            audioURL: clip.sourceURL,
            configuration: waveformConfiguration
        )
        .drawingGroup()
    }

    private var waveformConfiguration: Waveform.Configuration {
        Waveform.Configuration(
            style: .striped(
                .init(
                    color: .white.withAlphaComponent(0.8),
                    width: 2,
                    spacing: 1,
                    lineCap: .round
                )
            ),
            damping: .init(percentage: 0.125, sides: .both),
            scale: 1.0,
            verticalScalingFactor: 0.95,
            shouldAntialias: true
        )
    }
}

#Preview {
    VStack(spacing: 4) {
        AudioClipView(
            clip: AudioClip(
                sourceURL: URL(fileURLWithPath: "/path/to/audio.wav"),
                timelineStartFrame: 0,
                durationFrames: 2400,
                sourceStartFrame: 0,
                sourceType: .audioFile
            ),
            lane: AudioLane(name: "Audio 1"),
            isActive: true,
            pixelsPerFrame: 0.5,
            waveformData: nil,
            isSelected: false,
            isLoadingWaveform: false,
            onSelect: {},
            onDoubleClick: {}
        )

        AudioClipView(
            clip: AudioClip(
                sourceURL: URL(fileURLWithPath: "/path/to/video.mov"),
                timelineStartFrame: 2400,
                durationFrames: 1800,
                sourceStartFrame: 0,
                sourceType: .videoTrack,
                sourceTrackIndex: 0,
                isMuted: true
            ),
            lane: AudioLane(name: "Audio 2"),
            isActive: false,
            pixelsPerFrame: 0.5,
            waveformData: nil,
            isSelected: true,
            isLoadingWaveform: true,
            onSelect: {},
            onDoubleClick: {}
        )
    }
    .padding()
    .background(Color(white: 0.15))
}
