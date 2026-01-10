import SwiftUI
import Foundation
import UniformTypeIdentifiers
import Iconoir
import AVFoundation

/// Video track container showing all video reels on the timeline
struct VideoTrackView: View {
    @ObservedObject var timelineManager: TimelineManager
    let playbackEngine: PlaybackEngine
    @ObservedObject var thumbnailCache: ThumbnailCache
    @ObservedObject var mediaLibrary: ProjectMediaLibrary
    let pixelsPerFrame: CGFloat
    let scrollOffset: CGFloat
    let showThumbnails: Bool
    let clipInteractionsEnabled: Bool
    let onDropMedia: ([URL], Int, Bool) -> Void
    let onReelSelected: (UUID?) -> Void
    let onReelDoubleClick: (VideoReel) -> Void
    let onReelMove: (UUID, Int) -> Void
    let linkedDragPreview: LinkedDragPreview?
    let onReelDragPreview: (VideoReel, Int?) -> Void

    @State private var selectedReelId: UUID?
    @State private var isDropTargeted = false
    @State private var dropPreviewFrame: Int?
    @State private var dropPreviewDurationFrames: Int?
    @State private var isLoadingDropPreview = false
    @State private var isDropAllowed = false
    @State private var latestDropLocation: CGPoint?
    @State private var draggingReelId: UUID?
    @State private var dragStartFrame: Int = 0
    @State private var dragOffsetFrames: Int = 0
    @EnvironmentObject private var dragContext: DragContext


    var body: some View {
        HStack(spacing: 0) {
            // Track header
            trackHeader

            // Reels area
            reelsArea
        }
        .frame(height: TimelineLayout.videoTrackHeight)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.3))
    }

    // MARK: - Track Header

    private var trackHeader: some View {
        Color.clear
            .frame(width: TimelineLayout.headerWidth, height: TimelineLayout.videoTrackHeight)
            .overlay(
                VStack(spacing: 2) {
                    Text("Video")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.primary)

                    // Show metadata for first reel if available
                    if let firstReel = timelineManager.timeline.videoReels.first {
                        videoMetadataView(for: firstReel)
                    } else {
                        Iconoir.videoCamera.asImage
                            .frame(width: 14, height: 14)
                            .foregroundColor(.secondary)

                        Text("No reels")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary.opacity(0.5))
                    }
                }
            )
    }

    @ViewBuilder
    private func videoMetadataView(for reel: VideoReel) -> some View {
        // Frame rate from reel
        Text(String(format: "%.2f fps", reel.sourceFrameRate.fps))
            .font(.system(size: 9, design: .monospaced))
            .foregroundColor(.secondary)

        // Bitrate from linked MediaItem
        if let mediaItemId = reel.mediaItemId,
           let item = mediaLibrary.items.first(where: { $0.id == mediaItemId }),
           let bitrate = item.formattedBitrate {
            Text(bitrate)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
        }

        // Reel count
        if timelineManager.timeline.videoReels.count > 1 {
            Text("\(timelineManager.timeline.videoReels.count) reels")
                .font(.system(size: 8))
                .foregroundColor(.secondary.opacity(0.7))
        }
    }

    // MARK: - Reels Area

    private var reelsArea: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background with drop zone
                dropZoneBackground

                // Reels
                reelsContent

                if (isDropAllowed || isLoadingDropPreview), let previewFrame = dropPreviewFrame {
                    dropPreviewOverlay(frame: previewFrame, height: geometry.size.height, width: geometry.size.width)
                }

            }
            .frame(maxWidth: .infinity, maxHeight: .infinity) // Ensure ZStack fills available space
            .onDrop(of: [UTType.fileURL, UTType.url, UTType.movie, UTType.video, UTType.mpeg4Movie, UTType.projectorMediaItem], delegate: VideoTrackDropDelegate(
                isTargeted: $isDropTargeted,
                pixelsPerFrame: pixelsPerFrame,
                scrollOffset: scrollOffset,
                durationFrames: timelineManager.timeline.config.durationFrames,
                isDropAllowed: { isDropAllowed },
                dropOperation: { (isDropAllowed || isLoadingDropPreview) ? .copy : .cancel },
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
        .offset(x: -TimelineLayout.headerWidth / 2)
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
                isOptimized: isReelOptimized(reel),
                onSelect: {
                    selectedReelId = reel.id
                    onReelSelected(reel.id)
                },
                onDoubleClick: {
                    onReelDoubleClick(reel)
                }
            )
            .offset(x: reelOffset(for: reel))
            .simultaneousGesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        guard clipInteractionsEnabled else { return }
                        if draggingReelId != reel.id {
                            draggingReelId = reel.id
                            dragStartFrame = reel.timelineStartFrame
                            dragOffsetFrames = 0
                            selectedReelId = reel.id
                            onReelSelected(reel.id)
                        }
                        let deltaFrames = Int(round(value.translation.width / max(pixelsPerFrame, 0.001)))
                        dragOffsetFrames = deltaFrames
                        let desired = dragStartFrame + dragOffsetFrames
                        let maxStart = max(0, timelineManager.timeline.config.durationFrames - reel.durationFrames)
                        let previewFrame = min(max(0, desired), maxStart)
                        onReelDragPreview(reel, previewFrame)
                    }
                    .onEnded { _ in
                        guard draggingReelId == reel.id else { return }
                        let unclamped = dragStartFrame + dragOffsetFrames
                        let maxStart = max(0, timelineManager.timeline.config.durationFrames - reel.durationFrames)
                        let newFrame = min(max(0, unclamped), maxStart)
                        draggingReelId = nil
                        dragOffsetFrames = 0
                        onReelMove(reel.id, newFrame)
                        onReelDragPreview(reel, nil)
                    }
            )
        }
    }

    private func reelOffset(for reel: VideoReel) -> CGFloat {
        let base = CGFloat(reel.timelineStartFrame) * pixelsPerFrame - scrollOffset
        if draggingReelId == reel.id {
            let desired = dragStartFrame + dragOffsetFrames
            let maxStart = max(0, timelineManager.timeline.config.durationFrames - reel.durationFrames)
            let clamped = min(max(0, desired), maxStart)
            return base + (CGFloat(clamped - reel.timelineStartFrame) * pixelsPerFrame)
        }

        if let preview = linkedDragPreview,
           isLinkedPreview(reel, preview: preview) {
            let delta = preview.toFrame - preview.fromFrame
            return base + (CGFloat(delta) * pixelsPerFrame)
        }

        return base
    }

    // MARK: - Drop Handling

    private func handleDrop(providers: [NSItemProvider], at location: CGPoint) -> Bool {
        var urls: [URL] = []

        let group = DispatchGroup()
        let targetFrame = dropFrame(for: location)
        let isInternalDrag = isInternalMediaDrag(providers)

        for provider in providers {
            group.enter()
            loadURL(from: provider) { url in
                defer { group.leave() }
                if let url = url {
                    urls.append(url)
                }
            }
        }

        group.notify(queue: .main) {
            let videoURLs = urls.filter { isVideoFile($0) }
            if !videoURLs.isEmpty {
                onDropMedia(videoURLs, targetFrame, isInternalDrag)
            }
            if isInternalDrag {
                dragContext.end()
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
        latestDropLocation = location
        dropPreviewFrame = dropFrame(for: location)
    }

    private func beginDropPreview(with providers: [NSItemProvider], at location: CGPoint) {
        updateDropPreview(location: location)
        if dropPreviewDurationFrames != nil || isLoadingDropPreview {
            return
        }
        isLoadingDropPreview = true
        isDropAllowed = false

        if let quickType = quickMediaType(from: providers) {
            guard quickType == .video else {
                isLoadingDropPreview = false
                clearDropPreview()
                return
            }
            isDropAllowed = true
        }

        loadFirstURL(from: providers) { url in
            guard let url = url else {
                isLoadingDropPreview = false
                return
            }
            guard isVideoFile(url) else {
                isLoadingDropPreview = false
                clearDropPreview()
                return
            }
            isDropAllowed = true
            updateDropPreview(location: latestDropLocation ?? location)
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
        isDropAllowed = false
    }

    private func loadFirstURL(from providers: [NSItemProvider], completion: @escaping (URL?) -> Void) {
        guard let provider = providers.first else {
            completion(nil)
            return
        }

        loadURL(from: provider, completion: completion)
    }

    private func isVideoFile(_ url: URL) -> Bool {
        ProjectMediaLibrary.mediaType(for: url) == .video
    }

    private func quickMediaType(from providers: [NSItemProvider]) -> MediaType? {
        for provider in providers {
            if let name = provider.suggestedName {
                let url = URL(fileURLWithPath: name)
                if let type = ProjectMediaLibrary.mediaType(for: url) {
                    return type
                }
            }
            for typeId in provider.registeredTypeIdentifiers {
                guard let utType = UTType(typeId) else { continue }
                if utType.conforms(to: .movie) { return .video }
                if utType.conforms(to: .audio) { return .audio }
            }
        }
        return nil
    }

    private func isLinkedPreview(_ reel: VideoReel, preview: LinkedDragPreview) -> Bool {
        reel.sourceURL == preview.sourceURL &&
        reel.sourceStartFrame == preview.sourceStartFrame &&
        reel.durationFrames == preview.durationFrames &&
        reel.timelineStartFrame == preview.fromFrame
    }

    /// Check if the media item for this reel is optimized
    private func isReelOptimized(_ reel: VideoReel) -> Bool {
        // First try to find by mediaItemId (most reliable)
        if let mediaItemId = reel.mediaItemId,
           let item = mediaLibrary.items.first(where: { $0.id == mediaItemId }) {
            return item.isOptimized
        }
        // Fall back to URL matching
        let item = mediaLibrary.items.first { $0.url == reel.sourceURL }
        return item?.isOptimized ?? false
    }

    private func loadURL(from provider: NSItemProvider, completion: @escaping (URL?) -> Void) {
        var didFinish = false
        func finish(_ url: URL?) {
            guard !didFinish else { return }
            didFinish = true
            completion(url)
        }

        // Try loading as NSURL first (works for most Finder drops)
        provider.loadObject(ofClass: NSURL.self) { object, _ in
            if let url = object as? NSURL {
                finish(url as URL)
                return
            }
            // Try file URL identifier
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let url = extractURL(from: item) {
                    finish(url)
                    return
                }
                // Try movie type (for video files dragged from Finder)
                provider.loadItem(forTypeIdentifier: UTType.movie.identifier, options: nil) { item, _ in
                    if let url = extractURL(from: item) {
                        finish(url)
                        return
                    }
                    // Try MPEG-4 movie type specifically
                    provider.loadItem(forTypeIdentifier: UTType.mpeg4Movie.identifier, options: nil) { item, _ in
                        if let url = extractURL(from: item) {
                            finish(url)
                            return
                        }
                        // Try generic URL
                        provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                            if let url = extractURL(from: item) {
                                finish(url)
                                return
                            }
                            // Finally try our custom projector media item
                            provider.loadDataRepresentation(forTypeIdentifier: UTType.projectorMediaItem.identifier) { data, _ in
                                finish(extractProjectorMediaURL(from: data))
                            }
                        }
                    }
                }
            }
        }
    }

    private func extractURL(from item: Any?) -> URL? {
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        if let url = item as? URL {
            return url
        }
        if let url = item as? NSURL {
            return url as URL
        }
        if let string = item as? String {
            return URL(string: string)
        }
        return nil
    }

    private func extractProjectorMediaURL(from item: Any?) -> URL? {
        guard let data = item as? Data else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let urlString = object["url"] as? String {
            if let url = URL(string: urlString) {
                return url
            }
            if urlString.hasPrefix("/") {
                return URL(fileURLWithPath: urlString)
            }
        }
        if let string = String(data: data, encoding: .utf8) {
            if let url = URL(string: string), url.scheme != nil {
                return url
            }
            if string.hasPrefix("/") {
                return URL(fileURLWithPath: string)
            }
        }
        return nil
    }
}

private struct VideoTrackDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    let pixelsPerFrame: CGFloat
    let scrollOffset: CGFloat
    let durationFrames: Int
    let isDropAllowed: () -> Bool
    let dropOperation: () -> DropOperation
    let dropHandler: ([NSItemProvider], CGPoint) -> Bool
    let updateHandler: (CGPoint) -> Void
    let enterHandler: ([NSItemProvider], CGPoint) -> Void
    let exitHandler: () -> Void
    private let supportedTypes: [UTType] = [.fileURL, .url, .movie, .video, .mpeg4Movie, .projectorMediaItem]

    func validateDrop(info: DropInfo) -> Bool {
        !info.itemProviders(for: supportedTypes).isEmpty
    }

    func dropEntered(info: DropInfo) {
        isTargeted = true
        let providers = info.itemProviders(for: supportedTypes)
        enterHandler(providers, info.location)
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
        exitHandler()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateHandler(info.location)
        return DropProposal(operation: dropOperation())
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        exitHandler()
        let providers = info.itemProviders(for: supportedTypes)
        return dropHandler(providers, info.location)
    }
}

#Preview {
    struct PreviewWrapper: View {
        @StateObject var timelineManager = TimelineManager()
        @StateObject var playbackEngine = PlaybackEngine()
        @StateObject var thumbnailCache = ThumbnailCache()
        @StateObject var mediaLibrary = ProjectMediaLibrary()

        var body: some View {
            VideoTrackView(
                timelineManager: timelineManager,
                playbackEngine: playbackEngine,
                thumbnailCache: thumbnailCache,
                mediaLibrary: mediaLibrary,
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
                },
                onReelMove: { _, _ in },
                linkedDragPreview: nil,
                onReelDragPreview: { _, _ in }
            )
            .frame(width: 800)
            .background(Color(white: 0.15))
        }
    }

    return PreviewWrapper()
}
