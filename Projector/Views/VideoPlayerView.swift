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
    var overlayPosition: TimecodeOverlayPosition = .bottomCenter
    var overlayOpacity: Double = 0.8

    /// Offers to install the missing codec, when the host view can present it.
    ///
    /// Optional so the floating player window can show the explanation without adding
    /// a second place to start the install - the import alert is the primary one.
    var onInstallCodec: (() -> Void)?

    var body: some View {
        ZStack {
            // Video layer
            if playbackEngine.hasContent {
                if playbackEngine.isInGap {
                    // Show black during gaps
                    Rectangle()
                        .fill(Color.black)
                } else if let codecName = playbackEngine.unplayableCodecName {
                    // A reel whose codec has no decoder. Without this the picture is
                    // simply black, which reads as a broken app rather than a missing
                    // system component.
                    missingCodecPlaceholder(codecName: codecName)
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
                                .font(Typography.iconEmptyState)
                                .foregroundColor(AppColors.textTertiary)
                            Text("Drop video files here")
                                .font(Typography.displaySubtitle)
                                .foregroundColor(AppColors.textTertiary)
                            Text("to create a timeline")
                                .font(Typography.caption)
                                .foregroundColor(AppColors.textMuted)
                        }
                        // Centre in the space the timecode is not using, on
                        // whichever edge it occupies. The placeholder centres on
                        // the whole area otherwise, which in the 270pt inline
                        // column puts its hint text right where the overlay sits.
                        .padding(.top, showTimecode && overlayPosition.isTop ? TimecodeOverlayView.reservedHeight : 0)
                        .padding(.bottom, showTimecode && !overlayPosition.isTop ? TimecodeOverlayView.reservedHeight : 0)
                    }
            }

            // Timecode overlay.
            //
            // Not gated on media: the playhead follows incoming MTC with an
            // empty timeline, and that is exactly when a large readout is worth
            // having - there is no picture to read position from.
            if showTimecode {
                TimecodeOverlayView(
                    timecode: playbackEngine.currentTimecode,
                    position: overlayPosition,
                    opacity: overlayOpacity
                )
            }
        }
    }

    /// Explains that this Mac has no decoder for the current reel's codec.
    ///
    /// - Parameter codecName: The codec's own name, e.g. "Avid DNxHD".
    /// - Returns: A placeholder filling the video area.
    @ViewBuilder
    private func missingCodecPlaceholder(codecName: String) -> some View {
        Rectangle()
            .fill(Color.black)
            .overlay {
                VStack(spacing: Spacing.md) {
                    Image(systemName: "film.stack")
                        .font(Typography.iconEmptyState)
                        .foregroundColor(AppColors.textTertiary)
                    Text("Cannot decode \(codecName)")
                        .font(Typography.displaySubtitle)
                        .foregroundColor(AppColors.textTertiary)
                    Text("Timecode and duration are still correct")
                        .font(Typography.caption)
                        .foregroundColor(AppColors.textMuted)
                    if let onInstallCodec {
                        Button("Install Codec Support…", action: onInstallCodec)
                            .padding(.top, Spacing.xs)
                    }
                }
                .padding(.top, showTimecode && overlayPosition.isTop ? TimecodeOverlayView.reservedHeight : 0)
                .padding(.bottom, showTimecode && !overlayPosition.isTop ? TimecodeOverlayView.reservedHeight : 0)
            }
    }
}

/// Timecode overlay displayed on top of video.
///
/// Placement is the user's choice, and every cell sits the same short distance
/// from its edges. Three of the six share space with something else - the hover
/// controls bottom right, the frame-rate chip bottom left, the player window's
/// titlebar along the top - but this draws underneath all of them, so they
/// occlude it rather than displace it.
struct TimecodeOverlayView: View {
    let timecode: Timecode
    var position: TimecodeOverlayPosition = .bottomCenter
    var opacity: Double = 0.3

    /// Fixed size. This was briefly user-selectable across four scales; 14pt
    /// read best at every window size and every position, so the choice was
    /// removed rather than left as three ways to make it worse.
    private static let font = Font.system(size: 14, weight: .medium, design: .monospaced)

    /// Vertical space this claims on whichever edge it occupies, for anything
    /// that has to stay clear of it.
    static let reservedHeight: CGFloat = 44

    var body: some View {
        ZStack(alignment: position.alignment) {
            Color.clear

            Text(timecode.stringValue())
                .font(Self.font)
                .foregroundColor(.white)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: PanelLayout.cornerRadius)
                        .fill(Color.black.opacity(0.6))
                )
                .opacity(opacity)
                // The same tight inset on every edge. Nothing is dodged: the
                // overlay renders beneath the hover controls, so where the two
                // share a corner the controls simply draw over it.
                .padding(Spacing.md)
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
