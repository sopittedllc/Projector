import SwiftUI
import SwiftTimecodeCore

/// Visual representation of a single audio clip on an audio lane
struct AudioClipView: View {
    let clip: AudioClip
    let lane: AudioLane
    let laneIndex: Int
    let isActive: Bool
    let pixelsPerFrame: CGFloat
    let frameRate: TimecodeFrameRate
    let isSelected: Bool
    let waveformCache: WaveformCache
    let showWaveform: Bool
    let interactionsEnabled: Bool
    let timelineStartTimecode: String?
    let onSelect: (SelectionModifiers) -> Void
    let onDoubleClick: () -> Void
    let onSetTimelineStart: () -> Void

    /// Optional override for clip height (uses audioClipHeight if nil)
    var clipHeight: CGFloat?

    /// Part of this clip the viewport can actually show, in clip-local points.
    ///
    /// The waveform used to be drawn, and rasterized, across the clip's whole *zoomed*
    /// width. At four points per frame a reel is hundreds of thousands of points wide,
    /// and `drawingGroup()` asked Metal for a texture that size - which is not a slow
    /// draw but a rejected allocation, and an `abort()`. Given the visible span, the
    /// waveform draws the part inside it and nothing else, so the texture is bounded by
    /// the window however far the user zooms in.
    ///
    /// `nil` means "no viewport known" - previews and tests - and falls back to the whole
    /// clip, which is safe at the widths those run at. Mirrors
    /// ``VideoReelClipView/visibleXRange``.
    var visibleXRange: ClosedRange<CGFloat>?

    /// Points-to-pixels ratio of the screen this clip is drawn on.
    ///
    /// Needed because ``rasterized(_:pointWidth:)`` reasons about the *texture*
    /// `drawingGroup()` allocates, which is measured in pixels: the same clip asks for
    /// twice the texture on a Retina display as on a 1x one.
    @Environment(\.displayScale) private var displayScale

    /// Track height for audio clips
    private var trackHeight: CGFloat {
        clipHeight ?? TimelineLayout.audioClipHeight
    }
    /// Header height for filename - scales with clip height
    private var headerHeight: CGFloat {
        if let height = clipHeight, height < TimelineLayout.audioClipHeight {
            // Proportionally smaller header for compact clips
            return min(TimelineLayout.audioClipHeaderHeight, height * 0.4)
        }
        return TimelineLayout.audioClipHeaderHeight
    }

    var body: some View {
        let clipContent = ZStack(alignment: .topLeading) {
            // Background
            RoundedRectangle(cornerRadius: 4)
                .fill(backgroundFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(borderColor, lineWidth: isSelected ? 3 : 1)
                )
                .overlay(
                    // Selection highlight overlay - bright glow when selected
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(isSelected ? 0.15 : 0))
                )
                .shadow(color: isSelected ? Color.white.opacity(0.5) : Color.clear, radius: 4)

            VStack(spacing: 0) {
                // Header with filename and timecode
                HStack(spacing: Spacing.xs) {
                    Text(clip.displayName)
                        .font(Typography.labelSmall)
                        .foregroundColor(.white)
                        .lineLimit(1)

                    // No optimization indicator: optimized clips used to carry a
                    // green stopwatch for the life of the project, marking
                    // finished work rather than anything the user could act on.

                    // Timeline start timecode
                    if let tc = timelineStartTimecode, clipWidth > 120 {
                        Text(tc)
                            .font(Typography.monoTiny)
                            .foregroundColor(.white.opacity(0.7))
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(Color.black.opacity(0.3))
                            .cornerRadius(2)
                    }

                    Spacer(minLength: 0)

                    // Muted indicator
                    if clip.isMuted {
                        Image(systemName: "speaker.slash")
                            .frame(width: 10, height: 10)
                            .foregroundColor(.red)
                    }

                    // Volume indicator if not default
                    if clip.volume != 1.0 && !clip.isMuted {
                        Text(String(format: "%.0f%%", clip.volume * 100))
                            .font(Typography.monoTiny)
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
                .padding(.horizontal, Spacing.sm)
                .frame(height: headerHeight)
                .background(laneColor.opacity(0.9))

                // Waveform area
                ZStack {
                    waveformLayer
                        .modifier(BottomRoundedClip(radius: 4))
                }
                .frame(height: trackHeight - headerHeight)
            }
        }

        Group {
            if interactionsEnabled {
                Button(action: { onSelect(SelectionModifiers.current) }) {
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
        .help("Double-click to set timecode position")
        .contextMenu {
            Button("Set Timecode Position...") {
                onDoubleClick()
            }

            Button("Set Timeline Start to Region") {
                onSetTimelineStart()
            }
            // Already the start; the command would do nothing.
            .disabled(clip.timelineStartFrame == 0)
        }
        // Keep the clip addressable as one timeline item while exposing useful
        // descendants (notably waveform/loading state) to VoiceOver and UI tests.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("audio-clip")
    }

    // MARK: - Computed Properties

    private var clipWidth: CGFloat {
        max(TimelineLayout.minimumClipWidth, CGFloat(clip.durationFrames) * pixelsPerFrame)
    }

    /// Widest texture Projector will ask Metal for, in pixels.
    ///
    /// `drawingGroup()` rasterizes into one texture, and a texture wider than the GPU
    /// allows is not a slow draw - it is a failed allocation, which surfaces as a crash
    /// rather than a missing waveform.
    ///
    /// The limit is 16384 on Apple Silicon and current Intel Macs, and 8192 on older
    /// Intel integrated GPUs. Zoom tops out at four points per frame, so at 24fps a clip
    /// crosses 16384 pixels after about 85 seconds on a Retina display and 8192 after
    /// about 43 - both ordinary lengths for a reel, which is why this had to be bounded
    /// rather than assumed safe.
    ///
    /// 4096 sits under every limit with room for the frame to be over-committed, and
    /// costs nothing when exceeded: rasterizing is an optimisation, so the fallback is
    /// simply to draw the waveform directly.
    static let maximumRasterizedPixelWidth: CGFloat = 4096

    /// The part of the clip actually drawn, in clip-local points.
    ///
    /// Widened by a little either side so a scroll of a few points does not expose a gap
    /// before the next layout pass fills it - the same reason the filmstrip widens by a
    /// cell. Always inside `0...clipWidth`, so the offset it produces cannot push the
    /// waveform outside its own clip.
    private var drawnSpan: ClosedRange<CGFloat> {
        let full: CGFloat = max(clipWidth, 1)
        guard let visibleXRange else { return 0...full }

        let lower = max(0, min(visibleXRange.lowerBound - Self.spanOvershoot, full))
        let upper = min(full, max(visibleXRange.upperBound + Self.spanOvershoot, 0))

        // No overlap - the clip is entirely off one side of the window. Collapse where
        // the window is rather than at the clip's start, so the empty span cannot place
        // a sliver of the opening waveform under a viewport showing the tail.
        guard upper > lower else { return lower...lower }
        return lower...upper
    }

    /// ``drawnSpan`` as a fraction of the clip's width, for slicing the levels.
    private var drawnFraction: ClosedRange<Double> {
        let full = Double(max(clipWidth, 1))
        let span = drawnSpan
        let lower = min(1, max(0, Double(span.lowerBound) / full))
        let upper = min(1, max(lower, Double(span.upperBound) / full))
        return lower...upper
    }

    /// Drawn either side of the viewport, in points.
    private static let spanOvershoot: CGFloat = 64

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
        LaneColor.color(forLaneIndex: laneIndex)
    }

    private var borderColor: Color {
        if isSelected {
            return .yellow  // Bright yellow selection border
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
                    // Resolution follows the whole clip, not the drawn slice, so panning
                    // does not re-request a different level on every scroll. Clamped
                    // because the cache tops out anyway, and because an unclamped
                    // `Int(clipWidth)` is a trap waiting for a non-finite width.
                    let targetCount = waveformCache.clampedTargetWidth(clipWidth)
                    if let renderData = waveformCache.renderData(for: clip, targetWidth: targetCount) {
                        let showChannels = renderData.isStereo
                            && geometry.size.height >= WaveformLayout.minimumStereoHeight
                        let span = drawnSpan
                        let spanWidth = max(1, span.upperBound - span.lowerBound)
                        Group {
                            if showChannels {
                                stereoWaveform(
                                    renderData,
                                    height: geometry.size.height,
                                    fraction: drawnFraction
                                )
                            } else {
                                monoWaveform(
                                    renderData,
                                    height: geometry.size.height,
                                    fraction: drawnFraction
                                )
                            }
                        }
                        .frame(width: spanWidth, height: geometry.size.height)
                        .rasterized(pointWidth: spanWidth, scale: displayScale)
                        .offset(x: span.lowerBound)
                        .frame(width: geometry.size.width, height: geometry.size.height,
                               alignment: .leading)
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

    /// The single summed trace, centred in the clip.
    private func monoWaveform(
        _ data: WaveformRenderData,
        height: CGFloat,
        fraction: ClosedRange<Double>
    ) -> some View {
        let sliced = slice(level: data.level, duration: data.duration, fraction: fraction)
        return ZStack {
            centerLine
            WaveformBarsView(level: sliced, mode: .rms)
                .stroke(Color.white.opacity(WaveformLayout.traceOpacity), lineWidth: WaveformLayout.traceWidth)
        }
    }

    /// Left above right, each in its own half with its own centre line.
    ///
    /// Stacked rather than overlaid: two traces sharing a baseline turn into one
    /// shape the moment they differ, which is precisely when the difference
    /// matters. The two levels already share a scale, so a side carrying
    /// nothing draws flat next to a side that is working.
    private func stereoWaveform(
        _ data: WaveformRenderData,
        height: CGFloat,
        fraction: ClosedRange<Double>
    ) -> some View {
        let halfHeight = height / 2

        return VStack(spacing: 0) {
            ForEach(Array(slicedChannels(data, fraction: fraction).enumerated()), id: \.offset) { _, level in
                ZStack {
                    centerLine
                    WaveformBarsView(level: level, mode: .rms, amplitudeBoost: WaveformLayout.stereoAmplitudeBoost)
                        .stroke(Color.white.opacity(WaveformLayout.traceOpacity), lineWidth: WaveformLayout.traceWidth)
                }
                .frame(height: halfHeight)
            }
        }
        .overlay(alignment: .center) {
            // Marks where one channel ends and the next begins, so the pair does
            // not read as a single trace with a gap in the middle.
            Rectangle()
                .fill(Color.black.opacity(WaveformLayout.channelDividerOpacity))
                .frame(height: WaveformLayout.hairline)
        }
    }

    private var centerLine: some View {
        Rectangle()
            .fill(Color.white.opacity(WaveformLayout.centerLineOpacity))
            .frame(height: WaveformLayout.hairline)
    }

    /// The visible portion of each channel, rescaled against the pair.
    ///
    /// `slice(level:duration:)` derives contrast from whatever it was handed, so
    /// slicing the channels one at a time would give each its own scale and undo
    /// the shared normalization done during analysis. Re-sharing here keeps the
    /// per-clip contrast that makes a quiet passage readable *and* the level
    /// difference between the sides.
    private func slicedChannels(
        _ data: WaveformRenderData,
        fraction: ClosedRange<Double>
    ) -> [WaveformLevel] {
        let sliced = data.channelLevels.prefix(2).map {
            slice(level: $0, duration: data.duration, fraction: fraction)
        }
        let floor = sliced.map(\.rmsFloor).min() ?? 0
        let peak = sliced.map(\.rmsPeak).max() ?? 0
        return sliced.map { $0.rescaled(floor: floor, peak: peak) }
    }

    /// The part of the source this clip uses, narrowed to the part on screen.
    ///
    /// - Parameters:
    ///   - level: Levels covering the whole source file.
    ///   - duration: The source's duration in seconds.
    ///   - fraction: Portion of the *clip* to keep, 0...1 across its own width.
    /// - Returns: Levels covering only that portion.
    private func slice(
        level: WaveformLevel,
        duration: Double,
        fraction: ClosedRange<Double>
    ) -> WaveformLevel {
        guard duration > 0, level.count > 0 else { return level }
        let visibleStart = clipStartSeconds + clipDurationSeconds * fraction.lowerBound
        let visibleEnd = clipStartSeconds + clipDurationSeconds * fraction.upperBound
        let startRatio = max(0, min(1, visibleStart / duration))
        let endRatio = max(0, min(1, visibleEnd / duration))

        let startIndex = Int(Double(level.count) * startRatio)
        let endIndex = max(startIndex + 1, Int(Double(level.count) * endRatio))
        let clampedEnd = min(level.count, endIndex)

        let minSlice = Array(level.min[startIndex..<clampedEnd])
        let maxSlice = Array(level.max[startIndex..<clampedEnd])
        let rmsSlice = Array(level.rms[startIndex..<clampedEnd])
        return WaveformLevel(min: minSlice, max: maxSlice, rms: rmsSlice)
    }
}

/// Fixed values for waveform drawing.
private enum WaveformLayout {
    /// Below this the lane is split into halves too thin to read, so the
    /// summed trace is drawn instead.
    ///
    /// Sized against what the timeline actually gives a waveform, which is the
    /// clip height minus its header - not the lane height. The video file's
    /// linked audio strip is the tightest case at 36 - 14.4 = 21.6pt, and an
    /// ordinary audio clip gets 50 - 18 = 32pt. A threshold set from the lane
    /// heights instead would exclude every video file, which is the one case
    /// this display was asked for.
    static let minimumStereoHeight: CGFloat = 16

    static let hairline: CGFloat = 1
    static let traceWidth: CGFloat = 0.7
    static let traceOpacity: Double = 0.85
    static let centerLineOpacity: Double = 0.14

    /// Separator between the two channels. Darker than the centre lines so the
    /// split between channels outranks the baseline within each one.
    static let channelDividerOpacity: Double = 0.35

    /// How much more of its half a stacked channel may fill. Kept below the
    /// point where a peak would touch the divider.
    static let stereoAmplitudeBoost: CGFloat = 1.3
}

private struct WaveformBarsView: Shape {
    enum Mode {
        case rms
        case peak
    }

    let level: WaveformLevel
    let mode: Mode
    var centerLine: Bool = true

    /// Multiplier on how much of the available half-height a trace may use.
    ///
    /// A stacked channel owns half the space a single trace would, so it is
    /// allowed to fill more of it - at the default scale the two traces in a
    /// 21.6pt strip would be a few points tall and read as noise.
    var amplitudeBoost: CGFloat = 1.0

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard level.count > 0 else { return path }

        let width = rect.width
        let height = rect.height
        let midY = rect.midY
        let xStep = width / CGFloat(level.count)
        let amplitudeScale: CGFloat = (mode == .rms ? 0.62 : 0.72) * amplitudeBoost
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
    VStack(spacing: Spacing.xs) {
        AudioClipView(
            clip: AudioClip(
                sourceURL: URL(fileURLWithPath: "/path/to/audio.wav"),
                timelineStartFrame: 0,
                durationFrames: 2400,
                sourceStartFrame: 0,
                sourceType: .audioFile
            ),
            lane: AudioLane(name: "Audio 1"),
            laneIndex: 0,
            isActive: true,
            pixelsPerFrame: 0.5,
            frameRate: .fps24,
            isSelected: false,
            waveformCache: WaveformCache(),
            showWaveform: true,
            interactionsEnabled: true,
            timelineStartTimecode: "01:00:00:00",
            onSelect: { _ in },
            onDoubleClick: {},
            onSetTimelineStart: {}
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
            laneIndex: 1,
            isActive: false,
            pixelsPerFrame: 0.5,
            frameRate: .fps24,
            isSelected: true,
            waveformCache: WaveformCache(),
            showWaveform: true,
            interactionsEnabled: true,
            timelineStartTimecode: "01:01:40:00",
            onSelect: { _ in },
            onDoubleClick: {},
            onSetTimelineStart: {}
        )
    }
    .padding()
    .background(Color(white: 0.15))
}

/// Clips to a shape rounded on its bottom corners only.
///
/// Uses `UnevenRoundedRectangle` wherever it exists, so the corners are drawn by
/// the same code as before. Older systems get the hand-built path below, whose
/// quadratic corners are a close but not pixel-identical match.
struct BottomRoundedClip: ViewModifier {
    let radius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 13, *) {
            content.clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: radius,
                    bottomTrailingRadius: radius,
                    topTrailingRadius: 0
                )
            )
        } else {
            content.clipShape(BottomRoundedRectangle(radius: radius))
        }
    }
}

/// A rectangle rounded on its bottom corners only, for systems without
/// `UnevenRoundedRectangle`.
struct BottomRoundedRectangle: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = min(radius, min(rect.width, rect.height) / 2)

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - r, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - r),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.closeSubpath()
        return path
    }
}

// MARK: - Bounded Rasterization

extension View {

    /// Rasterizes with `drawingGroup()`, but only while the result fits in one texture.
    ///
    /// `drawingGroup()` is an optimisation with a hard edge: it flattens the view into a
    /// single Metal texture, and a texture wider than the GPU's maximum dimension cannot
    /// be allocated at all. A timeline clip is as wide as its duration times the zoom, so
    /// zooming in far enough on an ordinary reel will cross that limit - the failure
    /// arrives as a crash while zooming, on whichever machine has the lower limit.
    ///
    /// Above the bound the view draws unrasterized, which is slower and correct, rather
    /// than faster and impossible.
    ///
    /// - Parameters:
    ///   - pointWidth: Width the view will occupy, in points.
    ///   - scale: Points-to-pixels ratio of the target screen.
    ///   - limit: Widest texture to allow, in pixels.
    /// - Returns: The view, rasterized only when that is safe.
    @ViewBuilder
    func rasterized(
        pointWidth: CGFloat,
        scale: CGFloat,
        limit: CGFloat = AudioClipView.maximumRasterizedPixelWidth
    ) -> some View {
        if pointWidth * max(scale, 1) <= limit {
            drawingGroup()
        } else {
            self
        }
    }
}
