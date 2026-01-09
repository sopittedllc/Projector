import SwiftUI
import Iconoir

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
    let onSelect: () -> Void
    let onDoubleClick: () -> Void

    /// Clip height (fits within 50px track with padding)
    private let clipHeight: CGFloat = 42  // TODO: Use TimelineLayout.videoClipHeight after adding to Xcode project
    /// Width of each thumbnail in the filmstrip
    private let thumbnailWidth: CGFloat = 48  // TODO: Use TimelineLayout.thumbnailWidth after adding to Xcode project

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
            HStack(spacing: 4) {
                // Reel info
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(reel.displayName)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .shadow(color: .black.opacity(0.5), radius: 1, x: 0, y: 1)

                        // Optimization indicator
                        if isOptimized {
                            Image(systemName: "stopwatch.fill")
                                .font(.system(size: 9))
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
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            // Active highlight border
            if isActive {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.accentColor, lineWidth: 2)
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
        .frame(width: reelWidth, height: clipHeight)
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture(count: 2)
                .onEnded { _ in
                    onDoubleClick()
                }
        )
        .help(reel.sourceURL.lastPathComponent)
    }

    // MARK: - Thumbnail Filmstrip

    @ViewBuilder
    private var thumbnailFilmstrip: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                let thumbnailCount = max(1, Int(ceil(geometry.size.width / thumbnailWidth)))
                let clipDuration = Double(reel.durationFrames) / reel.sourceFrameRate.fps
                let strip = thumbnailCache.strip(for: reel, targetCount: thumbnailCount)

                ForEach(0..<thumbnailCount, id: \.self) { index in
                    // Calculate the source time for this thumbnail cell
                    let cellStartX = CGFloat(index) * thumbnailWidth
                    let cellCenterX = cellStartX + thumbnailWidth / 2
                    let fractionThrough = cellCenterX / geometry.size.width
                    let sourceTimeOffset = clipDuration * fractionThrough
                    let sourceTime = Double(reel.sourceStartFrame) / reel.sourceFrameRate.fps + sourceTimeOffset

                    thumbnailCell(at: sourceTime, strip: strip)
                        .frame(width: thumbnailWidth, height: geometry.size.height)
                }
            }
        }
    }

    @ViewBuilder
    private func thumbnailCell(at sourceTime: Double, strip: ThumbnailStrip?) -> some View {
        if let data = strip?.thumbnail(at: sourceTime),
           let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
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
        max(60, CGFloat(reel.durationFrames) * pixelsPerFrame)
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
    HStack(spacing: 4) {
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
            onSelect: {},
            onDoubleClick: {}
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
            onSelect: {},
            onDoubleClick: {}
        )
    }
    .padding()
    .background(Color(white: 0.15))
}
