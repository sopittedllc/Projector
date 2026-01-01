import SwiftUI

/// Interactive scrubber bar for timeline seeking
struct ScrubberView: View {
    @ObservedObject var playerManager: VideoPlayerManager
    @Binding var isDragging: Bool

    @State private var dragPosition: Double = 0

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background track
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.2))

                // Progress fill
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor)
                    .frame(width: progressWidth(in: geometry))

                // Playhead handle
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                    .frame(width: 14, height: 14)
                    .offset(x: playheadOffset(in: geometry))
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(in: geometry))
            .gesture(tapGesture(in: geometry))
        }
        .frame(height: 8)
    }

    // MARK: - Calculations

    private func progressWidth(in geometry: GeometryProxy) -> CGFloat {
        guard playerManager.duration > 0 else { return 0 }

        let progress = isDragging ? dragPosition : playerManager.currentTime
        let ratio = progress / playerManager.duration
        return max(0, min(geometry.size.width, geometry.size.width * CGFloat(ratio)))
    }

    private func playheadOffset(in geometry: GeometryProxy) -> CGFloat {
        guard playerManager.duration > 0 else { return -7 }

        let progress = isDragging ? dragPosition : playerManager.currentTime
        let ratio = progress / playerManager.duration
        let offset = (geometry.size.width - 14) * CGFloat(ratio)
        return max(-7, min(geometry.size.width - 7, offset))
    }

    // MARK: - Gestures

    private func dragGesture(in geometry: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                isDragging = true
                let ratio = max(0, min(1, value.location.x / geometry.size.width))
                dragPosition = Double(ratio) * playerManager.duration
                // Real-time scrubbing: seek while dragging for instant preview
                playerManager.seek(toSeconds: dragPosition)
            }
            .onEnded { value in
                let ratio = max(0, min(1, value.location.x / geometry.size.width))
                let seekTime = Double(ratio) * playerManager.duration
                playerManager.seek(toSeconds: seekTime)
                isDragging = false
            }
    }

    private func tapGesture(in geometry: GeometryProxy) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                let ratio = max(0, min(1, value.location.x / geometry.size.width))
                let seekTime = Double(ratio) * playerManager.duration
                playerManager.seek(toSeconds: seekTime)
            }
    }
}

#Preview {
    ScrubberView(
        playerManager: VideoPlayerManager(),
        isDragging: .constant(false)
    )
    .padding()
}
