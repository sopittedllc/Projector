import SwiftUI
import AVKit
import SwiftTimecodeCore

/// SwiftUI wrapper for AVPlayerView with fullscreen support
struct VideoPlayerView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.player = player
        playerView.controlsStyle = .none  // We provide our own controls
        playerView.showsFullScreenToggleButton = true
        playerView.allowsPictureInPicturePlayback = false
        playerView.videoGravity = .resizeAspect

        // Optimize for smooth resizing
        playerView.wantsLayer = true
        playerView.layerContentsRedrawPolicy = .onSetNeedsDisplay

        return playerView
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        // Only update player if it changed
        if nsView.player !== player {
            nsView.player = player
        }
    }
}

/// A view that displays video content with optional timecode overlay
struct VideoContentView: View {
    @ObservedObject var playbackEngine: PlaybackEngine
    let showTimecode: Bool
    var overlayPosition: TimecodeOverlayPosition = .bottomRight
    var overlayOpacity: Double = 0.8
    var extraTrailingPadding: CGFloat = 0

    var body: some View {
        ZStack {
            // Video layer
            if playbackEngine.hasContent {
                if playbackEngine.isInGap {
                    // Show black during gaps
                    Rectangle()
                        .fill(Color.black)
                } else if let player = playbackEngine.currentPlayer {
                    VideoPlayerView(player: player)
                        .background(Color.black)
                } else {
                    Rectangle()
                        .fill(Color.black)
                }
            } else {
                // Placeholder when no content is loaded
                Rectangle()
                    .fill(Color.black)
                    .overlay {
                        VStack(spacing: Spacing.lg) {
                            Image(systemName: "film")
                                .font(Typography.displayLarge)
                                .foregroundColor(AppColors.textTertiary)
                            Text("Drop video files here")
                                .font(Typography.displaySubtitle)
                                .foregroundColor(AppColors.textTertiary)
                            Text("to create a timeline")
                                .font(Typography.caption)
                                .foregroundColor(AppColors.textMuted)
                        }
                    }
            }

            // Timecode overlay
            if showTimecode && playbackEngine.hasContent {
                TimecodeOverlayView(
                    timecode: playbackEngine.currentTimecode,
                    position: overlayPosition,
                    opacity: overlayOpacity,
                    extraTrailingPadding: extraTrailingPadding
                )
            }
        }
    }
}

/// Timecode overlay displayed on top of video
struct TimecodeOverlayView: View {
    let timecode: Timecode
    var position: TimecodeOverlayPosition = .bottomRight
    var opacity: Double = 0.8
    var extraTrailingPadding: CGFloat = 0

    var body: some View {
        VStack {
            if position == .bottomLeft || position == .bottomRight {
                Spacer()
            }

            HStack {
                if position == .topRight || position == .bottomRight {
                    Spacer()
                }

                Text(timecode.stringValue())
                    .font(Typography.monoXLarge)
                    .foregroundColor(.white)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: PanelLayout.cornerRadius)
                            .fill(Color.black.opacity(0.6 * opacity))
                    )
                    .opacity(opacity)
                    .padding(.leading, Spacing.lg)
                    .padding(.trailing, Spacing.lg + extraTrailingPadding)
                    .padding(.vertical, Spacing.lg)

                if position == .topLeft || position == .bottomLeft {
                    Spacer()
                }
            }

            if position == .topLeft || position == .topRight {
                Spacer()
            }
        }
    }
}

// Backward compatibility alias
typealias VideoContentViewForEngine = VideoContentView

#Preview {
    VideoContentView(
        playbackEngine: PlaybackEngine(),
        showTimecode: true
    )
    .frame(width: 640, height: 360)
}
