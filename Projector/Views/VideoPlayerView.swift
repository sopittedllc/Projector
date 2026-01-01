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
    @ObservedObject var playerManager: VideoPlayerManager
    let showTimecode: Bool
    var overlayPosition: TimecodeOverlayPosition = .bottomRight
    var overlayOpacity: Double = 0.8

    var body: some View {
        ZStack {
            // Video layer
            if playerManager.hasVideo {
                VideoPlayerView(player: playerManager.player)
                    .background(Color.black)
            } else {
                // Placeholder when no video is loaded
                Rectangle()
                    .fill(Color.black)
                    .overlay {
                        VStack(spacing: 16) {
                            Image(systemName: "film")
                                .font(.system(size: 64))
                                .foregroundColor(.gray)
                            Text("Drop a video file here")
                                .font(.title2)
                                .foregroundColor(.gray)
                            Text("or use File → Open")
                                .font(.caption)
                                .foregroundColor(.gray.opacity(0.7))
                        }
                    }
            }

            // Timecode overlay
            if showTimecode && playerManager.hasVideo {
                TimecodeOverlayView(
                    timecode: playerManager.currentTimecode,
                    position: overlayPosition,
                    opacity: overlayOpacity
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
                    .font(.system(size: 24, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.black.opacity(0.6 * opacity))
                    )
                    .opacity(opacity)
                    .padding(16)

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

#Preview {
    VideoContentView(
        playerManager: VideoPlayerManager(),
        showTimecode: true
    )
    .frame(width: 640, height: 360)
}
