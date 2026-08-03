import SwiftUI

/// Modifier flags for selection operations
struct SelectionModifiers: OptionSet {
    let rawValue: Int

    static let command = SelectionModifiers(rawValue: 1 << 0)
    static let shift = SelectionModifiers(rawValue: 1 << 1)

    /// Get current modifier flags from NSEvent
    static var current: SelectionModifiers {
        var modifiers = SelectionModifiers()
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return modifiers
    }
}

/// Visual representation of a single video reel on the timeline
struct VideoReelClipView: View {
    let reel: VideoReel
    let isActive: Bool
    let pixelsPerFrame: CGFloat
    @ObservedObject var thumbnailCache: ThumbnailCache
    let showThumbnails: Bool
    let isSelected: Bool
    let interactionsEnabled: Bool
    let isOptimized: Bool
    let timelineStartTimecode: String?

    /// Part of this clip the viewport can actually show, in clip-local points.
    ///
    /// The filmstrip draws one cell per ``thumbnailWidth`` of clip, so its cost
    /// tracked the clip's *zoomed* width rather than the window's: a
    /// feature-length reel at full zoom is over half a million points wide and
    /// asked for eleven thousand cells, each decoding a JPEG, on every layout
    /// pass. That is the beach ball. Given the visible span, the strip draws the
    /// cells inside it and nothing else, so the cost is bounded by the window.
    ///
    /// `nil` means "no viewport known" - previews and tests - and falls back to
    /// the whole clip, which is safe at the widths those run at.
    let visibleXRange: ClosedRange<CGFloat>?

    let onSelect: (SelectionModifiers) -> Void
    let onDoubleClick: () -> Void
    let onSetTimelineStart: () -> Void

    /// Clip height (fits within 50px track with padding)
    private let clipHeight: CGFloat = TimelineLayout.videoClipHeight
    /// Width of each thumbnail in the filmstrip
    private let thumbnailWidth: CGFloat = TimelineLayout.thumbnailWidth

    var body: some View {
        let clipContent = ZStack(alignment: .leading) {
            // Thumbnail filmstrip background
            Group {
                if showThumbnails {
                    thumbnailFilmstrip
                } else {
                    Rectangle()
                        .fill(Color(white: 0.15))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))

            // Gradient overlay for text readability
            RoundedRectangle(cornerRadius: 4)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.6),
                            Color.black.opacity(0.2),
                            Color.black.opacity(0.2),
                            Color.black.opacity(0.4)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )

            // Border
            RoundedRectangle(cornerRadius: 4)
                .stroke(borderColor, lineWidth: isSelected ? 2 : 1)

            // Content overlay
            VStack(spacing: 0) {
                HStack(spacing: Spacing.xs) {
                    // Reel info
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        HStack(spacing: Spacing.xs) {
                            Text(reel.displayName)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .shadow(color: .black.opacity(0.5), radius: 1, x: 0, y: 1)

                            // Optimization indicator
                            if isOptimized {
                                Image(systemName: "stopwatch.fill")
                                    .font(Typography.captionSmall)
                                    .foregroundColor(.green)
                                    .shadow(color: .black.opacity(0.5), radius: 1, x: 0, y: 1)
                            }
                        }

                        Text(formattedDuration)
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.9))
                            .shadow(color: .black.opacity(0.5), radius: 1, x: 0, y: 1)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Spacing.sm)
                .padding(.top, Spacing.xs)

                Spacer(minLength: 0)

                // Timeline start timecode, along the bottom edge
                if let tc = timelineStartTimecode, reelWidth > 80 {
                    HStack {
                        Text(tc)
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.7))
                            .padding(.horizontal, Spacing.xs)
                            .padding(.vertical, 1)
                            .background(Color.black.opacity(0.4))
                            .cornerRadius(2)

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Spacing.xs)
                    .padding(.bottom, Spacing.xs)
                }
            }

            // Active highlight border
            if isActive {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.accentColor, lineWidth: 2)
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
        .frame(width: reelWidth, height: clipHeight)
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
            .disabled(reel.timelineStartFrame == 0)
        }
    }

    // MARK: - Thumbnail Filmstrip

    @ViewBuilder
    private var thumbnailFilmstrip: some View {
        GeometryReader { geometry in
            let clipWidth = max(1, geometry.size.width)
            let totalCells = max(1, Int(ceil(clipWidth / thumbnailWidth)))

            // Cells the window can reach, and only those. Widened by one cell
            // each way so a scroll of less than a cell does not expose a gap
            // before the next layout pass fills it.
            let visible = visibleXRange ?? 0...clipWidth
            let firstCell = max(0, Int(floor(visible.lowerBound / thumbnailWidth)) - 1)
            let lastCell = min(totalCells - 1, Int(ceil(visible.upperBound / thumbnailWidth)) + 1)

            if firstCell <= lastCell {
                let clipDuration = Double(reel.durationFrames) / reel.sourceFrameRate.fps

                // Resolution follows the whole clip, not the drawn slice, so
                // panning does not re-request a different level on every scroll.
                let strip = thumbnailCache.strip(for: reel, targetCount: totalCells)

                HStack(spacing: 0) {
                    ForEach(firstCell...lastCell, id: \.self) { index in
                        // Calculate the source time for this thumbnail cell
                        let cellStartX = CGFloat(index) * thumbnailWidth
                        let cellCenterX = cellStartX + thumbnailWidth / 2
                        let fractionThrough = cellCenterX / clipWidth
                        let sourceTimeOffset = clipDuration * fractionThrough
                        let sourceTime = Double(reel.sourceStartFrame) / reel.sourceFrameRate.fps + sourceTimeOffset

                        thumbnailCell(at: sourceTime, strip: strip)
                            .frame(width: thumbnailWidth, height: geometry.size.height)
                    }
                }
                // Rasterized after the slice is taken, never before: a
                // drawingGroup over the full zoomed clip is a request for a
                // half-million-point texture.
                .drawingGroup()
                .offset(x: CGFloat(firstCell) * thumbnailWidth)
            }
        }
    }

    @ViewBuilder
    private func thumbnailCell(at sourceTime: Double, strip: ThumbnailStrip?) -> some View {
        if let strip,
           let index = strip.index(at: sourceTime),
           let image = thumbnailCache.image(
               reelId: reel.id,
               bucketCount: strip.count,
               index: index,
               in: strip
           ) {
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            // Placeholder pattern
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [Color(white: 0.25), Color(white: 0.18)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
    }

    // MARK: - Computed Properties

    private var reelWidth: CGFloat {
        max(TimelineLayout.minimumClipWidth, CGFloat(reel.durationFrames) * pixelsPerFrame)
    }

    private var borderColor: Color {
        if isSelected {
            return .accentColor
        }
        return .white.opacity(0.15)
    }

    private var formattedDuration: String {
        let totalSeconds = Double(reel.durationFrames) / reel.sourceFrameRate.fps
        let hours = Int(totalSeconds) / 3600
        let minutes = (Int(totalSeconds) % 3600) / 60
        let seconds = Int(totalSeconds) % 60
        let frames = reel.durationFrames % Int(reel.sourceFrameRate.fps)

        if hours > 0 {
            return String(format: "%d:%02d:%02d:%02d", hours, minutes, seconds, frames)
        }
        return String(format: "%02d:%02d:%02d", minutes, seconds, frames)
    }
}

#Preview {
    HStack(spacing: Spacing.xs) {
        VideoReelClipView(
            reel: VideoReel(
                sourceURL: URL(fileURLWithPath: "/path/to/Reel_001.mov"),
                timelineStartFrame: 0,
                durationFrames: 2880,
                sourceStartFrame: 0,
                sourceFrameRate: .fps24
            ),
            isActive: true,
            pixelsPerFrame: 0.5,
            thumbnailCache: ThumbnailCache(),
            showThumbnails: true,
            isSelected: false,
            interactionsEnabled: true,
            isOptimized: true,
            timelineStartTimecode: "01:00:00:00",
            visibleXRange: nil,
            onSelect: { _ in },
            onDoubleClick: {},
            onSetTimelineStart: {}
        )

        VideoReelClipView(
            reel: VideoReel(
                sourceURL: URL(fileURLWithPath: "/path/to/Reel_002.mov"),
                timelineStartFrame: 2880,
                durationFrames: 1800,
                sourceStartFrame: 0,
                sourceFrameRate: .fps24
            ),
            isActive: false,
            pixelsPerFrame: 0.5,
            thumbnailCache: ThumbnailCache(),
            showThumbnails: true,
            isSelected: true,
            interactionsEnabled: true,
            isOptimized: false,
            timelineStartTimecode: "01:02:00:00",
            visibleXRange: nil,
            onSelect: { _ in },
            onDoubleClick: {},
            onSetTimelineStart: {}
        )
    }
    .padding()
    .background(Color(white: 0.15))
}
