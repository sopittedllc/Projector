import SwiftUI
import UniformTypeIdentifiers
import Iconoir

/// Video track container showing all video reels on the timeline
struct VideoTrackView: View {
    @ObservedObject var timelineManager: TimelineManager
    let playbackEngine: PlaybackEngine
    let thumbnails: [UUID: ThumbnailStrip]
    let pixelsPerFrame: CGFloat
    let scrollOffset: CGFloat
    let onDropMedia: ([URL]) -> Void
    let onReelSelected: (UUID?) -> Void
    let onReelDoubleClick: (VideoReel) -> Void

    @State private var selectedReelId: UUID?
    @State private var isDropTargeted = false

    /// Track header width - must match MultiTrackTimelineView
    private let headerWidth: CGFloat = 120
    /// Track height for video reels
    private let trackHeight: CGFloat = 60

    var body: some View {
        HStack(spacing: 0) {
            // Track header
            trackHeader

            // Reels area
            reelsArea
        }
        .frame(height: trackHeight)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.3))
    }

    // MARK: - Track Header

    private var trackHeader: some View {
        Color.clear
            .frame(width: headerWidth, height: trackHeight)
            .overlay(
                VStack(spacing: 3) {
                    Text("Video")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.primary)

                    Iconoir.videoCamera.asImage
                        .frame(width: 14, height: 14)
                        .foregroundColor(.secondary)

                    Text(timelineManager.timeline.videoReels.isEmpty ? "No reels" : "\(timelineManager.timeline.videoReels.count) reel\(timelineManager.timeline.videoReels.count == 1 ? "" : "s")")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary.opacity(timelineManager.timeline.videoReels.isEmpty ? 0.5 : 1.0))
                }
            )
    }

    // MARK: - Reels Area

    private var reelsArea: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background with drop zone
                dropZoneBackground

                // Reels
                reelsContent(in: geometry)

                // Drop target overlay
                if isDropTargeted {
                    dropTargetOverlay
                }
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    private var dropZoneBackground: some View {
        DustyBackground()
            .overlay(
                Group {
                    if timelineManager.timeline.videoReels.isEmpty {
                        emptyDropPrompt
                    }
                }
            )
    }

    private var emptyDropPrompt: some View {
        VStack(spacing: 4) {
            Iconoir.mediaVideo.asImage
                .frame(width: 20, height: 20)
                .foregroundColor(.secondary.opacity(0.6))

            Text("Drop video files here")
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.6))
        }
    }

    private var dropTargetOverlay: some View {
        RoundedRectangle(cornerRadius: 4)
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
            .background(Color.accentColor.opacity(0.1))
            .padding(4)
    }

    @ViewBuilder
    private func reelsContent(in geometry: GeometryProxy) -> some View {
        let sortedReels = timelineManager.timeline.sortedVideoReels

        ForEach(sortedReels) { reel in
            let xOffset = CGFloat(reel.timelineStartFrame) * pixelsPerFrame - scrollOffset

            VideoReelClipView(
                reel: reel,
                isActive: playbackEngine.activeReel?.id == reel.id,
                pixelsPerFrame: pixelsPerFrame,
                thumbnailStrip: thumbnails[reel.id],
                isSelected: selectedReelId == reel.id,
                onSelect: {
                    selectedReelId = reel.id
                    onReelSelected(reel.id)
                },
                onDoubleClick: {
                    onReelDoubleClick(reel)
                }
            )
            .offset(x: xOffset)
        }
    }

    // MARK: - Drop Handling

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var urls: [URL] = []

        let group = DispatchGroup()

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                defer { group.leave() }

                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    urls.append(url)
                } else if let url = item as? URL {
                    urls.append(url)
                }
            }
        }

        group.notify(queue: .main) {
            let videoURLs = urls.filter { isVideoFile($0) }
            if !videoURLs.isEmpty {
                onDropMedia(videoURLs)
            }
        }

        return true
    }

    private func isVideoFile(_ url: URL) -> Bool {
        let videoExtensions = ["mov", "mp4", "m4v", "avi", "mkv", "mxf", "prores"]
        return videoExtensions.contains(url.pathExtension.lowercased())
    }
}

#Preview {
    struct PreviewWrapper: View {
        @StateObject var timelineManager = TimelineManager()
        @StateObject var playbackEngine = PlaybackEngine()

        var body: some View {
            VideoTrackView(
                timelineManager: timelineManager,
                playbackEngine: playbackEngine,
                thumbnails: [:],
                pixelsPerFrame: 0.5,
                scrollOffset: 0,
                onDropMedia: { urls in
                    print("Dropped: \(urls)")
                },
                onReelSelected: { id in
                    print("Selected: \(String(describing: id))")
                },
                onReelDoubleClick: { reel in
                    print("Double-clicked: \(reel.displayName)")
                }
            )
            .frame(width: 800)
            .background(Color(white: 0.15))
        }
    }

    return PreviewWrapper()
}
