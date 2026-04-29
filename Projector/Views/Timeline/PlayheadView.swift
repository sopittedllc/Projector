import SwiftUI

/// Vertical playhead line that spans all timeline tracks
struct PlayheadView: View {
    let currentFrame: Int
    let pixelsPerFrame: CGFloat
    let scrollOffset: CGFloat
    let totalHeight: CGFloat

    /// Header width - must match other timeline views
    private let headerWidth: CGFloat = TimelineLayout.playheadHeaderWidth

    /// Triangle dimensions
    private let triangleWidth: CGFloat = TimelineLayout.playheadTriangleWidth
    private let triangleHeight: CGFloat = TimelineLayout.playheadTriangleHeight

    var body: some View {
        let xPosition = CGFloat(currentFrame) * pixelsPerFrame - scrollOffset + headerWidth

        Canvas { context, size in
            // Draw triangle at top, centered on x=triangleWidth/2
            let trianglePath = Path { path in
                path.move(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: triangleWidth, y: 0))
                path.addLine(to: CGPoint(x: triangleWidth / 2, y: triangleHeight))
                path.closeSubpath()
            }
            context.fill(trianglePath, with: .color(AppColors.accent))

            // Draw vertical line from bottom of triangle to bottom of view
            let linePath = Path { path in
                path.move(to: CGPoint(x: triangleWidth / 2, y: triangleHeight))
                path.addLine(to: CGPoint(x: triangleWidth / 2, y: size.height))
            }
            context.stroke(linePath, with: .color(AppColors.accent), lineWidth: 1)
        }
        .frame(width: triangleWidth, height: totalHeight)
        .offset(x: xPosition - triangleWidth / 2)
    }
}

/// Overlay that contains the playhead and click-to-seek functionality
struct PlayheadOverlayView: View {
    let currentFrame: Int
    let durationFrames: Int
    let pixelsPerFrame: CGFloat
    let scrollOffset: CGFloat
    let totalHeight: CGFloat
    let onSeek: (Int) -> Void

    @State private var isDragging = false

    /// Header width - must match other timeline views
    private let headerWidth: CGFloat = TimelineLayout.playheadHeaderWidth

    var body: some View {
        ZStack(alignment: .leading) {
            // Invisible hit area for click-to-seek (only in content area)
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isDragging = true
                            seekToLocation(value.location.x)
                        }
                        .onEnded { _ in
                            isDragging = false
                        }
                )
                .padding(.leading, headerWidth)
                .padding(.trailing, headerWidth)

            // Playhead
            PlayheadView(
                currentFrame: currentFrame,
                pixelsPerFrame: pixelsPerFrame,
                scrollOffset: scrollOffset,
                totalHeight: totalHeight
            )
        }
    }

    private func seekToLocation(_ x: CGFloat) {
        // Account for header offset
        let contentX = x - headerWidth + scrollOffset
        let frame = Int(contentX / pixelsPerFrame)
        let clampedFrame = max(0, min(frame, durationFrames - 1))
        onSeek(clampedFrame)
    }
}

#Preview {
    VStack {
        ZStack(alignment: .leading) {
            // Background tracks
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .frame(height: 60)

                Divider()

                Rectangle()
                    .fill(Color.gray.opacity(0.15))
                    .frame(height: 50)

                Divider()

                Rectangle()
                    .fill(Color.gray.opacity(0.15))
                    .frame(height: 50)
            }

            // Playhead overlay
            PlayheadOverlayView(
                currentFrame: 1200,
                durationFrames: 5000,
                pixelsPerFrame: 0.5,
                scrollOffset: 0,
                totalHeight: 162,
                onSeek: { frame in
                    print("Seek to frame: \(frame)")
                }
            )
        }
        .frame(width: 800, height: 162)
    }
    .background(Color(white: 0.15))
}
