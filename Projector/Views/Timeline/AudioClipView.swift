import SwiftUI
import Iconoir

/// Visual representation of a single audio clip on an audio lane
struct AudioClipView: View {
    let clip: AudioClip
    let lane: AudioLane
    let isActive: Bool
    let pixelsPerFrame: CGFloat
    let waveformData: WaveformData?
    let isSelected: Bool
    let onSelect: () -> Void
    let onDoubleClick: () -> Void

    /// Track height for audio clips
    private let trackHeight: CGFloat = 50

    var body: some View {
        ZStack(alignment: .leading) {
            // Background
            RoundedRectangle(cornerRadius: 4)
                .fill(backgroundFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(borderColor, lineWidth: isSelected ? 2 : 1)
                )

            // Waveform layer
            waveformLayer
                .clipShape(RoundedRectangle(cornerRadius: 4))

            // Overlay content
            HStack(spacing: 4) {
                // Source type indicator
                sourceTypeIcon
                    .frame(width: 12, height: 12)
                    .foregroundColor(.white.opacity(0.7))

                // Clip name
                Text(clip.displayName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Spacer(minLength: 0)

                // Muted indicator
                if clip.isMuted {
                    Iconoir.soundOff.asImage
                        .frame(width: 10, height: 10)
                        .foregroundColor(.red.opacity(0.8))
                }

                // Volume indicator if not default
                if clip.volume != 1.0 && !clip.isMuted {
                    Text(String(format: "%.0f%%", clip.volume * 100))
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .frame(width: clipWidth, height: trackHeight)
        .opacity(clip.isMuted || lane.isMuted ? 0.5 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onDoubleClick)
        .onTapGesture(count: 1, perform: onSelect)
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

    private var sourceTypeIcon: some View {
        Group {
            switch clip.sourceType {
            case .videoTrack:
                Iconoir.videoCamera.asImage
            case .audioFile:
                Iconoir.soundHigh.asImage
            }
        }
    }

    // MARK: - Waveform Layer

    @ViewBuilder
    private var waveformLayer: some View {
        GeometryReader { geometry in
            if let data = waveformData, !data.samples.isEmpty {
                // Trim waveform samples to match clip region
                let trimmedSamples = trimmedWaveformSamples(from: data, width: geometry.size.width)

                WaveformShape(samples: trimmedSamples)
                    .stroke(Color.white.opacity(0.4), lineWidth: 1)
                    .frame(height: geometry.size.height * 0.8)
                    .offset(y: geometry.size.height * 0.1)
            }
        }
    }

    private func trimmedWaveformSamples(from data: WaveformData, width: CGFloat) -> [Float] {
        guard !data.samples.isEmpty, data.duration > 0 else { return [] }

        let samplesPerSecond = Double(data.samples.count) / data.duration
        let startSample = Int(Double(clip.sourceStartFrame) / 24.0 * samplesPerSecond) // Approximate
        let endSample = startSample + Int(Double(clip.durationFrames) / 24.0 * samplesPerSecond)

        let clampedStart = max(0, min(startSample, data.samples.count - 1))
        let clampedEnd = max(clampedStart + 1, min(endSample, data.samples.count))

        return Array(data.samples[clampedStart..<clampedEnd])
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
            waveformData: WaveformData(
                trackIndex: 0,
                samples: (0..<200).map { _ in Float.random(in: 0...0.8) },
                samplesPerSecond: 100,
                duration: 100
            ),
            isSelected: false,
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
            onSelect: {},
            onDoubleClick: {}
        )
    }
    .padding()
    .background(Color(white: 0.15))
}
