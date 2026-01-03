import SwiftUI
import UniformTypeIdentifiers
import Iconoir
import AVFoundation

/// Video track container showing all video reels on the timeline
struct VideoTrackView: View {
    @ObservedObject var timelineManager: TimelineManager
    let playbackEngine: PlaybackEngine
    @ObservedObject var thumbnailCache: ThumbnailCache
    let pixelsPerFrame: CGFloat
    let scrollOffset: CGFloat
    let showThumbnails: Bool
    let clipInteractionsEnabled: Bool
    let onDropMedia: ([URL], Int, Bool) -> Void
    let onReelSelected: (UUID?) -> Void
    let onReelDoubleClick: (VideoReel) -> Void

    @State private var selectedReelId: UUID?
    @State private var isDropTargeted = false
    @State private var dropPreviewFrame: Int?
    @State private var dropPreviewDurationFrames: Int?
    @State private var isLoadingDropPreview = false

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
                reelsContent

                if let previewFrame = dropPreviewFrame {
                    dropPreviewOverlay(frame: previewFrame, height: geometry.size.height, width: geometry.size.width)
                }

                // Drop target overlay
                if isDropTargeted {
                    dropTargetOverlay
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity) // Ensure ZStack fills available space
            .onDrop(of: [UTType.fileURL], delegate: VideoTrackDropDelegate(
                isTargeted: $isDropTargeted,
                pixelsPerFrame: pixelsPerFrame,
                scrollOffset: scrollOffset,
                durationFrames: timelineManager.timeline.config.durationFrames,
                dropHandler: { providers, location in
                    handleDrop(providers: providers, at: location)
                },
                updateHandler: { location in
                    updateDropPreview(location: location)
                },
                enterHandler: { providers, location in
                    beginDropPreview(with: providers, at: location)
                },
                exitHandler: {
                    clearDropPreview()
                }
            ))
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

    private func dropPreviewOverlay(frame: Int, height: CGFloat, width: CGFloat) -> some View {
        let durationFrames = dropPreviewDurationFrames ?? Int(timelineManager.timeline.config.frameRate.fps)
        let rawWidth = CGFloat(durationFrames) * pixelsPerFrame
        let clampedWidth = min(max(12, rawWidth), width)
        let xOffset = CGFloat(frame) * pixelsPerFrame - scrollOffset

        return RoundedRectangle(cornerRadius: 4)
            .stroke(Color.orange, lineWidth: 2)
            .background(Color.orange.opacity(0.1))
            .frame(width: clampedWidth, height: max(6, height - 6))
            .offset(x: xOffset)
            .padding(.vertical, 3)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var reelsContent: some View {
        let sortedReels = timelineManager.timeline.sortedVideoReels

        ForEach(sortedReels) { reel in
            VideoReelClipView(
                reel: reel,
                isActive: playbackEngine.activeReel?.id == reel.id,
                pixelsPerFrame: pixelsPerFrame,
                thumbnailCache: thumbnailCache,
                showThumbnails: showThumbnails,
                isSelected: selectedReelId == reel.id,
                interactionsEnabled: clipInteractionsEnabled,
                onSelect: {
                    selectedReelId = reel.id
                    onReelSelected(reel.id)
                },
                onDoubleClick: {
                    onReelDoubleClick(reel)
                }
            )
            .offset(x: CGFloat(reel.timelineStartFrame) * pixelsPerFrame - scrollOffset)
        }
    }

    // MARK: - Drop Handling

    private func handleDrop(providers: [NSItemProvider], at location: CGPoint) -> Bool {
        var urls: [URL] = []

        let group = DispatchGroup()
        let targetFrame = dropFrame(for: location)
        let isInternalDrag = isInternalMediaDrag(providers)

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
                onDropMedia(videoURLs, targetFrame, isInternalDrag)
            }
        }
        clearDropPreview()

        return true
    }

    private func isInternalMediaDrag(_ providers: [NSItemProvider]) -> Bool {
        providers.contains { provider in
            provider.hasItemConformingToTypeIdentifier(UTType.projectorMediaItem.identifier)
        }
    }

    private func dropFrame(for location: CGPoint) -> Int {
        let x = max(0, location.x + scrollOffset)
        let rawFrame = Int(x / max(pixelsPerFrame, 0.001))
        let maxFrame = max(0, timelineManager.timeline.config.durationFrames - 1)
        return max(0, min(rawFrame, maxFrame))
    }

    private func updateDropPreview(location: CGPoint) {
        dropPreviewFrame = dropFrame(for: location)
    }

    private func beginDropPreview(with providers: [NSItemProvider], at location: CGPoint) {
        updateDropPreview(location: location)
        if dropPreviewDurationFrames != nil || isLoadingDropPreview {
            return
        }
        isLoadingDropPreview = true

        loadFirstURL(from: providers) { url in
            guard let url = url else {
                isLoadingDropPreview = false
                return
            }
            Task {
                let asset = AVAsset(url: url)
                do {
                    let duration = try await asset.load(.duration)
                    let frames = max(1, Int(duration.seconds * timelineManager.timeline.config.frameRate.fps))
                    dropPreviewDurationFrames = frames
                } catch {
                    dropPreviewDurationFrames = nil
                }
                isLoadingDropPreview = false
            }
        }
    }

    private func clearDropPreview() {
        dropPreviewFrame = nil
        dropPreviewDurationFrames = nil
        isLoadingDropPreview = false
    }

    private func loadFirstURL(from providers: [NSItemProvider], completion: @escaping (URL?) -> Void) {
        guard let provider = providers.first else {
            completion(nil)
            return
        }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            if let data = item as? Data,
               let url = URL(dataRepresentation: data, relativeTo: nil) {
                completion(url)
            } else if let url = item as? URL {
                completion(url)
            } else {
                completion(nil)
            }
        }
    }

    private func isVideoFile(_ url: URL) -> Bool {
        let videoExtensions = ["mov", "mp4", "m4v", "avi", "mkv", "mxf", "prores"]
        return videoExtensions.contains(url.pathExtension.lowercased())
    }
}

private struct VideoTrackDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    let pixelsPerFrame: CGFloat
    let scrollOffset: CGFloat
    let durationFrames: Int
    let dropHandler: ([NSItemProvider], CGPoint) -> Bool
    let updateHandler: (CGPoint) -> Void
    let enterHandler: ([NSItemProvider], CGPoint) -> Void
    let exitHandler: () -> Void

    func validateDrop(info: DropInfo) -> Bool {
        !info.itemProviders(for: [UTType.fileURL]).isEmpty
    }

    func dropEntered(info: DropInfo) {
        isTargeted = true
        let providers = info.itemProviders(for: [UTType.fileURL])
        enterHandler(providers, info.location)
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
        exitHandler()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateHandler(info.location)
        return DropProposal(operation: .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        exitHandler()
        let providers = info.itemProviders(for: [UTType.fileURL])
        return dropHandler(providers, info.location)
    }
}

#Preview {
    struct PreviewWrapper: View {
        @StateObject var timelineManager = TimelineManager()
        @StateObject var playbackEngine = PlaybackEngine()
        @StateObject var thumbnailCache = ThumbnailCache()

        var body: some View {
            VideoTrackView(
                timelineManager: timelineManager,
                playbackEngine: playbackEngine,
                thumbnailCache: thumbnailCache,
                pixelsPerFrame: 0.5,
                scrollOffset: 0,
                showThumbnails: true,
                clipInteractionsEnabled: true,
                onDropMedia: { urls, _, _ in
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
