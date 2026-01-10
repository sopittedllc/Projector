import SwiftUI
import SwiftTimecodeCore
import Iconoir

/// Visual representation of a single audio clip on an audio lane
struct AudioClipView: View {
    let clip: AudioClip
    let lane: AudioLane
    let isActive: Bool
    let pixelsPerFrame: CGFloat
    let frameRate: TimecodeFrameRate
    let isSelected: Bool
    let waveformCache: WaveformCache
    let showWaveform: Bool
    let interactionsEnabled: Bool
    let isOptimized: Bool
    let onSelect: () -> Void
    let onDoubleClick: () -> Void

    /// Track height for audio clips
    private let trackHeight: CGFloat = TimelineLayout.audioClipHeight
    /// Header height for filename
    private let headerHeight: CGFloat = TimelineLayout.audioClipHeaderHeight

    var body: some View {
        let clipContent = ZStack(alignment: .topLeading) {
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

                    // Optimization indicator
                    if isOptimized {
                        Image(systemName: "stopwatch.fill")
                            .font(.system(size: 8))
                            .foregroundColor(.green)
                    }

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

                // Waveform area
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

        Group {
            if interactionsEnabled {
                Button(action: onSelect) {
                    clipContent
                }
                .buttonStyle(.plain)
            } else {
                clipContent
            }
        }
        .frame(width: clipWidth, height: trackHeight)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .opacity(clip.isMuted || lane.isMuted ? 0.5 : 1.0)
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture(count: 2)
                .onEnded { _ in
                    onDoubleClick()
                }
        )
        .help(clip.sourceURL.lastPathComponent)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("audio-clip")
    }

    // MARK: - Computed Properties

    private var clipWidth: CGFloat {
        max(40, CGFloat(clip.durationFrames) * pixelsPerFrame)
    }

    private var clipDurationSeconds: Double {
        Double(clip.durationFrames) / frameRate.fps
    }

    private var clipStartSeconds: Double {
        max(0, Double(clip.sourceStartFrame) / frameRate.fps)
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

    // MARK: - Waveform Layer

    @ViewBuilder
    private var waveformLayer: some View {
        ZStack {
            Rectangle()
                .fill(laneColor.opacity(0.3))

            if showWaveform {
                GeometryReader { geometry in
                    let targetCount = max(1, Int(clipWidth))
                    if let renderData = waveformCache.renderData(for: clip, targetWidth: targetCount) {
                        let sliced = slice(level: renderData.level, duration: renderData.duration)
                        ZStack {
                            Rectangle()
                                .fill(Color.white.opacity(0.14))
                                .frame(height: 1)
                            WaveformBarsView(level: sliced, mode: .rms)
                                .stroke(Color.white.opacity(0.85), lineWidth: 0.7)
                        }
                        .drawingGroup()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .accessibilityIdentifier("audio-waveform")
                    } else if waveformCache.isLoading(for: clip) {
                        ProgressView()
                            .scaleEffect(0.5)
                            .tint(.white.opacity(0.6))
                            .accessibilityIdentifier("audio-waveform-loading")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            }
        }
    }

    private func slice(level: WaveformLevel, duration: Double) -> WaveformLevel {
        guard duration > 0, level.count > 0 else { return level }
        let startRatio = max(0, min(1, clipStartSeconds / duration))
        let endRatio = max(0, min(1, (clipStartSeconds + clipDurationSeconds) / duration))

        let startIndex = Int(Double(level.count) * startRatio)
        let endIndex = max(startIndex + 1, Int(Double(level.count) * endRatio))
        let clampedEnd = min(level.count, endIndex)

        let minSlice = Array(level.min[startIndex..<clampedEnd])
        let maxSlice = Array(level.max[startIndex..<clampedEnd])
        let rmsSlice = Array(level.rms[startIndex..<clampedEnd])
        return WaveformLevel(min: minSlice, max: maxSlice, rms: rmsSlice)
    }
}

private struct WaveformBarsView: Shape {
    enum Mode {
        case rms
        case peak
    }

    let level: WaveformLevel
    let mode: Mode
    var centerLine: Bool = true

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard level.count > 0 else { return path }

        let width = rect.width
        let height = rect.height
        let midY = rect.midY
        let xStep = width / CGFloat(level.count)
        let amplitudeScale: CGFloat = mode == .rms ? 0.62 : 0.72
        var floor = level.rmsFloor
        let peak = max(level.rmsPeak, 0.0001)
        if peak - floor < peak * 0.1 {
            floor = peak * 0.9
        }
        let range = max(peak - floor, 0.0001)
        let gamma: Double = 0.6
        let minVisible: Float = 0.005

        for index in 0..<level.count {
            let x = CGFloat(index) * xStep
            let rawValue: Float
            switch mode {
            case .rms:
                rawValue = level.rms[index]
            case .peak:
                rawValue = max(level.max[index], level.rms[index])
            }

            let normalized = max(0, min(1, (rawValue - floor) / range))
            if normalized < minVisible {
                continue
            }

            let scaled = pow(Double(normalized), gamma)
            let amplitude = CGFloat(scaled) * (height / 2) * amplitudeScale

            if centerLine {
                path.move(to: CGPoint(x: x, y: midY - amplitude))
                path.addLine(to: CGPoint(x: x, y: midY + amplitude))
            } else {
                path.move(to: CGPoint(x: x, y: height))
                path.addLine(to: CGPoint(x: x, y: height - amplitude * 2))
            }
        }
        return path
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
            frameRate: .fps24,
            isSelected: false,
            waveformCache: WaveformCache(),
            showWaveform: true,
            interactionsEnabled: true,
            isOptimized: true,
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
            frameRate: .fps24,
            isSelected: true,
            waveformCache: WaveformCache(),
            showWaveform: true,
            interactionsEnabled: true,
            isOptimized: false,
            onSelect: {},
            onDoubleClick: {}
        )
    }
    .padding()
    .background(Color(white: 0.15))
}
