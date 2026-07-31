import SwiftUI
import Foundation
import UniformTypeIdentifiers
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
    /// Called when a drop contains BOTH video and audio files.
    ///
    /// - Parameters:
    ///   - videoURLs: Array of video file URLs from the drop
    ///   - audioURLs: Array of audio file URLs from the drop
    ///   - targetFrame: Timeline frame position where the drop occurred
    var onDropMixedMedia: (([URL], [URL], Int) -> Void)?
    /// Called when the track header is renamed. Only offered when exactly one
    /// reel is present - with several, the header describes the track, not a
    /// single file, so there's nothing unambiguous to rename.
    var onReelRename: ((UUID, String) -> Void)?
    let onReelSelected: (UUID?, SelectionModifiers) -> Void
    let onReelDoubleClick: (VideoReel) -> Void
    let onReelMove: (UUID, Int) -> Void
    let linkedDragPreview: LinkedDragPreview?
    let onReelDragPreview: (VideoReel, Int?) -> Void
    /// Set of reel IDs selected via marquee selection (from parent)
    var selectedReelIds: Set<UUID> = []
    /// Whether to show the track header (set false when using external unified header)
    var showsHeader: Bool = true

    @State private var selectedReelId: UUID?
    @State private var isEditingName = false
    @State private var editedName = ""
    @FocusState private var isNameFieldFocused: Bool
    @State private var dropPreviewFrame: Int?
    @State private var dropPreviewDurationFrames: Int?
    @State private var isLoadingDropPreview = false
    @State private var isDropAllowed = false
    @State private var latestDropLocation: CGPoint?
    @State private var draggingReelId: UUID?
    @State private var dragStartFrame: Int = 0
    @State private var dragOffsetFrames: Int = 0
    @EnvironmentObject private var dragContext: DragContext

    /// Output routing choices, for the baked-in audio's controls.
    var availableAudioOutputs: [MappedAudioOutput] = []

    /// Whether we're in a multi-file drag from the media panel
    private var isMultiFileDrag: Bool {
        dragContext.mediaItems.count > 1
    }

    /// Check if providers represent a multi-file external drag
    private func isMultiFileExternalDrag(_ providers: [NSItemProvider]) -> Bool {
        dragContext.mediaItems.isEmpty && providers.count > 1
    }


    var body: some View {
        HStack(spacing: 0) {
            // Track header (only show if not using external unified header)
            if showsHeader {
                trackHeader
            }

            // Reels area
            reelsArea
        }
        .frame(height: TimelineLayout.videoTrackHeight)
        .background(showsHeader ? Color(nsColor: .textBackgroundColor).opacity(0.3) : Color.clear)
    }

    // MARK: - Track Header

    private var trackHeader: some View {
        HStack(spacing: 0) {
            // Left padding to align with panel header
            Spacer()
                .frame(width: Spacing.md)

            VStack(spacing: Spacing.xs) {
                trackTitle

                // Show metadata for first reel if available
                if let firstReel = timelineManager.timeline.videoReels.first {
                    videoMetadataView(for: firstReel)

                    // The baked-in audio has no header of its own - it is drawn
                    // as a strip beneath this row - so its controls live here.
                    if let linked = timelineManager.timeline.videoAudioLane,
                       let index = timelineManager.timeline.audioLanes.firstIndex(where: { $0.id == linked.id }) {
                        AudioLaneControls(
                            lane: linked,
                            availableAudioOutputs: availableAudioOutputs,
                            onMuteToggle: { timelineManager.toggleLaneMute(at: index) },
                            onSoloToggle: { timelineManager.toggleLaneSolo(at: index) },
                            onOutputMappingChange: { output in
                                timelineManager.setLaneOutputMapping(id: linked.id, mapping: output)
                            },
                            onOutputNone: { timelineManager.disableLaneOutput(id: linked.id) }
                        )
                    }
                } else {
                    Image(systemName: "video")
                        .frame(width: 14, height: 14)
                        .foregroundColor(.secondary)

                    Text("No reels")
                        .font(Typography.captionSmall)
                        .foregroundColor(.secondary.opacity(0.5))
                }
            }
            .frame(maxWidth: .infinity)

            Spacer()
                .frame(width: Spacing.sm)
        }
        .frame(width: TimelineLayout.headerWidth)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
    }

    /// Track title: the reel's name when there's exactly one, otherwise the
    /// generic "Video" label.
    ///
    /// Mirrors the audio lanes - a track named after its media is far easier to
    /// scan than a row of identical generic labels. Renaming is offered only in
    /// the single-reel case; with several reels the header summarises the whole
    /// track and there is no single file the name would belong to.
    @ViewBuilder
    private var trackTitle: some View {
        let reels = timelineManager.timeline.videoReels
        let soleReel = reels.count == 1 ? reels.first : nil

        if isEditingName, let reel = soleReel {
            // Same semantics as lane rename: Return commits, Escape reverts,
            // clicking away commits, existing text selected on entry.
            TextField("", text: $editedName)
                .font(.system(size: 10, weight: .medium))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .focused($isNameFieldFocused)
                .onSubmit { commitNameEdit(for: reel) }
                .onExitCommand { cancelNameEdit(for: reel) }
                .onChange(of: isNameFieldFocused) { _, focused in
                    if focused {
                        selectAllInFieldEditor()
                    } else if isEditingName {
                        commitNameEdit(for: reel)
                    }
                }
                .frame(maxWidth: TimelineLayout.headerWidth - Spacing.md - Spacing.sm - 12)
                .help("Return to rename, Escape to cancel")
        } else if let reel = soleReel {
            Button(action: {}) {
                Text(reel.displayName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .simultaneousGesture(
                TapGesture(count: 2).onEnded { _ in startNameEdit(for: reel) }
            )
            .help("\(reel.displayName) - double-click to rename")
            .accessibilityLabel("Video track: \(reel.displayName)")
        } else {
            Text("Video")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.primary)
        }
    }

    private func startNameEdit(for reel: VideoReel) {
        editedName = reel.displayName
        isEditingName = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            isNameFieldFocused = true
        }
    }

    /// Commit the rename. Clearing the field restores the filename rather than
    /// leaving the track blank (renameVideoReel treats empty as "no override").
    private func commitNameEdit(for reel: VideoReel) {
        guard isEditingName else { return }   // guards submit + blur double-commit
        isEditingName = false
        isNameFieldFocused = false

        let trimmed = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != reel.displayName else { return }
        onReelRename?(reel.id, trimmed)
    }

    private func cancelNameEdit(for reel: VideoReel) {
        isEditingName = false
        isNameFieldFocused = false
        editedName = reel.displayName
    }

    /// Select the whole name on entry so typing replaces it. SwiftUI exposes no
    /// API for this on macOS; the field editor is an NSTextView on the window.
    private func selectAllInFieldEditor() {
        DispatchQueue.main.async {
            guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
            editor.selectAll(nil)
        }
    }

    @ViewBuilder
    private func videoMetadataView(for reel: VideoReel) -> some View {
        // Frame rate from reel
        Text(String(format: "%.2f fps", reel.sourceFrameRate.fps))
            .font(.system(size: 9, design: .monospaced))
            .foregroundColor(.secondary)

        // Bitrate intentionally omitted - fps is the actionable figure here.

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

                // Reels - vertically centered with subtle padding
                reelsContent
                    .offset(y: (TimelineLayout.videoTrackHeight - TimelineLayout.videoClipHeight) / 2)

                // Show preview for all drops (single and multi-file)
                if (isDropAllowed || isLoadingDropPreview), let previewFrame = dropPreviewFrame {
                    dropPreviewOverlay(frame: previewFrame, height: geometry.size.height, width: geometry.size.width)
                }

            }
            .frame(maxWidth: .infinity, maxHeight: .infinity) // Ensure ZStack fills available space
            .contentShape(Rectangle())
            // AppKit drag capture, NOT SwiftUI's .onDrop(delegate:). The
            // DropDelegate form has a fatal flaw for this app: on a multi-file
            // drag, DropInfo.itemProviders(for:) vends only ONE provider (even
            // when asked for just .fileURL), so a video + stems drop reached
            // routing as a single video. NSDraggingInfo's pasteboard returns
            // every dragged file. Same pattern as AudioLaneDragCaptureView.
            .overlay {
                VideoTrackDragCaptureView(
                    onEntered: { info, location in
                        beginDropPreviewNative(info: info, at: location)
                        return (isDropAllowed || isLoadingDropPreview) ? .copy : []
                    },
                    onUpdated: { info, location in
                        dragContext.refresh()
                        updateDropPreview(location: location)
                        return (isDropAllowed || isLoadingDropPreview) ? .copy : []
                    },
                    onExited: {
                        clearDropPreview()
                    },
                    onPerform: { info, location in
                        handleDropNative(info: info, at: location)
                    }
                )
            }
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
        VStack(spacing: Spacing.xs) {
            Image(systemName: "film")
                .frame(width: 20, height: 20)
                .foregroundColor(.secondary.opacity(0.6))

            Text("Drop video files here")
                .font(Typography.caption)
                .foregroundColor(.secondary.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            .padding(.vertical, Spacing.xs)
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
                isSelected: selectedReelId == reel.id || selectedReelIds.contains(reel.id),
                interactionsEnabled: clipInteractionsEnabled,
                isOptimized: isReelOptimized(reel),
                timelineStartTimecode: timelineManager.formatTimecode(forFrame: reel.timelineStartFrame),
                onSelect: { modifiers in
                    selectedReelId = reel.id
                    onReelSelected(reel.id, modifiers)
                },
                onDoubleClick: {
                    onReelDoubleClick(reel)
                },
                onSetTimelineStart: {
                    timelineManager.setTimelineStart(toFrame: reel.timelineStartFrame)
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
                            onReelSelected(reel.id, SelectionModifiers.current)
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

                        // Only move if new position is not inside another reel
                        let isOverExisting = isFrameInsideExistingReel(newFrame, excluding: reel.id)
                        if !isOverExisting {
                            onReelMove(reel.id, newFrame)
                        }
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

    /// Routes video/audio URLs to the appropriate handler
    /// - Mixed drops (video + audio): routes to onDropMixedMedia
    /// - Video-only drops: routes to onDropMedia
    /// - Audio-only drops: ignored (audio lane handles these)
    private func routeDroppedMedia(videoURLs: [URL], audioURLs: [URL], targetFrame: Int, isInternalDrag: Bool) {
        if !videoURLs.isEmpty && !audioURLs.isEmpty, let onMixed = onDropMixedMedia {
            onMixed(videoURLs, audioURLs, targetFrame)
        } else if !videoURLs.isEmpty {
            onDropMedia(videoURLs, targetFrame, isInternalDrag)
        }
        // Audio-only drops on video track: ignored (existing behavior)
    }

    /// All dragged media, from DragContext for internal drags or from the
    /// dragging pasteboard for Finder drags. The pasteboard returns every
    /// dragged file in drag order.
    private func mediaCandidates(from info: NSDraggingInfo) -> (videoURLs: [URL], audioURLs: [URL], isInternal: Bool) {
        if dragContext.isDragging && !dragContext.mediaItems.isEmpty {
            let videoURLs = dragContext.mediaItems.filter { $0.type == .video }.map { $0.url }
            let audioURLs = dragContext.mediaItems.filter { $0.type == .audio }.map { $0.url }
            return (videoURLs, audioURLs, true)
        }

        let allURLs = (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL]) ?? []
        let videoURLs = allURLs.filter { ProjectMediaLibrary.mediaType(for: $0) == .video }
        let audioURLs = allURLs.filter { ProjectMediaLibrary.mediaType(for: $0) == .audio }
        return (videoURLs, audioURLs, false)
    }

    private func handleDropNative(info: NSDraggingInfo, at location: CGPoint) -> Bool {
        let candidates = mediaCandidates(from: info)
        debugPrint("VideoTrackView.handleDropNative: \(candidates.videoURLs.count) video, \(candidates.audioURLs.count) audio (internal=\(candidates.isInternal))")
        let targetFrame = dropFrame(for: location)

        routeDroppedMedia(
            videoURLs: candidates.videoURLs,
            audioURLs: candidates.audioURLs,
            targetFrame: targetFrame,
            isInternalDrag: candidates.isInternal
        )

        if candidates.isInternal {
            dragContext.end()
        }
        clearDropPreview()
        // The pasteboard either had usable media or it didn't - claiming the
        // drop when both lists are empty would just swallow it silently.
        return !(candidates.videoURLs.isEmpty && candidates.audioURLs.isEmpty)
    }

    private func isVideoFile(_ url: URL) -> Bool {
        ProjectMediaLibrary.mediaType(for: url) == .video
    }

    private func isLinkedPreview(_ reel: VideoReel, preview: LinkedDragPreview) -> Bool {
        reel.sourceURL == preview.sourceURL &&
        reel.sourceStartFrame == preview.sourceStartFrame &&
        reel.durationFrames == preview.durationFrames &&
        reel.timelineStartFrame == preview.fromFrame
    }

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

    private func dropFrame(for location: CGPoint) -> Int {
        let x = max(0, location.x + scrollOffset)
        let rawFrame = Int(x / max(pixelsPerFrame, 0.001))
        return max(0, rawFrame)  // Only clamp lower bound, let business logic auto-extend
    }

    private func updateDropPreview(location: CGPoint) {
        latestDropLocation = location
        let frame = dropFrame(for: location)
        dropPreviewFrame = frame

        // Disallow drop if cursor is over an existing reel
        if dropPreviewDurationFrames != nil {
            let isOverExisting = isFrameInsideExistingReel(frame)
            isDropAllowed = !isOverExisting
        }
    }

    private func beginDropPreviewNative(info: NSDraggingInfo, at location: CGPoint) {
        updateDropPreview(location: location)
        if dropPreviewDurationFrames != nil || isLoadingDropPreview {
            return
        }
        isLoadingDropPreview = true
        isDropAllowed = false

        let candidates = mediaCandidates(from: info)
        // Audio-only drags belong to the audio lanes; preview only when the
        // drag brings at least one video.
        guard let firstVideo = candidates.videoURLs.first else {
            isLoadingDropPreview = false
            clearDropPreview()
            return
        }

        // Duplicate videos are rejected at drop time; disallow the preview too.
        if timelineManager.timeline.videoReels.contains(where: { $0.sourceURL == firstVideo }) {
            isLoadingDropPreview = false
            isDropAllowed = false
            return
        }

        updateDropPreview(location: latestDropLocation ?? location)
        Task {
            let asset = AVAsset(url: firstVideo)
            do {
                let duration = try await asset.load(.duration)
                let frames = max(1, Int(duration.seconds * timelineManager.timeline.config.frameRate.fps))
                dropPreviewDurationFrames = frames

                // Disallow drop if cursor is over an existing reel
                let targetFrame = dropFrame(for: latestDropLocation ?? location)
                let isOverExisting = isFrameInsideExistingReel(targetFrame)
                isDropAllowed = !isOverExisting
            } catch {
                dropPreviewDurationFrames = nil
                isDropAllowed = false
            }
            isLoadingDropPreview = false
        }
    }

    private func isFrameInsideExistingReel(_ frame: Int, excluding reelId: UUID? = nil) -> Bool {
        for reel in timelineManager.timeline.videoReels {
            if reel.id == reelId { continue }

            if frame >= reel.timelineStartFrame && frame < reel.timelineEndFrame {
                return true
            }
        }
        return false
    }

    private func clearDropPreview() {
        dropPreviewFrame = nil
        dropPreviewDurationFrames = nil
        isLoadingDropPreview = false
        isDropAllowed = false
    }

}

// MARK: - Drag Capture (AppKit)

/// AppKit-level drag capture for the video track.
///
/// Exists because SwiftUI's `.onDrop(of:delegate:)` was vending a single
/// NSItemProvider for multi-file drags (`DropInfo.itemProviders(for:)` returned
/// 1 even for a bare `.fileURL` query), which silently reduced a video+stems
/// drop to just the video. `NSDraggingInfo.draggingPasteboard` returns every
/// dragged file. Mirrors `AudioLaneDragCaptureView` / `DragCaptureView`.
private struct VideoTrackDragCaptureView: NSViewRepresentable {
    var onEntered: (NSDraggingInfo, CGPoint) -> NSDragOperation
    var onUpdated: (NSDraggingInfo, CGPoint) -> NSDragOperation
    var onExited: () -> Void
    var onPerform: (NSDraggingInfo, CGPoint) -> Bool

    func makeNSView(context: Context) -> VideoTrackDragCaptureNSView {
        let view = VideoTrackDragCaptureNSView()
        view.onEntered = onEntered
        view.onUpdated = onUpdated
        view.onExited = onExited
        view.onPerform = onPerform
        return view
    }

    func updateNSView(_ nsView: VideoTrackDragCaptureNSView, context: Context) {
        nsView.onEntered = onEntered
        nsView.onUpdated = onUpdated
        nsView.onExited = onExited
        nsView.onPerform = onPerform
    }
}

private final class VideoTrackDragCaptureNSView: NSView {
    var onEntered: ((NSDraggingInfo, CGPoint) -> NSDragOperation)?
    var onUpdated: ((NSDraggingInfo, CGPoint) -> NSDragOperation)?
    var onExited: (() -> Void)?
    var onPerform: ((NSDraggingInfo, CGPoint) -> Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDragTypes()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDragTypes()
    }

    private func registerForDragTypes() {
        registerForDraggedTypes([
            .fileURL,
            .URL,
            NSPasteboard.PasteboardType("com.projector.media-item"),
            NSPasteboard.PasteboardType("public.item")
        ])
    }

    // Pass all mouse events through to the SwiftUI reels underneath; only
    // drag-and-drop (which bypasses hitTest via registerForDraggedTypes) is
    // handled here.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        false
    }

    override func mouseDown(with event: NSEvent) {
        nextResponder?.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        nextResponder?.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        nextResponder?.mouseUp(with: event)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onEntered?(sender, localLocation(for: sender)) ?? []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        onUpdated?(sender, localLocation(for: sender)) ?? []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onExited?()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onPerform?(sender, localLocation(for: sender)) ?? false
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        onExited?()
    }

    private func localLocation(for info: NSDraggingInfo) -> CGPoint {
        convert(info.draggingLocation, from: nil)
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
                onReelSelected: { id, modifiers in
                    print("Selected: \(String(describing: id)), modifiers: \(modifiers)")
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
