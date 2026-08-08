import SwiftUI
import Foundation
import SwiftTimecodeCore
import UniformTypeIdentifiers
import AVFoundation
import AppKit

/// Simple triangle shape for playhead
private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.closeSubpath()
        }
    }
}

/// Subtle darker background for timeline content areas
struct DustyBackground: View {
    var body: some View {
        Color(white: 0.12)
    }
}

/// Helper view that captures a reference to the nearest ancestor NSScrollView.
///
/// Used for programmatic scroll operations like auto-scroll during marquee selection.
/// Embeds an invisible NSView that traverses up the view hierarchy to find
/// the enclosing NSScrollView and reports it via a binding.
private struct ScrollViewCaptureHelper: NSViewRepresentable {
    @Binding var scrollView: NSScrollView?

    func makeNSView(context: Context) -> NSView {
        let view = ScrollViewFinderView()
        view.onScrollViewFound = { [self] foundScrollView in
            DispatchQueue.main.async {
                self.scrollView = foundScrollView
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    /// Custom NSView that finds its ancestor NSScrollView
    private class ScrollViewFinderView: NSView {
        var onScrollViewFound: ((NSScrollView?) -> Void)?

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            // Delay to ensure view hierarchy is fully set up
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.findScrollView()
            }
        }

        private func findScrollView() {
            var currentView: NSView? = superview
            while let view = currentView {
                if let scrollView = view as? NSScrollView {
                    onScrollViewFound?(scrollView)
                    return
                }
                currentView = view.superview
            }
            onScrollViewFound?(nil)
        }
    }
}

/// Multi-track timeline view with video reels and audio lanes
struct MultiTrackTimelineView: View {
    @ObservedObject var timelineManager: TimelineManager
    // PlaybackEngine is NOT observed at view level to prevent constant re-renders.
    // Sub-views that need playback state (PlayheadView, transport controls) observe it directly.
    let playbackEngine: PlaybackEngine
    @ObservedObject var waveformCache: WaveformCache
    @ObservedObject var audioOutputManager: AudioOutputManager
    @ObservedObject var thumbnailCache: ThumbnailCache
    @ObservedObject var mediaLibrary: ProjectMediaLibrary
    @EnvironmentObject private var dragContext: DragContext
    @Environment(\.undoManager) private var undoManager
    let onDropVideoMedia: ([URL], Int, Bool) -> Void
    let onDropAudioMedia: (Int, [URL], Int, Bool) -> Void
    /// Called when mixed video/audio files are dropped on the timeline
    var onDropMixedMedia: (([URL], [URL], Int) -> Void)?
    let onSeek: (Int) -> Void
    let onSettingsPressed: () -> Void
    var showHeader: Bool = true
    @Binding var zoomLevel: CGFloat
    /// Counter that asks the timeline to frame its content. Each new value is
    /// one request; see `TimelineViewModel.requestZoomToFitContent()`.
    var zoomToFitContentRequest: Int = 0

    // MARK: - State

    @State private var isHoveringStartTC = false
    @State private var editingStartTCText = ""
    @State private var isStartTCFocused: Bool = false
    @State private var isHoveringPosition = false
    @State private var editingPositionText = ""
    @State private var isPositionFocused: Bool = false
    @State private var showExtendDurationConfirmation = false
    @State private var pendingSeekFrame: Int?
    @State private var isEmptyAudioDropAllowed = false
    @State private var isEmptyAudioDropLoading = false
    @State private var emptyAudioDropPreviewFrame: Int?
    @State private var emptyAudioDropPreviewDurationFrames: Int?
    @State private var emptyAudioDropLocation: CGPoint?
    @State private var emptyAudioDropSourceURL: URL?

    // Selection state (single selection for compatibility)
    @State private var selectedVideoReelId: UUID?
    @State private var selectedAudioClipId: UUID?
    @State private var selectedAudioLaneId: UUID?

    // Multi-selection state for marquee selection
    @State private var selectedVideoReelIds: Set<UUID> = []
    @State private var selectedAudioClipIds: Set<UUID> = []

    // Clipboard state for cut/copy/paste
    @State private var clipboardVideoReelIds: Set<UUID> = []
    @State private var clipboardAudioClipIds: Set<UUID> = []
    @State private var showPasteError = false
    @State private var pasteErrorMessage = ""

    // Marquee selection state
    @State private var isMarqueeSelecting = false
    @State private var marqueeStartPoint: CGPoint = .zero
    @State private var marqueeCurrentPoint: CGPoint = .zero

    // Focus state for keyboard commands
    @FocusState private var isTimelineFocused: Bool

    // Timecode entry dialog state
    @State private var showTimecodeEntryDialog = false
    @State private var timecodeEntryText = ""
    @State private var timecodeEntryError: String?
    @State private var editingReelId: UUID?
    @State private var editingClipId: UUID?
    @State private var editingLaneId: UUID?

    // Cached active audio clip IDs (updated only when currentFrame changes)
    @State private var cachedActiveAudioClipIds: Set<UUID> = []
    @State private var lastFrameForActiveClips: Int = -1
    @State private var linkedDragPreview: LinkedDragPreview?
    @State private var laneChangePreview: LaneChangePreview?

    // Lane reorder state
    @State private var draggingLaneId: UUID?
    @State private var draggingLaneSourceIndex: Int?
    @State private var draggingLaneOffset: CGFloat = 0
    @State private var laneReorderTargetIndex: Int?
    @State private var laneReorderCursorPushed = false

    // Unified multi-file drop state
    @State private var isMultiFileDropTargeted = false
    @State private var externalDragItemCount: Int = 0

    // Auto-scroll state for marquee selection
    @State private var autoScrollTimer: Timer?
    @State private var cachedScrollView: NSScrollView?
    /// Horizontal scroll offset of the track area, in points.
    ///
    /// The ruler and playhead are drawn outside the ScrollView, so they need
    /// this to stay aligned with the content that does scroll.
    @State private var horizontalScrollOffset: CGFloat = 0

    /// Width the track area was last laid out at, including the header column.
    ///
    /// The one number the zoom curve is a function of, kept so
    /// ``zoomToFitContent()`` can invert that curve using **exactly** the width
    /// `pixelsPerFrame(for:)` was given rather than a second measurement that
    /// only looks like it. The scroll view's own clip view is not that width -
    /// measured on the same layout, the geometry reports 1416pt while the clip
    /// view is 1399pt - and solving with the wrong one lands the zoom about 1.3%
    /// off, which is enough to spend the whole margin the framing asks for.
    ///
    /// Recorded, never fed back: nothing sizes itself from this, so it cannot
    /// become the measure-and-resize loop `SectionLayout` warns about.
    @State private var trackAreaWidth: CGFloat = 0

    /// Whether the zoom change now in flight came from framing content.
    ///
    /// Framing chooses a scroll offset of its own, so the playhead anchor has to
    /// stand aside for that one change or the two fight over the offset.
    @State private var isFramingContent = false

    /// Screen position the playhead is being held at for the zoom change in
    /// progress, in track-area points.
    ///
    /// Captured once, on the first change of a burst, and reused by every change
    /// until the burst is applied. A zoom step is animated, so `zoomLevel`
    /// arrives as a stream of interpolated values - measured, 195 of them across
    /// six clicks, some delivered out of order. Re-reading the playhead's
    /// position per value drifted it left across the animation (measured: 629pt
    /// to 204pt over one zoom-out) because each read saw an offset the previous
    /// value had not finished applying. Holding the *pre-burst* position instead
    /// makes the whole animation converge on one answer.
    @State private var pendingAnchorX: CGFloat?

    /// Identifies the newest zoom change, so a superseded one does not scroll to
    /// a target the user has already zoomed past.
    @State private var anchorToken = 0

    /// Whether the video file's baked-in audio strip is shown.
    ///
    /// Collapsing it leaves the Video File track as a single picture row, for
    /// when the embedded audio is not what you are working on.
    @State private var isVideoAudioExpanded = true
    @State private var scrollAreaFrame: CGRect = .zero

    // Video track rename state
    @State private var isEditingVideoName = false
    @State private var editedVideoName = ""
    @FocusState private var isVideoNameFieldFocused: Bool

    // MARK: - Constants

    /// Height for the inactive "new lane" drop target
    private let newLaneDropInactiveHeight: CGFloat = TimelineLayout.newLaneDropZoneInactiveHeight

    /// Distance from edge to trigger auto-scroll during marquee selection
    private let autoScrollEdgeInset: CGFloat = 50

    /// Scroll speed in points per timer tick
    private let autoScrollSpeed: CGFloat = 20

    // MARK: - Computed Properties

    /// Pixels per frame at maximum zoom - the scale at which individual frames
    /// are distinguishable.
    private static let maxPixelsPerFrame: CGFloat = 4.0

    /// Floor for the zoom range, so short timelines still zoom in usefully.
    private static let minZoomMultiplier: CGFloat = 10.0

    /// How far max zoom must reach past fit-to-view, given this timeline.
    ///
    /// Was a hardcoded 10x, which silently made the zoom range a function of
    /// timeline duration: 10x fit on a short media-length timeline is frame
    /// level, but 10x fit on the default 4-hour timeline is still only
    /// ~0.02pt/frame - the playhead crawls at half a point per second and the
    /// transport looks frozen at *every* slider position. Deriving the ceiling
    /// from a target pixels-per-frame makes max zoom mean the same thing
    /// regardless of how long the timeline is.
    private func maxZoomMultiplier(fitPixelsPerFrame: CGFloat) -> CGFloat {
        guard fitPixelsPerFrame > 0 else { return Self.minZoomMultiplier }
        return max(Self.minZoomMultiplier, Self.maxPixelsPerFrame / fitPixelsPerFrame)
    }

    private func pixelsPerFrame(for availableWidth: CGFloat) -> CGFloat {
        let contentWidth = max(1, availableWidth - TimelineLayout.headerWidth)
        let durationFrames = max(1, timeline.config.durationFrames)
        let fitPixelsPerFrame = contentWidth / CGFloat(durationFrames)
        let clampedZoom = min(max(zoomLevel, minZoom), maxZoom)

        // Geometric, not linear. Spanning ~1700x linearly would leave every
        // useful working scale crammed into the last few percent of the slider;
        // geometric interpolation gives each slider position a constant *ratio*
        // of change, which is how zoom controls are expected to behave.
        let multiplier = pow(maxZoomMultiplier(fitPixelsPerFrame: fitPixelsPerFrame), clampedZoom)
        return fitPixelsPerFrame * multiplier
    }

    /// Axes the track area may scroll on.
    ///
    /// Horizontal scrolling is only offered when zoomed in, because at fit zoom
    /// the content is defined to be exactly the viewport width and there is
    /// nothing to scroll to. Leaving the axis enabled there caused a visible
    /// glitch: adding a lane makes the content taller before the panel grows to
    /// match, so a vertical scroller is inserted for a frame and takes 17pt of
    /// width - which briefly makes a perfectly-fitting timeline horizontally
    /// scrollable and flashes a scrollbar. Measured at 978pt of content in a
    /// 962pt viewport, settling to 979pt about 50ms later.
    ///
    /// With the axis off, that transient clips instead of scrolling, which is
    /// invisible at 17pt for one frame.
    private var scrollAxes: Axis.Set {
        zoomLevel > minZoom ? [.horizontal, .vertical] : .vertical
    }

    private func timelineContentWidth(for availableWidth: CGFloat) -> CGFloat {
        let content = CGFloat(timeline.config.durationFrames)
            * pixelsPerFrame(for: availableWidth)
            + TimelineLayout.headerWidth

        // Rounded down because at fit zoom this is meant to equal the viewport
        // exactly, and floating point does not oblige: dividing the width by the
        // frame count and multiplying back can land a fraction of a point over
        // (1hr at 25fps overshoots 936pt by ~1e-13). That is enough to make the
        // content horizontally scrollable, and macOS overlay scrollbars flash on
        // every content change - so adding a lane blinked a horizontal scrollbar
        // for a timeline that fits perfectly. Zoomed in, losing a sub-point is
        // invisible against a content width in the thousands.
        return content.rounded(.down)
    }

    private var timeline: Timeline {
        timelineManager.timeline
    }

    private var totalHeight: CGFloat {
        var height = TimelineLayout.toolbarHeight + TimelineLayout.rulerHeight + 1 // Toolbar + ruler + divider
        height += TimelineLayout.videoTrackHeight + 1 // Video track + divider
        height += max(TimelineLayout.audioLaneHeight, CGFloat(timeline.audioLanes.count) * (TimelineLayout.audioLaneHeight + 1)) // Audio lanes
        return height
    }

    /// Active audio clip IDs - uses cached value to avoid recalculation on scroll
    private var activeAudioClipIds: Set<UUID> {
        cachedActiveAudioClipIds
    }

    /// Whether we're dragging multiple items (from media panel or external like Finder)
    private var isMultiFileDrag: Bool {
        dragContext.mediaItems.count > 1 || externalDragItemCount > 1
    }

    /// Update cached active audio clip IDs when frame changes
    private func updateActiveAudioClipIds() {
        let currentFrame = playbackEngine.currentFrame
        guard currentFrame != lastFrameForActiveClips else { return }
        lastFrameForActiveClips = currentFrame
        cachedActiveAudioClipIds = Set(timeline.activeAudioClips(at: currentFrame).map { $0.clip.id })
    }

    // MARK: - Body
    //
    // The body is split into helper properties to avoid Swift's type-checker
    // timing out on the deeply nested modifier chains.

    var body: some View {
        bodyWithKeyboardHandlers
    }

    /// Core layout: header (optional) + tracks.
    private var bodyCore: some View {
        VStack(spacing: 0) {
            if showHeader {
                headerSection
            }
            tracksSection
        }
    }

    /// Visual styling applied to the core layout.
    private var bodyWithVisuals: some View {
        bodyCore
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .windowBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Focus handling added on top of visuals.
    private var bodyWithFocus: some View {
        bodyWithVisuals
            .focusable()
            .focusRingHidden()
            .focused($isTimelineFocused)
            .onDeleteCommand {
                deleteSelectedItem()
            }
    }

    /// Sheets and alerts added.
    private var bodyWithDialogs: some View {
        bodyWithFocus
            .sheet(isPresented: $showTimecodeEntryDialog) {
                timecodeEntryDialogContent
            }
            .alert("Paste Failed", isPresented: $showPasteError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(pasteErrorMessage)
            }
            .alert("Extend Timeline?", isPresented: $showExtendDurationConfirmation) {
                Button("Cancel", role: .cancel) {
                    pendingSeekFrame = nil
                    editingPositionText = playheadTimecodeString()
                }
                Button("Extend") {
                    confirmExtendAndSeek()
                }
            } message: {
                Text("The position you entered is beyond the current timeline duration. Would you like to extend the timeline to include this position?")
            }
    }

    /// onChange handlers for selection and playback.
    private var bodyWithOnChange: some View {
        bodyWithDialogs
            .onChangeCompat(of: selectedVideoReelId) { newValue in
                if newValue != nil {
                    isTimelineFocused = true
                }
            }
            .onChangeCompat(of: selectedAudioClipId) { newValue in
                if newValue != nil {
                    isTimelineFocused = true
                }
            }
            .onChangeCompat(of: playbackEngine.currentFrame) { _ in
                updateActiveAudioClipIds()
                scrollPlayheadIntoViewIfNeeded()
            }
            .onChangeCompat(of: cachedScrollView) { scrollView in
                scrollView?.contentView.postsBoundsChangedNotifications = true
                horizontalScrollOffset = scrollView?.contentView.bounds.origin.x ?? 0
            }
            .onChangeCompat(of: zoomToFitContentRequest) { _ in
                zoomToFitContent()
            }
            .onChangeWithPrevious(of: zoomLevel) { oldZoom, newZoom in
                anchorPlayheadAcrossZoom(from: oldZoom, to: newZoom)
            }
    }

    /// Notification handlers for scroll and edit menu.
    private var bodyWithNotifications: some View {
        bodyWithOnChange
            .onReceive(NotificationCenter.default.publisher(for: NSView.boundsDidChangeNotification)) { note in
                guard let clipView = note.object as? NSClipView,
                      clipView === cachedScrollView?.contentView else { return }
                horizontalScrollOffset = clipView.bounds.origin.x
            }
            .onAppear {
                updateActiveAudioClipIds()
            }
            // Deliberately *not* gated on `isTimelineFocused`, unlike Delete and
            // Select All below.
            //
            // Undo is a document-wide command: a drop lands on the timeline
            // without giving it focus, so requiring focus meant Cmd-Z after an
            // import did nothing at all - and did it silently, which reads as "the
            // app has no undo" rather than "click the timeline first". Delete is
            // different and keeps its gate: which panel has focus decides what
            // Delete even means.
            .onReceive(NotificationCenter.default.publisher(for: .editUndo)) { _ in
                undoManager?.undo()
            }
            .onReceive(NotificationCenter.default.publisher(for: .editRedo)) { _ in
                undoManager?.redo()
            }
            .onReceive(NotificationCenter.default.publisher(for: .editDelete)) { _ in
                guard isTimelineFocused else { return }
                deleteSelectedItem()
            }
            .onReceive(NotificationCenter.default.publisher(for: .editSelectAll)) { _ in
                guard isTimelineFocused else { return }
                selectAll()
            }
            .onReceive(NotificationCenter.default.publisher(for: .editDeselectAll)) { _ in
                guard isTimelineFocused else { return }
                deselectAll()
            }
            .onReceive(NotificationCenter.default.publisher(for: .editCut)) { _ in
                guard isTimelineFocused else { return }
                cutSelectedItems()
            }
            .onReceive(NotificationCenter.default.publisher(for: .editCopy)) { _ in
                guard isTimelineFocused else { return }
                copySelectedItems()
            }
            .onReceive(NotificationCenter.default.publisher(for: .editPaste)) { _ in
                guard isTimelineFocused else { return }
                pasteItems()
            }
    }

    /// Keyboard navigation handlers.
    private var bodyWithKeyboardHandlers: some View {
        bodyWithNotifications
            // Return lives here too now, so every key the timeline claims is
            // declared in one place rather than split across two modifiers.
            .onTimelineKey(isEnabled: !isEditingText) { key in
                switch key {
                case .returnKey: playbackEngine.stop()
                case .escape:    deselectAll()
                case .leftArrow:  navigateSelection(direction: .left)
                case .rightArrow: navigateSelection(direction: .right)
                case .upArrow:    navigateSelection(direction: .up)
                case .downArrow:  navigateSelection(direction: .down)
                }
                return true
            }
    }

    // MARK: - Text Editing Guard

    /// Whether a text field currently has keyboard focus anywhere in the app.
    ///
    /// The timeline is `.focusable()` and installs container-level
    /// `.onKeyPress` handlers for Return, Escape, and the arrow keys. An
    /// ancestor's key handler runs BEFORE a descendant text field's
    /// `onSubmit`, so while renaming a lane those handlers swallowed the very
    /// keys the field needs: Return stopped playback instead of committing the
    /// name, Escape cleared the selection instead of cancelling the edit, and
    /// the arrows moved the selection instead of the insertion point.
    ///
    /// Reading the first responder covers every text field under the timeline
    /// without threading editing state through each one - SwiftUI's TextField
    /// edits via an NSTextView field editor.
    var isEditingText: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        if let textView = responder as? NSTextView {
            return textView.isFieldEditor || textView.isEditable
        }
        return responder is NSTextField
    }

    // MARK: - Delete Selected Items

    /// Delete all selected items (video reels and audio clips)
    ///
    /// Handles both single and multi-selection:
    /// - Uses `selectedVideoReelIds` and `selectedAudioClipIds` for multi-selection
    /// - Falls back to singular `selectedVideoReelId` and `selectedAudioClipId` for compatibility
    /// - Registers a single undo operation before any deletions
    /// - Removes linked audio clips when deleting video reels
    /// - Cleans up empty audio lanes after all deletions
    private func deleteSelectedItem() {
        // Collect all items to delete
        var reelIdsToDelete: Set<UUID> = selectedVideoReelIds
        var clipIdsToDelete: Set<UUID> = selectedAudioClipIds

        // Fall back to singular selection if multi-selection is empty
        if reelIdsToDelete.isEmpty, let singleReelId = selectedVideoReelId {
            reelIdsToDelete.insert(singleReelId)
        }
        if clipIdsToDelete.isEmpty, let singleClipId = selectedAudioClipId {
            clipIdsToDelete.insert(singleClipId)
        }

        // Nothing to delete
        guard !reelIdsToDelete.isEmpty || !clipIdsToDelete.isEmpty else { return }

        // Build description for undo action
        let reelCount = reelIdsToDelete.count
        let clipCount = clipIdsToDelete.count
        let actionName: String
        if reelCount > 0 && clipCount > 0 {
            actionName = "Delete \(reelCount + clipCount) Items"
        } else if reelCount > 1 {
            actionName = "Delete \(reelCount) Video Reels"
        } else if reelCount == 1 {
            actionName = "Delete Video Reel"
        } else if clipCount > 1 {
            actionName = "Delete \(clipCount) Audio Clips"
        } else {
            actionName = "Delete Audio Clip"
        }

        // Register undo ONCE before any modifications
        registerTimelineUndo(actionName: actionName)

        // Track which video reels we've already handled (to avoid double-delete via linked audio)
        var deletedReelIds: Set<UUID> = []

        // First, check if any selected audio clips are linked to video reels
        // If so, we'll delete the reel (which deletes all linked audio)
        for clipId in clipIdsToDelete {
            guard let (_, clip) = findClip(by: clipId) else { continue }
            if clip.sourceType == .videoTrack, let reel = linkedReel(for: clip) {
                // This clip is linked to a video reel - add the reel to delete list
                reelIdsToDelete.insert(reel.id)
            }
        }

        // Delete all video reels and their linked audio
        for reelId in reelIdsToDelete {
            guard let reel = timelineManager.timeline.videoReels.first(where: { $0.id == reelId }) else { continue }
            removeLinkedAudio(for: reel, cleanupLanes: false)
            timelineManager.removeVideoReel(id: reelId)
            deletedReelIds.insert(reelId)
        }

        // Delete standalone audio clips (not linked to video)
        for clipId in clipIdsToDelete {
            guard let (lane, clip) = findClip(by: clipId) else { continue }
            // Skip if this clip was already deleted as part of a video reel
            if clip.sourceType == .videoTrack {
                continue // Already handled when we deleted the linked reel
            }
            timelineManager.removeAudioClip(clipId: clipId, fromLane: lane.id)
        }

        // Clean up empty lanes ONCE after all deletions
        removeEmptyAudioLanes()

        // Clear all selection state
        clearSelection()
    }

    /// Find a clip by its ID across all audio lanes
    private func findClip(by clipId: UUID) -> (lane: AudioLane, clip: AudioClip)? {
        for lane in timelineManager.timeline.audioLanes {
            if let clip = lane.clips.first(where: { $0.id == clipId }) {
                return (lane, clip)
            }
        }
        return nil
    }

    private func linkedReel(for clip: AudioClip) -> VideoReel? {
        timelineManager.timeline.videoReels.first { reel in
            reel.sourceURL == clip.sourceURL &&
            reel.sourceStartFrame == clip.sourceStartFrame &&
            reel.durationFrames == clip.durationFrames &&
            reel.timelineStartFrame == clip.timelineStartFrame
        }
    }

    /// Remove all audio clips linked to a video reel
    ///
    /// - Parameters:
    ///   - reel: The video reel whose linked audio should be removed
    ///   - cleanupLanes: Whether to remove empty lanes after removal (default: true)
    private func removeLinkedAudio(for reel: VideoReel, cleanupLanes: Bool = true) {
        let removals: [(laneId: UUID, clipId: UUID)] = timelineManager.timeline.audioLanes.flatMap { lane in
            lane.clips.compactMap { clip in
                guard clip.sourceType == .videoTrack,
                      clip.sourceURL == reel.sourceURL,
                      clip.sourceStartFrame == reel.sourceStartFrame,
                      clip.durationFrames == reel.durationFrames,
                      clip.timelineStartFrame == reel.timelineStartFrame else {
                    return nil
                }
                return (lane.id, clip.id)
            }
        }

        for removal in removals {
            timelineManager.removeAudioClip(clipId: removal.clipId, fromLane: removal.laneId)
        }

        if cleanupLanes {
            removeEmptyAudioLanes()
        }
    }

    private func removeEmptyAudioLanes() {
        let emptyLaneIds = timelineManager.timeline.audioLanes
            .filter { $0.clips.isEmpty }
            .map { $0.id }
        for laneId in emptyLaneIds {
            timelineManager.removeAudioLane(id: laneId)
        }
    }

    // MARK: - Timecode Entry Dialog

    private var timecodeEntryDialogContent: some View {
        VStack(spacing: Spacing.lg) {
            Text("Enter New Position")
                .font(.headline)

            TextField("00:00:00:00", text: $timecodeEntryText)
                .textFieldStyle(.roundedBorder)
                .font(Typography.monoDisplay)
                .frame(width: 150)
                .onChangeCompat(of: timecodeEntryText) { newValue in
                    timecodeEntryText = formatTimecodeInput(newValue)
                    timecodeEntryError = nil // Clear error when user types
                }

            if let error = timecodeEntryError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: Spacing.md) {
                Button("Cancel") {
                    showTimecodeEntryDialog = false
                    clearEditingState()
                }
                .keyboardShortcut(.cancelAction)

                Button("Apply") {
                    applyTimecodeEntry()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.xxl)
        .frame(minWidth: 280)
    }

    private func applyTimecodeEntry() {
        guard let newTC = parseTimecode(timecodeEntryText) else {
            timecodeEntryError = "Invalid timecode format"
            return
        }

        let newFrame = newTC.frameCount.wholeFrames - timeline.config.startTimecode.frameCount.wholeFrames

        // Get the duration of the region being moved
        var regionDuration = 0
        if let reelId = editingReelId,
           let reel = timeline.videoReels.first(where: { $0.id == reelId }) {
            regionDuration = reel.durationFrames
        } else if let clipId = editingClipId, let laneId = editingLaneId,
                  let lane = timeline.audioLanes.first(where: { $0.id == laneId }),
                  let clip = lane.clips.first(where: { $0.id == clipId }) {
            regionDuration = clip.durationFrames
        }

        // Check if new position is before timeline start
        if newFrame < 0 {
            timecodeEntryError = "Position is before timeline start"
            return
        }

        // Auto-extend timeline if region would exceed current duration
        let regionEndFrame = newFrame + regionDuration
        if regionEndFrame > timeline.config.durationFrames {
            let paddingFrames = Int(TimelineLayout.defaultPaddingMinutes * 60.0 * timeline.config.frameRate.fps)
            timelineManager.extendTimeline(toEndFrame: regionEndFrame + paddingFrames)
            // Zoom to fit so user sees the full timeline
            zoomLevel = minZoom
        }

        // Apply the move
        if let reelId = editingReelId {
            if let oldFrame = timeline.videoReels.first(where: { $0.id == reelId })?.timelineStartFrame,
               oldFrame != newFrame {
                registerVideoReelMoveUndo(reelId: reelId, from: oldFrame)
            }
            timelineManager.moveVideoReel(id: reelId, to: newFrame)
        } else if let clipId = editingClipId, let laneId = editingLaneId {
            if let lane = timeline.audioLanes.first(where: { $0.id == laneId }),
               let clip = lane.clips.first(where: { $0.id == clipId }),
               clip.timelineStartFrame != newFrame {
                registerAudioClipMoveUndo(clipId: clipId, laneId: laneId, from: clip.timelineStartFrame)
            }
            timelineManager.moveAudioClip(clipId: clipId, inLane: laneId, to: newFrame)
        }

        showTimecodeEntryDialog = false
        clearEditingState()
    }

    private func clearEditingState() {
        editingReelId = nil
        editingClipId = nil
        editingLaneId = nil
        timecodeEntryText = ""
        timecodeEntryError = nil
    }

    // MARK: - Header Section

    private var headerSection: some View {
        VStack(spacing: 0) {
            // Toolbar: Start TC | Position | FPS | Transport | Zoom | Settings
            HStack(spacing: Spacing.md) {
                // Start timecode (editable)
                startTCBox

                // Current position (editable - double-click or click to edit)
                positionBox

                // Transport controls
                transportControls

                Spacer()

                // Zoom controls
                zoomControls

                // Show the standalone player window. Always enabled - the
                // window may be hidden (closed) or just behind another window,
                // and show() handles both.
                Button(action: { PlayerWindowController.shared.show() }) {
                    Image(systemName: "play.rectangle")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("Show the video player window")
                .accessibilityLabel("Show video player window")
            }
            .padding(.horizontal, Spacing.md)
            .frame(height: TimelineLayout.toolbarHeight)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))

            Divider()
        }
    }

    private var transportControls: some View {
        // Use separate view to isolate playback state observation
        TransportControlsView(playbackEngine: playbackEngine)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(AppColors.borderLight, lineWidth: PanelLayout.borderWidth)
            )
    }

    private var zoomControls: some View {
        HStack(spacing: Spacing.xs) {
            Button(action: { zoomOut() }) {
                Image(systemName: "minus.magnifyingglass")
                    .font(Typography.bodySmall)
            }
            .buttonStyle(.plain)
            .disabled(zoomLevel <= minZoom)
            .help("Zoom out")
            .accessibilityLabel("Zoom out")

            Slider(value: $zoomLevel, in: minZoom...maxZoom)
                .frame(width: 80)
                .controlSize(.mini)
                // simultaneousGesture rather than onTapGesture: a tap gesture inside
                // scrollable content delays trackpad scrolling.
                .simultaneousGesture(
                    TapGesture(count: 2)
                        .onEnded { _ in resetZoom() }
                )
                // Double-click-to-reset is otherwise undiscoverable
                .help("Timeline zoom - double-click to reset to fit")
                .accessibilityLabel("Timeline zoom")

            Button(action: { zoomIn() }) {
                Image(systemName: "plus.magnifyingglass")
                    .font(Typography.bodySmall)
            }
            .buttonStyle(.plain)
            .disabled(zoomLevel >= maxZoom)
            .help("Zoom in")
            .accessibilityLabel("Zoom in")
        }
    }

    // MARK: - Editable Timecode Boxes

    private var startTCBox: some View {
        HStack(spacing: Spacing.xs) {
            Text("Start TC:")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize()

            TransparentTextField(
                text: $editingStartTCText,
                placeholder: "00:00:00:00",
                font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
                onSubmit: {
                    applyStartTimecode()
                },
                onEscape: {
                    editingStartTCText = timeline.config.startTimecode.stringValue()
                },
                isFocused: $isStartTCFocused
            )
            .frame(width: 85)
            .onChangeCompat(of: editingStartTCText) { newValue in
                let formatted = formatTimecodeInput(newValue)
                if formatted != newValue {
                    editingStartTCText = formatted
                }
            }
            .onChangeCompat(of: isStartTCFocused) { focused in
                // Save on blur
                if !focused {
                    applyStartTimecode()
                }
            }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(startTCBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isStartTCFocused ? Color.accentColor : AppColors.borderLight, lineWidth: PanelLayout.borderWidth)
        )
        .onHover { hovering in
            isHoveringStartTC = hovering
        }
        .onAppear {
            editingStartTCText = timeline.config.startTimecode.stringValue()
        }
    }

    private var startTCBackground: Color {
        if isStartTCFocused {
            return Color.red  // DEBUG: Should be RED not blue
        } else if isHoveringStartTC {
            return Color.green  // DEBUG: Should be GREEN on hover
        } else {
            return Color.white.opacity(0.04)
        }
    }

    private var positionBox: some View {
        HStack(spacing: Spacing.xs) {
            Text("Position:")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize()

            TransparentTextField(
                text: $editingPositionText,
                placeholder: "00:00:00:00",
                font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
                onSubmit: {
                    applyPosition()
                },
                onEscape: {
                    editingPositionText = timeline.config.timecode(at: playbackEngine.currentFrame).stringValue()
                },
                isFocused: $isPositionFocused
            )
            .frame(width: 85)
            .onChangeCompat(of: editingPositionText) { newValue in
                let formatted = formatTimecodeInput(newValue)
                if formatted != newValue {
                    editingPositionText = formatted
                }
            }
            .onChangeCompat(of: isPositionFocused) { focused in
                if !focused {
                    applyPosition()
                }
            }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(positionBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isPositionFocused ? Color.accentColor : AppColors.borderLight, lineWidth: PanelLayout.borderWidth)
        )
        .onHover { hovering in
            isHoveringPosition = hovering
        }
        // Follows the playhead the timeline actually draws, which comes from the
        // playback engine. This watched `timelineManager.currentFrame`, which is
        // only ever written by a manual seek - so the field sat at the timeline
        // start for the whole session while the playhead moved without it.
        .onChangeCompat(of: playbackEngine.currentFrame) { frame in
            guard !isPositionFocused else { return }
            editingPositionText = timeline.config.timecode(at: frame).stringValue()
        }
        .onAppear {
            editingPositionText = timeline.config.timecode(at: playbackEngine.currentFrame).stringValue()
        }
    }

    private var positionBackground: Color {
        if isPositionFocused {
            return Color.accentColor.opacity(0.2)
        } else if isHoveringPosition {
            return Color.white.opacity(0.08)
        } else {
            return Color.white.opacity(0.04)
        }
    }

    private var availableFrameRates: [TimecodeFrameRate] {
        [.fps23_976, .fps24, .fps25, .fps29_97, .fps29_97d, .fps30]
    }

    private func changeFrameRate(to newRate: TimecodeFrameRate) {
        var config = timeline.config
        // Convert timecodes to new frame rate
        let startFrames = config.startTimecode.frameCount.wholeFrames
        let endFrames = config.endTimecode.frameCount.wholeFrames
        config.frameRate = newRate
        config.startTimecode = Timecode(.frames(startFrames), at: newRate, by: .clamping)
        config.endTimecode = Timecode(.frames(endFrames), at: newRate, by: .clamping)
        timelineManager.updateConfig(config)
        // Update start TC text field
        editingStartTCText = config.startTimecode.stringValue()
    }

    /// Format timecode input as the user types, inserting colons every 2 digits
    private func formatTimecodeInput(_ input: String) -> String {
        TimecodeEntry.formatted(input)
    }

    private func applyStartTimecode() {
        isStartTCFocused = false
        if let newTC = parseTimecode(editingStartTCText) {
            timelineManager.setTimelineBounds(start: newTC, end: timeline.config.endTimecode)
            editingStartTCText = newTC.stringValue()
        } else {
            // Reset to current value if invalid
            editingStartTCText = timeline.config.startTimecode.stringValue()
        }
    }

    /// The timecode of the playhead the timeline is actually drawing.
    ///
    /// `timelineManager.currentFrame` is only ever written by a manual seek, so
    /// reading it here left the field showing the timeline start.
    private func playheadTimecodeString() -> String {
        timelineManager.timeline.config
            .timecode(at: playbackEngine.currentFrame).stringValue()
    }

    private func applyPosition() {
        isPositionFocused = false
        guard let newTC = parseTimecode(editingPositionText) else {
            // Reset to current value if invalid
            editingPositionText = timeline.config.timecode(at: playbackEngine.currentFrame).stringValue()
            return
        }

        // Calculate the frame offset from timeline start
        let startFrames = timeline.config.startTimecode.frameCount.wholeFrames
        let targetFrames = newTC.frameCount.wholeFrames
        let targetFrame = targetFrames - startFrames

        // Check if target is beyond current duration
        if targetFrame >= timeline.config.durationFrames {
            // Store the pending seek frame and show confirmation
            pendingSeekFrame = targetFrame
            showExtendDurationConfirmation = true
        } else if targetFrame < 0 {
            // Can't seek before timeline start
            editingPositionText = timeline.config.timecode(at: playbackEngine.currentFrame).stringValue()
        } else {
            // Within bounds, seek directly
            timelineManager.seekToFrame(targetFrame)
            onSeek(targetFrame)
            editingPositionText = newTC.stringValue()
        }
    }

    private func confirmExtendAndSeek() {
        guard let targetFrame = pendingSeekFrame else { return }

        // Extend timeline with padding
        let paddingFrames = Int(TimelineManager.defaultPaddingMinutes * 60.0 * timeline.config.frameRate.fps)
        timelineManager.extendTimeline(toEndFrame: targetFrame + paddingFrames)

        // Zoom to fit the new duration
        zoomLevel = minZoom

        // Now seek to the target frame
        timelineManager.seekToFrame(targetFrame)
        onSeek(targetFrame)
        editingPositionText = playheadTimecodeString()

        pendingSeekFrame = nil
    }

    private func parseTimecode(_ string: String) -> Timecode? {
        TimecodeEntry.parse(string, at: timeline.config.frameRate)
    }

    // MARK: - Tracks Section

    private var tracksSection: some View {
        tracksSectionCore
            // Published once for the whole track area: every header shifts by
            // it to stay against the viewport edge while the clips scroll.
            .environment(\.timelineHeaderScrollOffset, horizontalScrollOffset)
    }

    @ViewBuilder
    private var tracksSectionCore: some View {
        GeometryReader { geometry in
            let debug = TimelineDebugFlags.current
            let contentAreaWidth = geometry.size.width - TimelineLayout.headerWidth
            let totalContentWidth = timelineContentWidth(for: geometry.size.width)
            let ppf = pixelsPerFrame(for: geometry.size.width)
            let scrollHeight = max(0, geometry.size.height - TimelineLayout.rulerHeight - 1)
            let audioLanesHeight: CGFloat = {
                if timeline.audioLanes.isEmpty {
                    return TimelineLayout.audioLaneHeight
                }
                let dividers = max(0, timeline.audioLanes.count - 1)
                return (CGFloat(timeline.audioLanes.count) * TimelineLayout.audioLaneHeight) + CGFloat(dividers)
            }()
            let baseTracksHeight = 4 + TimelineLayout.videoTrackHeight + 1 + audioLanesHeight
            let availableNewLaneHeight = max(0, scrollHeight - baseTracksHeight - 8)

            VStack(spacing: 0) {
                // Ruler row. Does not scroll itself, so it is sized to the full
                // zoomed content width and shifted by the scroll offset - the
                // same transform the playhead uses.
                //
                // It previously took whatever width the row gave it and drew the
                // entire duration across that, which made it correct only at
                // fit-to-view. At any other zoom its labels described a
                // different span than the clips beneath it, so the playhead
                // could sit on "1:30:00" while the transport read something else
                // entirely.
                HStack(spacing: 0) {
                    // Part of the header gutter, not the ruler: left clear it
                    // stopped the column short of the panel's top edge.
                    TimelineHeaderColumnBackground()
                        .frame(width: TimelineLayout.headerWidth)

                    let rulerWidth = max(contentAreaWidth, CGFloat(timeline.config.durationFrames) * ppf)
                    let ruler = TimelineRulerView(
                        duration: playbackEngine.duration,
                        frameRate: timeline.config.frameRate,
                        currentTime: playbackEngine.currentTime,
                        startTimecode: timeline.config.startTimecode
                    )
                    .frame(width: rulerWidth, alignment: .leading)
                    .offset(x: -horizontalScrollOffset)
                    .frame(width: contentAreaWidth, alignment: .leading)
                    .clipped()
                    .contentShape(Rectangle())

                    if debug.disableRulerGesture {
                        ruler
                    } else {
                        ruler.gesture(seekGesture(contentAreaWidth: contentAreaWidth))
                    }
                }
                .frame(height: TimelineLayout.rulerHeight)
                .background(Color(white: 0.18))

                Rectangle()
                    .fill(Color(nsColor: .separatorColor).opacity(0.5))
                    .frame(height: 1)

                // Scrollable tracks area (horizontal + vertical)
                ScrollView(scrollAxes, showsIndicators: true) {
                    // Published once here so every track header can hold its
                    // column against the viewport edge as the clips scroll.
                    VStack(spacing: 0) {
                        // Invisible helper to capture NSScrollView reference for auto-scroll
                        ScrollViewCaptureHelper(scrollView: $cachedScrollView)
                            .frame(width: 0, height: 0)

                        Spacer().frame(height: Spacing.xs)

                        // Video File Track: video + linked audio as one unified track
                        videoFileTrack(ppf: ppf, totalContentWidth: totalContentWidth, contentAreaWidth: contentAreaWidth)

                        Divider()

                        // Audio lanes the user added. The video file's own audio
                        // is excluded - it is part of the track above, and would
                        // otherwise appear twice.
                        ForEach(Array(timeline.standaloneAudioLanes.enumerated()), id: \.element.id) { _, lane in
                            let index = timeline.audioLanes.firstIndex(where: { $0.id == lane.id }) ?? 0
                            let isDragging = draggingLaneId == lane.id
                            let displacementOffset = isDragging ? 0 : laneDisplacementOffset(for: index)

                            VStack(spacing: 0) {
                                AudioLaneView(
                                    lane: lane,
                                    laneIndex: index,
                                    activeClipIds: activeAudioClipIds,
                                    waveformCache: waveformCache,
                                    pixelsPerFrame: ppf,
                                    frameRate: timeline.config.frameRate,
                                    scrollOffset: 0,
                                    visibleContentX: visibleContentX(contentAreaWidth: contentAreaWidth),
                                    timelineDurationFrames: timeline.config.durationFrames,
                                    showWaveforms: !debug.disableWaveforms,
                                    clipInteractionsEnabled: !debug.disableClipInteractions && !isDragging,
                                    availableAudioOutputs: audioOutputManager.mappedOutputs,
                                    linkedDragPreview: linkedDragPreview,
                                    timelineStartFrames: timeline.config.startTimecode.frameCount.wholeFrames,
                                    onMuteToggle: { timelineManager.toggleLaneMute(at: index) },
                                    onSoloToggle: { timelineManager.toggleLaneSolo(at: index) },
                                    onVolumeChange: { volume in timelineManager.setLaneVolume(at: index, volume: volume) },
                                    onOutputMappingChange: { output in timelineManager.setLaneOutputMapping(id: lane.id, mapping: output) },
                                    onOutputNone: { timelineManager.disableLaneOutput(id: lane.id) },
                                    onDropMedia: { urls, frame, isInternal in onDropAudioMedia(index, urls, frame, isInternal) },
                                    onDropMixedMedia: onDropMixedMedia,
                                    onClipSelected: { clipId, modifiers in
                                        handleClipSelection(clipId: clipId, laneId: lane.id, modifiers: modifiers)
                                    },
                                    onClipDoubleClick: { clip in
                                        editingClipId = clip.id
                                        editingLaneId = lane.id
                                        let tc = Timecode(.frames(clip.timelineStartFrame + timeline.config.startTimecode.frameCount.wholeFrames), at: timeline.config.frameRate, by: .clamping)
                                        timecodeEntryText = tc.stringValue()
                                        showTimecodeEntryDialog = true
                                    },
                                    onClipSetTimelineStart: { clip in
                                        timelineManager.setTimelineStart(toFrame: clip.timelineStartFrame)
                                    },
                                    onClipMove: { clipId, newFrame in
                                        guard let lane = timelineManager.timeline.audioLanes.first(where: { $0.id == lane.id }),
                                              let clip = lane.clips.first(where: { $0.id == clipId }),
                                              clip.timelineStartFrame != newFrame else { return }
                                        registerAudioClipMoveUndo(clipId: clipId, laneId: lane.id, from: clip.timelineStartFrame)
                                        timelineManager.moveAudioClip(clipId: clipId, inLane: lane.id, to: newFrame)
                                    },
                                    onClipDragPreview: { clip, previewFrame in
                                        guard clip.sourceType == .videoTrack else {
                                            if linkedDragPreview != nil {
                                                linkedDragPreview = nil
                                            }
                                            return
                                        }
                                        if let previewFrame {
                                            linkedDragPreview = LinkedDragPreview(
                                                sourceURL: clip.sourceURL,
                                                sourceStartFrame: clip.sourceStartFrame,
                                                durationFrames: clip.durationFrames,
                                                fromFrame: clip.timelineStartFrame,
                                                toFrame: previewFrame
                                            )
                                        } else {
                                            linkedDragPreview = nil
                                        }
                                    },
                                    onLaneRename: { newName in
                                        timelineManager.renameAudioLane(id: lane.id, name: newName)
                                    },
                                    onDeleteLane: {
                                        // Snapshot-based undo, so a lane deleted
                                        // with clips on it comes back intact.
                                        registerTimelineUndo(actionName: "Delete Lane")
                                        timelineManager.removeAudioLane(id: lane.id)
                                    },
                                    onClipLaneChangeRequested: { clipId, laneOffset in
                                        // Move video-linked audio clip to adjacent lane
                                        let currentIndex = index
                                        let targetIndex = currentIndex + laneOffset
                                        guard targetIndex >= 0 && targetIndex < timeline.audioLanes.count else { return }
                                        let targetLane = timeline.audioLanes[targetIndex]

                                        // Check if clip would overlap in target lane
                                        if let clip = lane.clips.first(where: { $0.id == clipId }) {
                                            if !targetLane.hasOverlap(with: clip) {
                                                timelineManager.moveAudioClipToLane(
                                                    clipId: clipId,
                                                    fromLane: lane.id,
                                                    toLane: targetLane.id
                                                )
                                            }
                                        }
                                        // Clear preview after move
                                        laneChangePreview = nil
                                    },
                                    onClipLaneChangePreview: { clip, laneOffset in
                                        guard let offset = laneOffset else {
                                            // Clear preview
                                            laneChangePreview = nil
                                            return
                                        }
                                        let targetIndex = index + offset
                                        guard targetIndex >= 0 && targetIndex < timeline.audioLanes.count else {
                                            laneChangePreview = nil
                                            return
                                        }
                                        let targetLane = timeline.audioLanes[targetIndex]
                                        let isValid = !targetLane.hasOverlap(with: clip)
                                        laneChangePreview = LaneChangePreview(
                                            clipId: clip.id,
                                            timelineStartFrame: clip.timelineStartFrame,
                                            durationFrames: clip.durationFrames,
                                            sourceLaneIndex: index,
                                            targetLaneIndex: targetIndex,
                                            isValidDrop: isValid
                                        )
                                    },
                                    laneChangePreview: laneChangePreview,
                                    selectedClipIds: selectedAudioClipIds
                                )
                                .frame(width: totalContentWidth, height: TimelineLayout.audioLaneHeight)
                                // Drag handle covers header except controls row at bottom
                                // Full header width, top portion only (lane name row)
                                .overlay(alignment: .topLeading) {
                                    Color.white.opacity(0.001)
                                        .frame(width: TimelineLayout.headerWidth, height: 40)
                                        .contentShape(Rectangle())
                                        .allowsHitTesting(true)
                                        // This invisible handle lies over the lane
                                        // name - the obvious place to right-click a
                                        // lane - and a transparent Color with no
                                        // menu of its own swallowed the click, so
                                        // the lane's own context menu underneath
                                        // never saw it. Deleting a lane by
                                        // right-clicking its name simply stopped
                                        // working when this handle arrived.
                                        .contextMenu {
                                            Button(lane.deleteMenuTitle, role: .destructive) {
                                                registerTimelineUndo(actionName: "Delete Lane")
                                                timelineManager.removeAudioLane(id: lane.id)
                                            }
                                        }
                                        // ORDER IS LOAD-BEARING: the gesture must be
                                        // applied *after* `.contextMenu`, so that it
                                        // sits outside it and sees mouse events first.
                                        // Applied before, the context menu wraps the
                                        // gesture and swallows the whole stream - the
                                        // long press never fires, so the cursor does
                                        // not even change and reordering is dead.
                                        // That shipped in 2f29e8b: the right-click fix
                                        // silently cost the drag. The two survive
                                        // together only because a long press and a
                                        // drag are primary-button gestures, so a
                                        // right-click still falls through to the menu.
                                        .highPriorityGesture(laneReorderGesture(laneId: lane.id, laneIndex: index))
                                }
                                .overlay(alignment: .bottom) {
                                    if index == timeline.audioLanes.count - 1 {
                                        laneBorder
                                    }
                                }
                                // Visual feedback when dragging - neon green overlay
                                .overlay {
                                    if isDragging {
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(Color(red: 0.0, green: 1.0, blue: 0.0).opacity(0.25))
                                            .overlay {
                                                RoundedRectangle(cornerRadius: 4)
                                                    .stroke(Color(red: 0.0, green: 1.0, blue: 0.0), lineWidth: 2)
                                            }
                                    }
                                }
                                .offset(y: isDragging ? draggingLaneOffset : displacementOffset)
                                .zIndex(isDragging ? 100 : 0)
                                .animation(isDragging ? nil : AppAnimations.quick, value: displacementOffset)
                            }

                            if index < timeline.audioLanes.count - 1 {
                                Divider()
                            }
                        }

                        if timeline.audioLanes.isEmpty {
                            emptyAudioLanesPlaceholder(pixelsPerFrame: ppf, laneIndex: 0)
                                .frame(width: totalContentWidth)
                                .overlay(alignment: .bottom) {
                                    laneBorder
                                }
                        } else {
                            newAudioLaneDropZone(
                                pixelsPerFrame: ppf,
                                laneIndex: timeline.audioLanes.count,
                                availableHeight: availableNewLaneHeight
                            )
                                .frame(width: totalContentWidth)
                                .overlay(alignment: .bottom) {
                                    laneBorder
                                }
                        }

                        // Bottom padding
                        Spacer().frame(height: Spacing.sm)
                    }
                    // Top-aligned. `.frame(minHeight:)` centres by default, so
                    // on an empty project - a video track and the "no audio
                    // lanes" placeholder, well short of the scroll height - the
                    // tracks floated in the middle of the panel with a gap
                    // under the ruler.
                    .frame(minHeight: scrollHeight, alignment: .top)
                    // Marquee selection gesture on scroll content
                    // Using simultaneousGesture so it doesn't block scrolling
                    // Requires Option key to activate
                    .simultaneousGesture(marqueeSelectionGesture(pixelsPerFrame: ppf))
                }
            }
            // The width the zoom curve above was computed from. `onAppear` sets
            // the first value, which `onChange` alone would never deliver.
            .onAppear { trackAreaWidth = geometry.size.width }
            .onChangeCompat(of: geometry.size.width) { trackAreaWidth = $0 }
            // Playhead overlay spanning full height
            .overlay(alignment: .topLeading) {
                playhead(pixelsPerFrame: ppf, totalHeight: geometry.size.height)
                    .allowsHitTesting(false)
            }
            // No whole-timeline drop highlight: drops are handled per lane, and
            // the parent drag capture deliberately never claims them. Lighting
            // the whole track area would promise a drop the timeline refuses.
            // DragTracker: tracks external drag item count for multi-file overlay visibility.
            // NEVER claims drags - always returns [] so child views handle all drops.
            // Uses .background so it's BEHIND children in z-order.
            .background {
                DragCaptureView(
                    onEntered: { info, _ in
                        // Track external drag item count for overlay visibility
                        if dragContext.mediaItems.isEmpty {
                            let pasteboardItems = info.draggingPasteboard.pasteboardItems ?? []
                            externalDragItemCount = pasteboardItems.count
                        }
                        // NEVER claim drags - let children handle everything
                        return []
                    },
                    onUpdated: { info, _ in
                        // Keep tracking count
                        if dragContext.mediaItems.isEmpty {
                            let pasteboardItems = info.draggingPasteboard.pasteboardItems ?? []
                            externalDragItemCount = pasteboardItems.count
                        } else {
                            // Drag is still live - keep the context from timing out
                            dragContext.refresh()
                        }
                        return []
                    },
                    onExited: {
                        externalDragItemCount = 0
                    },
                    onPerform: { _, _ in
                        // Never handle drops - children do
                        false
                    }
                )
            }
            .coordinateSpace(name: "timelineTracks")
            // Marquee selection overlay (rendered above everything)
            .overlay {
                if isMarqueeSelecting {
                    marqueeSelectionRectangle
                }
            }
        }
    }

    /// Marquee selection gesture for selecting multiple clips
    /// Uses simultaneousGesture so it doesn't block scrolling
    /// Includes auto-scroll when cursor is near scroll view edges
    private func marqueeSelectionGesture(pixelsPerFrame: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named("timelineTracks"))
            .onChanged { value in
                // Don't start marquee during multi-file drag operations
                guard !isMultiFileDrag, externalDragItemCount == 0 else { return }

                // Don't start marquee if drag started in header area (lane reorder zone)
                guard value.startLocation.x >= TimelineLayout.headerWidth else { return }

                if !isMarqueeSelecting {
                    // Start marquee selection
                    isMarqueeSelecting = true
                    marqueeStartPoint = value.startLocation
                    // Clear selection if not holding shift
                    if !NSEvent.modifierFlags.contains(.shift) {
                        clearSelection()
                    }
                    // Start auto-scroll timer
                    startAutoScrollTimer(pixelsPerFrame: pixelsPerFrame)
                }
                marqueeCurrentPoint = value.location
                updateMarqueeSelection(pixelsPerFrame: pixelsPerFrame)
            }
            .onEnded { _ in
                isMarqueeSelecting = false
                stopAutoScrollTimer()
            }
    }

    // MARK: - Auto-Scroll During Marquee Selection

    /// Start the auto-scroll timer for marquee selection
    private func startAutoScrollTimer(pixelsPerFrame: CGFloat) {
        stopAutoScrollTimer()

        // Use Timer on main run loop - properly cancelled on drag end
        let timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in
            // Timer callback on main thread - check state and scroll
            Task { @MainActor in
                performAutoScrollIfNeeded(pixelsPerFrame: pixelsPerFrame)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoScrollTimer = timer
    }

    /// Stop the auto-scroll timer
    private func stopAutoScrollTimer() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
    }

    /// Perform auto-scroll based on cursor position relative to scroll view bounds
    ///
    /// This function:
    /// 1. Uses the cached NSScrollView reference (not fragile hierarchy search)
    /// 2. Checks cursor proximity to scroll view edges
    /// 3. Scrolls programmatically when near edges
    /// 4. Does NOT update marqueeCurrentPoint - the gesture will naturally
    ///    provide updated coordinates on the next onChanged call
    private func performAutoScrollIfNeeded(pixelsPerFrame: CGFloat) {
        guard isMarqueeSelecting else { return }

        // Use cached scroll view reference
        guard let scrollView = cachedScrollView else { return }

        let clipView = scrollView.contentView
        var currentOrigin = clipView.bounds.origin
        let contentSize = scrollView.documentView?.frame.size ?? .zero
        let visibleSize = clipView.bounds.size

        // Get cursor position in screen coordinates and convert to scroll view
        let mouseScreenLocation = NSEvent.mouseLocation
        let mouseWindowLocation = scrollView.window?.convertPoint(fromScreen: mouseScreenLocation) ?? .zero
        let mouseInScrollView = scrollView.convert(mouseWindowLocation, from: nil)

        // Calculate scroll deltas based on cursor proximity to edges
        var deltaX: CGFloat = 0
        var deltaY: CGFloat = 0

        // Horizontal edge detection
        // Note: NSScrollView uses flipped coordinates by default in SwiftUI hosting
        if mouseInScrollView.x < autoScrollEdgeInset && mouseInScrollView.x >= 0 {
            // Near left edge - scroll left
            deltaX = -autoScrollSpeed
        } else if mouseInScrollView.x > scrollView.bounds.width - autoScrollEdgeInset &&
                  mouseInScrollView.x <= scrollView.bounds.width {
            // Near right edge - scroll right
            deltaX = autoScrollSpeed
        }

        // Vertical edge detection
        // NSView coordinates: Y increases upward, but SwiftUI's hosting view may be flipped
        let scrollViewHeight = scrollView.bounds.height
        if mouseInScrollView.y < autoScrollEdgeInset && mouseInScrollView.y >= 0 {
            // Near bottom edge (in NSView coords) - scroll down
            deltaY = -autoScrollSpeed
        } else if mouseInScrollView.y > scrollViewHeight - autoScrollEdgeInset &&
                  mouseInScrollView.y <= scrollViewHeight {
            // Near top edge (in NSView coords) - scroll up
            deltaY = autoScrollSpeed
        }

        // Apply scroll with bounds checking
        if deltaX != 0 || deltaY != 0 {
            let maxScrollX = max(0, contentSize.width - visibleSize.width)
            let maxScrollY = max(0, contentSize.height - visibleSize.height)

            currentOrigin.x = max(0, min(currentOrigin.x + deltaX, maxScrollX))
            currentOrigin.y = max(0, min(currentOrigin.y + deltaY, maxScrollY))

            // Animate the scroll for smoother visual feedback
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.03
                context.allowsImplicitAnimation = true
                clipView.setBoundsOrigin(currentOrigin)
            }

            // IMPORTANT: Do NOT update marqueeCurrentPoint here!
            // The gesture's onChanged handler will naturally receive updated
            // coordinates on the next event, which properly accounts for
            // the new scroll position in the coordinate space.
        }
    }

    // Multi-file drops are routed by the per-lane handlers; the parent
    // DragCaptureView never claims a drop (see its onPerform above). A handler
    // here would have to honour the cursor position, not assume frame 0.

    /// The playhead, positioned in the scrolled content's coordinate space.
    ///
    /// This overlay lives *outside* the tracks ScrollView, so a position derived
    /// only from `currentFrame` is a document coordinate, not a screen one.
    /// Subtracting the scroll offset is what converts it. Without that the two
    /// only agree at fit-to-view - where the content exactly fills the viewport
    /// and the offset is always 0 - which is why the playhead tracked the
    /// transport at the old default zoom and flew off screen at any other.
    ///
    /// Hidden when it falls outside the track area rather than being clamped to
    /// the edge: a playhead parked against the frame would read as a real
    /// position and misreport where the transport actually is.
    @ViewBuilder
    private func playhead(pixelsPerFrame: CGFloat, totalHeight: CGFloat) -> some View {
        // Use separate view to avoid re-rendering entire tracksSection on every frame
        PlayheadView(
            playbackEngine: playbackEngine,
            pixelsPerFrame: pixelsPerFrame,
            horizontalScrollOffset: horizontalScrollOffset,
            totalHeight: totalHeight
        )
    }

    /// Keep the moving playhead on screen.
    ///
    /// Without this the timeline only showed the playhead moving while it
    /// happened to be inside the visible span: zoom in far enough for motion to
    /// be legible and the playhead leaves the viewport within seconds, never to
    /// return. Following it is what makes "receives MTC and moves the playhead"
    /// observable rather than merely true.
    ///
    /// Scale is read back off the scroll view's own document width instead of
    /// the layout's `pixelsPerFrame`, because that width is the one thing here
    /// that already encodes the current zoom without needing the geometry width
    /// plumbed out of the `GeometryReader`.

    // MARK: - Video File Track (Unified)

    /// Video file track: the video and the audio baked into it, as one track.
    ///
    /// Built as rows rather than as two tall columns. Each row is its own
    /// `HStack` of header block and content block, and the rows are separated by
    /// the same `laneBorder` used between ordinary audio lanes.
    ///
    /// The earlier shape - one full-height header beside one `VStack` of content
    /// - could not be separated: a divider inside the content column stops at
    /// the header, and nothing tied the two columns' vertical rhythm together,
    /// so the header controls drifted out of register with the strips they
    /// drive. Pairing each header with its own content makes alignment
    /// structural and lets one separator span the whole width.
    @ViewBuilder
    private func videoFileTrack(ppf: CGFloat, totalContentWidth: CGFloat, contentAreaWidth: CGFloat) -> some View {
        let linkedLanes = isVideoAudioExpanded ? timeline.videoAudioLanes : []
        let contentWidth = totalContentWidth - TimelineLayout.headerWidth
        let totalHeight = TimelineLayout.videoTrackHeight
            + CGFloat(linkedLanes.count) * (TimelineLayout.linkedAudioStripHeight + TimelineLayout.laneSeparatorHeight)

        VStack(spacing: 0) {
            HStack(spacing: 0) {
                videoInfoBlock
                    .frame(width: TimelineLayout.headerWidth, height: TimelineLayout.videoTrackHeight)
                    .background(headerColumnBackground)
                    // Held against the viewport edge while the track scrolls
                    // under it. Visual only - the row still reserves the column.
                    .offset(x: horizontalScrollOffset)
                    .zIndex(1)

                videoRowContent(ppf: ppf, width: contentWidth, contentAreaWidth: contentAreaWidth)
            }

            ForEach(linkedLanes) { linked in
                if let index = timeline.audioLanes.firstIndex(where: { $0.id == linked.id }) {
                    laneBorder

                    HStack(spacing: 0) {
                        linkedAudioHeaderBlock(lane: linked, index: index)
                            .frame(
                                width: TimelineLayout.headerWidth,
                                height: TimelineLayout.linkedAudioStripHeight
                            )
                            .background(headerColumnBackground)
                            .offset(x: horizontalScrollOffset)
                            .zIndex(1)

                        linkedAudioContent(
                            lane: linked,
                            index: index,
                            ppf: ppf,
                            width: contentWidth
                        )
                    }
                }
            }
        }
        .frame(width: totalContentWidth, height: totalHeight)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.3))
        .overlay(alignment: .top) {
            laneBorder
        }
    }

    private var headerColumnBackground: some View {
        TimelineHeaderColumnBackground()
    }

    /// The video reels themselves, with the lane header suppressed.
    private func videoRowContent(ppf: CGFloat, width: CGFloat, contentAreaWidth: CGFloat) -> some View {
        VideoTrackView(
            timelineManager: timelineManager,
            playbackEngine: playbackEngine,
            thumbnailCache: thumbnailCache,
            pixelsPerFrame: ppf,
            visibleContentX: visibleContentX(contentAreaWidth: contentAreaWidth),
            scrollOffset: 0,
            showThumbnails: !TimelineDebugFlags.current.disableThumbnails,
            clipInteractionsEnabled: !TimelineDebugFlags.current.disableClipInteractions,
            onDropMedia: { urls, frame, isInternal in onDropVideoMedia(urls, frame, isInternal) },
            onDropMixedMedia: onDropMixedMedia,
            onReelSelected: { reelId, modifiers in
                if let id = reelId {
                    handleReelSelection(reelId: id, modifiers: modifiers)
                }
            },
            onReelDoubleClick: { reel in
                editingReelId = reel.id
                let tc = Timecode(.frames(reel.timelineStartFrame + timeline.config.startTimecode.frameCount.wholeFrames), at: timeline.config.frameRate, by: .clamping)
                timecodeEntryText = tc.stringValue()
                showTimecodeEntryDialog = true
            },
            onReelMove: { reelId, newFrame in
                if let oldFrame = timeline.videoReels.first(where: { $0.id == reelId })?.timelineStartFrame,
                   oldFrame != newFrame {
                    registerVideoReelMoveUndo(reelId: reelId, from: oldFrame)
                }
                timelineManager.moveVideoReel(id: reelId, to: newFrame)
            },
            linkedDragPreview: linkedDragPreview,
            onReelDragPreview: { reel, frame in
                if let f = frame {
                    linkedDragPreview = LinkedDragPreview(
                        sourceURL: reel.sourceURL,
                        sourceStartFrame: 0,
                        durationFrames: reel.durationFrames,
                        fromFrame: reel.timelineStartFrame,
                        toFrame: f
                    )
                } else {
                    linkedDragPreview = nil
                }
            },
            selectedReelIds: selectedVideoReelIds,
            showsHeader: false
        )
        .frame(width: width, height: TimelineLayout.videoTrackHeight)
    }

    /// Header for one of the video's audio lanes.
    ///
    /// Named when there are multiple audio tracks (split channels or multi-track
    /// video) so the user can tell them apart. A lone lane is unambiguously "the
    /// video's audio" and a label would just crowd the controls.
    private func linkedAudioHeaderBlock(lane: AudioLane, index: Int) -> some View {
        laneHeaderLayout(accent: LaneColor.color(forLaneIndex: index)) {
            // Show name when there are multiple video audio lanes:
            // - Split channels (hard-panned audio)
            // - Multi-track video (discrete audio tracks)
            if lane.splitChannel != nil || timeline.videoAudioLanes.count > 1 {
                Text(lane.name)
                    .font(Typography.subheading)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            AudioLaneControls(
                lane: lane,
                availableAudioOutputs: audioOutputManager.mappedOutputs,
                onMuteToggle: { timelineManager.toggleLaneMute(at: index) },
                onSoloToggle: { timelineManager.toggleLaneSolo(at: index) },
                onOutputMappingChange: { output in
                    timelineManager.setLaneOutputMapping(id: lane.id, mapping: output)
                },
                onOutputNone: { timelineManager.disableLaneOutput(id: lane.id) }
            )
        }
    }

    /// The shape every header block in this track shares.
    ///
    /// A colour stripe on the leading edge, then the block's own content inset
    /// from it. The stripe is what ties a header to its clips - it is the colour
    /// their waveforms are drawn in - and it gives the column a left edge to
    /// align against instead of text floating in a panel.
    private func laneHeaderLayout<Content: View>(
        accent: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(accent)
                .frame(width: TimelineLayout.laneAccentWidth)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                content()
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
    }

    /// Video name and frame rate, centred in the video row.
    @ViewBuilder
    private var videoInfoBlock: some View {
        laneHeaderLayout(accent: AppColors.textTertiary) {
            // Video info with editable name
            if let reel = timelineManager.timeline.videoReels.first {
                let trackName = reel.name ?? "Video"

                // Editable track name
                if isEditingVideoName {
                    TextField("", text: $editedVideoName)
                        .font(Typography.subheading)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.leading)
                        .focused($isVideoNameFieldFocused)
                        .onSubmit { commitVideoNameEdit(for: reel) }
                        .onExitCommand { cancelVideoNameEdit(for: reel) }
                        .onChangeCompat(of: isVideoNameFieldFocused) { focused in
                            if !focused && isEditingVideoName {
                                commitVideoNameEdit(for: reel)
                            }
                        }
                        .frame(maxWidth: TimelineLayout.headerWidth - Spacing.md * 2)
                        .padding(.horizontal, Spacing.xs)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.3))
                        .cornerRadius(4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.accentColor, lineWidth: 1)
                        )
                } else {
                    Button(action: {}) {
                        Text(trackName)
                            .font(Typography.subheading)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(
                        TapGesture(count: 2).onEnded { _ in startVideoNameEdit(for: reel) }
                    )
                    .help("\(trackName) - double-click to rename")
                }

                // FPS and playback state
                HStack(spacing: Spacing.sm) {
                    videoHeaderFpsControl
                    videoHeaderPlaybackIndicator
                }
            } else {
                Text("Video")
                    .font(Typography.subheading)
                    .foregroundColor(.primary)

                // FPS and playback state (shown even without video)
                HStack(spacing: Spacing.sm) {
                    videoHeaderFpsControl
                    videoHeaderPlaybackIndicator
                }
            }
        }
    }

    /// Play/stop indicator for video lane header
    private var videoHeaderPlaybackIndicator: some View {
        Image(systemName: playbackEngine.isPlaying ? "play.fill" : "stop.fill")
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(playbackEngine.isPlaying ? AppColors.accentGreen : .secondary)
    }

    /// FPS dropdown for video lane header - simple gray text
    private var videoHeaderFpsControl: some View {
        HStack(spacing: Spacing.xs) {
            Text("FPS")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)

            Menu {
                ForEach(availableFrameRates, id: \.self) { rate in
                    Button(rate.displayName) {
                        changeFrameRate(to: rate)
                    }
                }
            } label: {
                Text(timeline.config.frameRate.displayName)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
    }

    private func startVideoNameEdit(for reel: VideoReel) {
        editedVideoName = reel.name ?? "Video"
        isEditingVideoName = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            isVideoNameFieldFocused = true
        }
    }

    private func commitVideoNameEdit(for reel: VideoReel) {
        guard isEditingVideoName else { return }
        isEditingVideoName = false

        let trimmed = editedVideoName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != reel.displayName {
            timelineManager.renameVideoReel(id: reel.id, name: trimmed)
        }
    }

    private func cancelVideoNameEdit(for reel: VideoReel) {
        isEditingVideoName = false
        editedVideoName = reel.name ?? "Video"
    }

    /// Video reels content (no header, just the clips).
    /// Span of timeline content the viewport can show, in content points.
    ///
    /// - Parameter contentAreaWidth: Width of the track area, headers excluded.
    /// - Returns: The visible span, measured from the start of the content.
    private func visibleContentX(contentAreaWidth: CGFloat) -> ClosedRange<CGFloat> {
        let start = max(0, horizontalScrollOffset)
        return start...(start + max(1, contentAreaWidth))
    }

    /// That span expressed relative to a clip's leading edge.
    ///
    /// Clips draw only the part of themselves the window can reach; without
    /// this a zoomed-in reel builds a filmstrip cell for every 48 points of its
    /// full width, which at feature length is thousands of JPEG decodes per
    /// layout pass.
    ///
    /// - Parameters:
    ///   - startFrame: The clip's first timeline frame.
    ///   - ppf: Points per frame at the current zoom.
    ///   - contentAreaWidth: Width of the track area, headers excluded.
    /// - Returns: The visible span in clip-local points.
    private func visibleXRange(
        forReelStartingAt startFrame: Int,
        ppf: CGFloat,
        contentAreaWidth: CGFloat
    ) -> ClosedRange<CGFloat> {
        let visible = visibleContentX(contentAreaWidth: contentAreaWidth)
        let clipStart = CGFloat(startFrame) * ppf
        let lower = visible.lowerBound - clipStart
        let upper = visible.upperBound - clipStart
        return min(lower, upper)...max(lower, upper)
    }

    private func videoFileTrackContent(ppf: CGFloat, width: CGFloat, contentAreaWidth: CGFloat) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                DustyBackground()

                ForEach(timelineManager.timeline.sortedVideoReels) { reel in
                    VideoReelClipView(
                        reel: reel,
                        isActive: playbackEngine.activeReel?.id == reel.id,
                        pixelsPerFrame: ppf,
                        thumbnailCache: thumbnailCache,
                        showThumbnails: !TimelineDebugFlags.current.disableThumbnails,
                        isSelected: selectedVideoReelIds.contains(reel.id),
                        interactionsEnabled: !TimelineDebugFlags.current.disableClipInteractions,
                        timelineStartTimecode: timelineManager.formatTimecode(forFrame: reel.timelineStartFrame),
                        visibleXRange: visibleXRange(forReelStartingAt: reel.timelineStartFrame, ppf: ppf, contentAreaWidth: contentAreaWidth),
                        onSelect: { modifiers in
                            handleReelSelection(reelId: reel.id, modifiers: modifiers)
                        },
                        onDoubleClick: {
                            editingReelId = reel.id
                            let tc = Timecode(.frames(reel.timelineStartFrame + timeline.config.startTimecode.frameCount.wholeFrames), at: timeline.config.frameRate, by: .clamping)
                            timecodeEntryText = tc.stringValue()
                            showTimecodeEntryDialog = true
                        },
                        onSetTimelineStart: {
                            timelineManager.setTimelineStart(toFrame: reel.timelineStartFrame)
                        }
                    )
                    .offset(x: CGFloat(reel.timelineStartFrame) * ppf)
                }
            }
        }
        .frame(width: width, height: TimelineLayout.videoTrackHeight)
    }

    /// Linked audio content (waveform only, no header).
    private func linkedAudioContent(lane: AudioLane, index: Int, ppf: CGFloat, width: CGFloat) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                DustyBackground()

                ForEach(lane.clips) { clip in
                    AudioClipView(
                        clip: clip,
                        lane: lane,
                        laneIndex: index,
                        isActive: activeAudioClipIds.contains(clip.id),
                        pixelsPerFrame: ppf,
                        frameRate: timeline.config.frameRate,
                        isSelected: selectedAudioClipIds.contains(clip.id),
                        waveformCache: waveformCache,
                        showWaveform: !TimelineDebugFlags.current.disableWaveforms,
                        interactionsEnabled: !TimelineDebugFlags.current.disableClipInteractions,
                        timelineStartTimecode: nil,
                        onSelect: { modifiers in
                            handleClipSelection(clipId: clip.id, laneId: lane.id, modifiers: modifiers)
                        },
                        onDoubleClick: {},
                        onSetTimelineStart: {
                            timelineManager.setTimelineStart(toFrame: clip.timelineStartFrame)
                        },
                        clipHeight: TimelineLayout.audioClipHeight
                    )
                    .offset(
                        x: CGFloat(clip.timelineStartFrame) * ppf,
                        y: (TimelineLayout.linkedAudioStripHeight - TimelineLayout.audioClipHeight) / 2
                    )
                }
            }
        }
        .frame(width: width, height: TimelineLayout.linkedAudioStripHeight)
    }

    /// The video file's baked-in audio, as a short strip under the picture.
    ///
    /// Reuses `AudioLaneView` at a third height with its header suppressed, so
    /// clips, waveforms and selection behave exactly as they do on any lane -
    /// only the chrome differs.
    /// Remove the video reels and the audio baked into them, together.
    private func deleteVideoFileTrack() {
        registerTimelineUndo(actionName: "Delete Video File")
        for reel in timelineManager.timeline.videoReels {
            removeLinkedAudio(for: reel, cleanupLanes: false)
            // A split lane is shared by every split reel, so only this reel's
            // clips go; the lane follows if that empties it. Removing the lane
            // outright would take the other reels' audio with it.
            timelineManager.removeLanesOwned(byReel: reel.id, sourceURL: reel.sourceURL)
            timelineManager.removeVideoReel(id: reel.id)
        }
        removeEmptyAudioLanes()
    }

    private func scrollPlayheadIntoViewIfNeeded() {
        guard playbackEngine.isPlaying,
              let scrollView = cachedScrollView else { return }

        let clipView = scrollView.contentView
        let documentWidth = scrollView.documentView?.frame.width ?? 0
        let visible = clipView.bounds
        guard documentWidth > visible.width, visible.width > 0 else { return }

        let durationFrames = max(1, timeline.config.durationFrames)
        let ppf = (documentWidth - TimelineLayout.headerWidth) / CGFloat(durationFrames)
        guard ppf > 0 else { return }

        let playheadX = TimelineLayout.headerWidth + CGFloat(playbackEngine.currentFrame) * ppf
        let inset = min(TimelineLayout.playheadFollowInset, visible.width / 4)
        guard playheadX < visible.minX + inset || playheadX > visible.maxX - inset else { return }

        // Recentre rather than nudge to the edge, so a jump (MMC locate, a click
        // elsewhere on the ruler) lands somewhere with context around it.
        var origin = visible.origin
        origin.x = max(0, min(playheadX - visible.width / 2, documentWidth - visible.width))
        clipView.setBoundsOrigin(origin)
        scrollView.reflectScrolledClipView(clipView)
    }

    /// Seek by converting the click position straight through the same
    /// pixels-per-frame used to lay out clips and the playhead.
    ///
    /// Previously re-derived the zoom multiplier inline with its own copy of
    /// the old linear formula, so any change to the zoom curve silently put
    /// clicks on a different frame than the one under the cursor. Deriving the
    /// scale from `pixelsPerFrame` keeps seek, layout and playhead on one
    /// definition.
    private func seekGesture(contentAreaWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let availableWidth = contentAreaWidth + TimelineLayout.headerWidth
                let ppf = pixelsPerFrame(for: availableWidth)
                guard ppf > 0 else { return }
                // The gesture reports screen coordinates within the ruler's
                // visible strip; adding the scroll offset converts back to the
                // document space frames are measured in.
                let frame = Int((value.location.x + horizontalScrollOffset) / ppf)
                onSeek(max(0, min(frame, timeline.config.durationFrames - 1)))
            }
    }


    /// Hairline between one track row and the next.
    ///
    /// Full strength: at half opacity it disappeared against the header gutter,
    /// so a split video's two lanes ran together as one block.
    private var laneBorder: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: TimelineLayout.laneSeparatorHeight)
    }

    private var tracksHeight: CGFloat {
        let audioHeight = max(50, CGFloat(timeline.audioLanes.count) * (TimelineLayout.audioLaneHeight + 1))
        return TimelineLayout.videoTrackHeight + 1 + audioHeight + 8 // +8 for bottom padding
    }

    private func emptyAudioLanesPlaceholder(pixelsPerFrame: CGFloat, laneIndex: Int) -> some View {
        let adjustLocation: (CGPoint) -> CGPoint = { location in
            CGPoint(x: max(0, location.x - TimelineLayout.headerWidth), y: location.y)
        }

        return HStack(spacing: 0) {
            // Header area - clearly show this is an empty state, not a lane
            Color.clear
                .frame(width: TimelineLayout.headerWidth, height: TimelineLayout.audioLaneHeight)
                .overlay(
                    VStack(spacing: Spacing.xs) {
                        Image(systemName: "speaker.slash")
                            .font(Typography.body)
                            .foregroundColor(.secondary.opacity(0.4))

                        Text("No audio")
                            .font(Typography.captionSmall)
                            .foregroundColor(.secondary.opacity(0.4))

                        Text("lanes")
                            .font(Typography.captionSmall)
                            .foregroundColor(.secondary.opacity(0.4))
                    }
                )

            // Empty content area with drop prompt
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Subtle striped pattern to indicate empty state
                    Color.clear
                        .background(
                            Color(nsColor: .controlBackgroundColor).opacity(0.3)
                        )
                        .overlay(
                            Rectangle()
                                .stroke(
                                    Color.secondary.opacity(0.1),
                                    style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                                )
                                .padding(Spacing.xs)
                        )

                    HStack(spacing: Spacing.sm) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 16))
                            .foregroundColor(.secondary.opacity(0.4))

                        Text("Click \"+Audio Lane\" to add a lane, or drop audio files here")
                            .font(Typography.caption)
                            .foregroundColor(.secondary.opacity(0.5))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // Show preview for all drops (single and multi-file)
                    if (isEmptyAudioDropAllowed || isEmptyAudioDropLoading),
                       let previewFrame = emptyAudioDropPreviewFrame {
                        emptyAudioDropPreviewOverlay(
                            frame: previewFrame,
                            height: geometry.size.height,
                            width: geometry.size.width,
                            pixelsPerFrame: pixelsPerFrame
                        )
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .overlay {
            DragCaptureView(
                onEntered: { info, location in
                    handleNewLaneDragEntered(info: info, location: adjustLocation(location), pixelsPerFrame: pixelsPerFrame)
                    return .copy  // Accept all drops for new lane creation
                },
                onUpdated: { info, location in
                    handleNewLaneDragUpdated(info: info, location: adjustLocation(location), pixelsPerFrame: pixelsPerFrame)
                },
                onExited: {
                    clearEmptyAudioDrop()
                },
                onPerform: { info, location in
                    handleNewLanePerformDrop(info: info, location: adjustLocation(location), pixelsPerFrame: pixelsPerFrame, laneIndex: laneIndex)
                }
            )
        }
        .frame(height: TimelineLayout.audioLaneHeight)
    }

    private func newAudioLaneDropZone(
        pixelsPerFrame: CGFloat,
        laneIndex: Int,
        availableHeight: CGFloat
    ) -> some View {
        let adjustLocation: (CGPoint) -> CGPoint = { location in
            CGPoint(x: max(0, location.x - TimelineLayout.headerWidth), y: location.y)
        }
        let isActive = isEmptyAudioDropAllowed || isEmptyAudioDropLoading
        let baseHeight = max(TimelineLayout.audioLaneHeight, availableHeight, newLaneDropInactiveHeight)

        return HStack(spacing: 0) {
            Color.clear
                .frame(width: TimelineLayout.headerWidth)
                .background(isActive ? Color(nsColor: .controlBackgroundColor).opacity(0.6) : Color.clear)
                .overlay(
                    VStack(spacing: Spacing.xs) {
                        Text("New Lane")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.secondary)
                        Image(systemName: "waveform.badge.plus")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                    .opacity(isActive ? 1 : 0)
                )

            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    if isActive {
                        DustyBackground()
                    }

                    if isActive {
                        VStack(spacing: Spacing.xs) {
                            Text("Drop to create new lane")
                                .font(Typography.caption)
                                .foregroundColor(.secondary.opacity(0.7))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    // Show preview for all drops (single and multi-file)
                    if (isEmptyAudioDropAllowed || isEmptyAudioDropLoading),
                       let previewFrame = emptyAudioDropPreviewFrame {
                        emptyAudioDropPreviewOverlay(
                            frame: previewFrame,
                            height: min(TimelineLayout.audioLaneHeight, geometry.size.height),
                            width: geometry.size.width,
                            pixelsPerFrame: pixelsPerFrame
                        )
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .overlay {
            DragCaptureView(
                onEntered: { info, location in
                    handleNewLaneDragEntered(info: info, location: adjustLocation(location), pixelsPerFrame: pixelsPerFrame)
                    return .copy  // Accept all drops for new lane creation
                },
                onUpdated: { info, location in
                    handleNewLaneDragUpdated(info: info, location: adjustLocation(location), pixelsPerFrame: pixelsPerFrame)
                },
                onExited: {
                    clearEmptyAudioDrop()
                },
                onPerform: { info, location in
                    handleNewLanePerformDrop(info: info, location: adjustLocation(location), pixelsPerFrame: pixelsPerFrame, laneIndex: laneIndex)
                }
            )
        }
        .frame(height: baseHeight)
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(AppAnimations.instant, value: isActive)
    }

    private func handleNewLaneDragEntered(
        info: NSDraggingInfo,
        location: CGPoint,
        pixelsPerFrame: CGFloat
    ) {
        // Note: externalDragItemCount is tracked at the parent level via the main DragCaptureView
        _ = updateEmptyAudioDrop(from: info, location: location, pixelsPerFrame: pixelsPerFrame)
    }

    private func handleNewLaneDragUpdated(
        info: NSDraggingInfo,
        location: CGPoint,
        pixelsPerFrame: CGFloat
    ) -> NSDragOperation {
        dragContext.refresh()
        let allowed = updateEmptyAudioDrop(from: info, location: location, pixelsPerFrame: pixelsPerFrame)
        return allowed ? .copy : []
    }

    private func handleNewLanePerformDrop(
        info: NSDraggingInfo,
        location: CGPoint,
        pixelsPerFrame: CGFloat,
        laneIndex: Int
    ) -> Bool {
        // Handle both single and multi-file drops to create new lane
        let urls = audioURLs(from: info)
        let videos = videoURLs(from: info)
        let targetFrame = max(0, Int(location.x / max(pixelsPerFrame, 0.001)))
        let isInternal = dragContext.isDragging

        // A batch dropped here can carry picture as well as audio, and
        // `audioCandidate(from:)` filters to audio - so the reel was discarded
        // with no alert and no "Not Imported" notice. It simply vanished, the
        // same silent-loss failure as the 08.07 frame-rate batch bug.
        //
        // This is the drop that runs when there is no lane to aim at yet, so it
        // was the *first* drop into an empty project that lost the picture.
        // Once a lane exists `AudioLaneView.routeDroppedMedia` handles the drop
        // and already routes mixed batches correctly - which is why this looked
        // fine whenever it was retested on a timeline that had content.
        //
        // Video-only drops stay ignored, matching `AudioLaneView`: the video
        // track owns those.
        if !videos.isEmpty, !urls.isEmpty, let onDropMixedMedia {
            onDropMixedMedia(videos, urls, targetFrame)
            dragContext.end()
            clearEmptyAudioDrop()
            return true
        }

        guard !urls.isEmpty else {
            clearEmptyAudioDrop()
            return false
        }
        onDropAudioMedia(laneIndex, urls, targetFrame, isInternal)
        dragContext.end()
        clearEmptyAudioDrop()
        return true
    }

    private func updateEmptyAudioDrop(
        from info: NSDraggingInfo,
        location: CGPoint,
        pixelsPerFrame: CGFloat
    ) -> Bool {
        emptyAudioDropLocation = location
        emptyAudioDropPreviewFrame = emptyAudioDropFrame(for: location, pixelsPerFrame: pixelsPerFrame)

        let candidate = audioCandidate(from: info)
        guard !candidate.urls.isEmpty else {
            clearEmptyAudioDrop()
            return false
        }

        isEmptyAudioDropAllowed = true

        if let duration = candidate.duration {
            emptyAudioDropSourceURL = candidate.urls.first
            emptyAudioDropPreviewDurationFrames = max(1, Int(duration * timeline.config.frameRate.fps))
            isEmptyAudioDropLoading = false
            return true
        }

        if let url = candidate.urls.first {
            if emptyAudioDropSourceURL != url {
                emptyAudioDropSourceURL = url
                emptyAudioDropPreviewDurationFrames = nil
            }
            if emptyAudioDropPreviewDurationFrames == nil && !isEmptyAudioDropLoading {
                isEmptyAudioDropLoading = true
                Task {
                    let asset = AVAsset(url: url)
                    do {
                        let duration = try await asset.load(.duration)
                        emptyAudioDropPreviewDurationFrames = max(1, Int(duration.seconds * timeline.config.frameRate.fps))
                    } catch {
                        emptyAudioDropPreviewDurationFrames = nil
                    }
                    isEmptyAudioDropLoading = false
                }
            }
        }
        return true
    }

    private func audioCandidate(from info: NSDraggingInfo) -> (urls: [URL], duration: Double?, isInternal: Bool) {
        if dragContext.isDragging {
            let audioItems = dragContext.mediaItems.filter { $0.type == .audio }
            if !audioItems.isEmpty {
                return (audioItems.map { $0.url }, audioItems.first?.duration, true)
            }
        }

        let pasteboard = info.draggingPasteboard
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL] ?? []).filter { ProjectMediaLibrary.mediaType(for: $0) == .audio }

        return (urls, nil, false)
    }

    private func audioURLs(from info: NSDraggingInfo) -> [URL] {
        let candidate = audioCandidate(from: info)
        return candidate.urls
    }

    /// The video files in a drag, as `audioCandidate(from:)` gives the audio ones.
    ///
    /// Filtering a drag down to audio is right for the drop *preview* - the
    /// empty-lane target only ever previews an audio clip - but wrong for
    /// deciding where the drop should go. A batch carrying picture as well as
    /// audio has to reach `onDropMixedMedia`, and there is no way to notice that
    /// from a list the picture has already been removed from.
    ///
    /// - Parameter info: The drag being inspected.
    /// - Returns: Every video URL in the drag, empty if there are none.
    private func videoURLs(from info: NSDraggingInfo) -> [URL] {
        if dragContext.isDragging {
            return dragContext.mediaItems
                .filter { $0.type == .video }
                .map { $0.url }
        }

        let pasteboard = info.draggingPasteboard
        return (pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL] ?? []).filter { ProjectMediaLibrary.mediaType(for: $0) == .video }
    }

    private func beginEmptyAudioDrop(
        with providers: [NSItemProvider],
        at location: CGPoint,
        pixelsPerFrame: CGFloat
    ) {
        updateEmptyAudioDropPreview(location: location, pixelsPerFrame: pixelsPerFrame)
        if emptyAudioDropPreviewDurationFrames != nil || isEmptyAudioDropLoading {
            return
        }
        isEmptyAudioDropAllowed = false
        isEmptyAudioDropLoading = true
        emptyAudioDropPreviewDurationFrames = nil
        let isInternalDrag = providers.contains { provider in
            provider.hasItemConformingToTypeIdentifier(UTType.projectorMediaItem.identifier)
        }

        let internalItem = dragContext.mediaItem ?? mediaItem(from: providers)

        if let quickType = quickMediaType(from: providers) {
            guard quickType == .audio else {
                isEmptyAudioDropLoading = false
                clearEmptyAudioDrop()
                return
            }
            isEmptyAudioDropAllowed = true
            if let internalItem, internalItem.type == .audio {
                emptyAudioDropPreviewDurationFrames = max(
                    1,
                    Int(internalItem.duration * timeline.config.frameRate.fps)
                )
            }
        } else if isInternalDrag {
            // Internal drags may not expose URL data during hover; try the custom payload.
            if let provider = providers.first(where: {
                $0.hasItemConformingToTypeIdentifier(UTType.projectorMediaItem.identifier)
            }) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.projectorMediaItem.identifier) { data, _ in
                    DispatchQueue.main.async {
                        let info = extractProjectorMediaInfo(from: data)
                        if info.type == .audio {
                            isEmptyAudioDropAllowed = true
                            if let duration = info.duration {
                                emptyAudioDropPreviewDurationFrames = max(
                                    1,
                                    Int(duration * timeline.config.frameRate.fps)
                                )
                            }
                            if info.url != nil {
                                updateEmptyAudioDropPreview(location: emptyAudioDropLocation ?? location, pixelsPerFrame: pixelsPerFrame)
                            }
                            isEmptyAudioDropLoading = false
                        } else {
                            clearEmptyAudioDrop()
                        }
                    }
                }
                return
            }
        }

        loadFirstURL(from: providers) { url in
            guard let url else {
                // Keep active for internal drags even if hover data isn't available yet.
                isEmptyAudioDropLoading = false
                return
            }
            guard ProjectMediaLibrary.mediaType(for: url) == .audio else {
                isEmptyAudioDropLoading = false
                clearEmptyAudioDrop()
                return
            }
            isEmptyAudioDropAllowed = true
            updateEmptyAudioDropPreview(location: emptyAudioDropLocation ?? location, pixelsPerFrame: pixelsPerFrame)
            Task {
                let asset = AVAsset(url: url)
                do {
                    let duration = try await asset.load(.duration)
                    let frames = max(1, Int(duration.seconds * timeline.config.frameRate.fps))
                    emptyAudioDropPreviewDurationFrames = frames
                } catch {
                    emptyAudioDropPreviewDurationFrames = nil
                }
                isEmptyAudioDropLoading = false
            }
        }
    }

    private func clearEmptyAudioDrop() {
        isEmptyAudioDropAllowed = false
        isEmptyAudioDropLoading = false
        emptyAudioDropPreviewFrame = nil
        emptyAudioDropPreviewDurationFrames = nil
        emptyAudioDropLocation = nil
        emptyAudioDropSourceURL = nil
        // NOTE: Don't reset externalDragItemCount here - only the parent's DragCaptureView onExited should do that
    }

    /// Load URL from an NSItemProvider (for external Finder drops)
    private func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else if let url = item as? URL {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func handleEmptyAudioDrop(
        providers: [NSItemProvider],
        at location: CGPoint,
        pixelsPerFrame: CGFloat,
        laneIndex: Int
    ) -> Bool {
        // Provider callbacks fire on arbitrary queues, so each result is written to
        // its own reserved slot rather than appended. This keeps the collection
        // race-free without a lock and preserves the order the files were dragged
        // in - appending would interleave by completion time, scattering a batch
        // drop across the timeline in arbitrary order.
        var slots = [URL?](repeating: nil, count: providers.count)
        let slotsLock = NSLock()
        let group = DispatchGroup()
        let isInternalDrag = providers.contains { provider in
            provider.hasItemConformingToTypeIdentifier(UTType.projectorMediaItem.identifier)
        }
        let internalItem = dragContext.mediaItem ?? mediaItem(from: providers)

        for (index, provider) in providers.enumerated() {
            group.enter()
            let store: (URL?) -> Void = { url in
                guard let url else { return }
                slotsLock.lock()
                slots[index] = url
                slotsLock.unlock()
            }

            if provider.hasItemConformingToTypeIdentifier(UTType.projectorMediaItem.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.projectorMediaItem.identifier) { data, _ in
                    defer { group.leave() }
                    let info = extractProjectorMediaInfo(from: data)
                    if info.type == .audio {
                        store(info.url)
                    }
                }
            } else {
                loadURL(from: provider) { url in
                    defer { group.leave() }
                    store(url)
                }
            }
        }

        group.notify(queue: .main) {
            var urls = slots.compactMap { $0 }
            if urls.isEmpty, let internalItem, internalItem.type == .audio {
                urls.append(internalItem.url)
            }
            let audioURLs = urls
                .filter { ProjectMediaLibrary.mediaType(for: $0) == .audio }
                .orderedDeduplicated()
            guard !audioURLs.isEmpty else { return }
            let targetFrame = max(0, Int(location.x / max(pixelsPerFrame, 0.001)))
            onDropAudioMedia(laneIndex, audioURLs, targetFrame, isInternalDrag)
            dragContext.end()
        }

        clearEmptyAudioDrop()
        return true
    }

    private func updateEmptyAudioDropPreview(location: CGPoint, pixelsPerFrame: CGFloat) {
        emptyAudioDropLocation = location
        emptyAudioDropPreviewFrame = emptyAudioDropFrame(for: location, pixelsPerFrame: pixelsPerFrame)
    }

    private func emptyAudioDropFrame(for location: CGPoint, pixelsPerFrame: CGFloat) -> Int {
        let x = max(0, location.x)
        let rawFrame = Int(x / max(pixelsPerFrame, 0.001))
        return max(0, min(rawFrame, max(0, timeline.config.durationFrames - 1)))
    }

    private func emptyAudioDropPreviewOverlay(
        frame: Int,
        height: CGFloat,
        width: CGFloat,
        pixelsPerFrame: CGFloat
    ) -> some View {
        let durationFrames = emptyAudioDropPreviewDurationFrames ?? Int(timeline.config.frameRate.fps)
        let rawWidth = CGFloat(durationFrames) * pixelsPerFrame
        let clampedWidth = min(max(12, rawWidth), width)
        let xOffset = CGFloat(frame) * pixelsPerFrame

        return RoundedRectangle(cornerRadius: 4)
            .stroke(Color.orange, lineWidth: 2)
            .background(Color.orange.opacity(0.1))
            .frame(width: clampedWidth, height: max(6, height - 6))
            .offset(x: xOffset)
            .padding(.vertical, Spacing.xs)
            .allowsHitTesting(false)
    }

    private func loadFirstURL(from providers: [NSItemProvider], completion: @escaping (URL?) -> Void) {
        guard let provider = providers.first else {
            completion(nil)
            return
        }
        loadURL(from: provider, completion: completion)
    }

    private func loadURL(from provider: NSItemProvider, completion: @escaping (URL?) -> Void) {
        var didFinish = false
        func finish(_ url: URL?) {
            guard !didFinish else { return }
            didFinish = true
            completion(url)
        }

        provider.loadObject(ofClass: NSURL.self) { object, _ in
            if let url = object as? NSURL {
                finish(url as URL)
                return
            }
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let url = extractURL(from: item) {
                    finish(url)
                    return
                }
                provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                    if let url = extractURL(from: item) {
                        finish(url)
                        return
                    }
                    provider.loadDataRepresentation(forTypeIdentifier: UTType.projectorMediaItem.identifier) { data, _ in
                        finish(extractProjectorMediaURL(from: data))
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
        extractProjectorMediaInfo(from: item).url
    }

    private func extractProjectorMediaInfo(from item: Any?) -> (url: URL?, type: MediaType?, duration: Double?, id: UUID?) {
        guard let data = item as? Data else { return (nil, nil, nil, nil) }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let urlString = object["url"] as? String {
            let type = (object["type"] as? String).flatMap { MediaType(rawValue: $0) }
            let duration = object["duration"] as? Double
            let id = (object["id"] as? String).flatMap { UUID(uuidString: $0) }
            if let url = URL(string: urlString) {
                return (url, type, duration, id)
            }
            if urlString.hasPrefix("/") {
                return (URL(fileURLWithPath: urlString), type, duration, id)
            }
        }
        if let string = String(data: data, encoding: .utf8) {
            if let url = URL(string: string), url.scheme != nil {
                return (url, nil, nil, nil)
            }
            if string.hasPrefix("/") {
                return (URL(fileURLWithPath: string), nil, nil, nil)
            }
        }
        return (nil, nil, nil, nil)
    }

    private func mediaItem(from providers: [NSItemProvider]) -> MediaItem? {
        for provider in providers {
            if let name = provider.suggestedName {
                if let item = mediaLibrary.items.first(where: { $0.url.lastPathComponent == name }) {
                    return item
                }
            }
        }
        return nil
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
                if utType.conforms(to: .audio) { return .audio }
                if utType.conforms(to: .movie) { return .video }
            }
        }
        return nil
    }

    // MARK: - Zoom

    /// Minimum zoom: 0% = fit entire timeline
    private let minZoom: CGFloat = 0.0
    /// Maximum zoom: 100% = max detail
    private let maxZoom: CGFloat = 1.0
    /// Zoom step for UI controls
    private let zoomStep: CGFloat = 0.1

    private func zoomIn() {
        withAnimation(AppAnimations.standard) {
            zoomLevel = min(maxZoom, zoomLevel + zoomStep)
        }
    }

    private func zoomOut() {
        withAnimation(AppAnimations.standard) {
            zoomLevel = max(minZoom, zoomLevel - zoomStep)
        }
    }

    private func resetZoom() {
        withAnimation(AppAnimations.standard) {
            zoomLevel = minZoom
        }
    }

    // MARK: - Zoom to Fit Content

    /// Blank space left on each side when framing content, as a fraction of the
    /// content's own span. Keeps the outermost reels off the viewport edges.
    private static let fitContentMarginFraction: CGFloat = 0.03

    /// How many run-loop turns the fit scroll waits for the new zoom to be laid
    /// out before scrolling anyway.
    private static let maxFitScrollAttempts = 20

    /// Width the vertical scroller takes off the visible track area.
    ///
    /// A constant rather than a measurement because it has to be known *before*
    /// the layout it describes: an import adds lanes, enough lanes bring the
    /// scroller in, and that happens after the fit has already chosen a zoom.
    /// Reading the clip view at solve time reports the width it had without the
    /// scroller, so nothing would be reserved and the outermost reel would end
    /// up behind it.
    ///
    /// 17pt is the difference measured between the track area's geometry and the
    /// clip view once the scroller was present, on a five-lane import.
    private static let verticalScrollerAllowance: CGFloat = 17

    /// The frame range occupied by every reel and clip on the timeline.
    ///
    /// - Returns: The first and last content frames, or `nil` when the timeline
    ///   is empty or its content has no length.
    private func contentFrameRange() -> (start: Int, end: Int)? {
        var starts: [Int] = timeline.videoReels.map { $0.timelineStartFrame }
        var ends: [Int] = timeline.videoReels.map { $0.timelineEndFrame }

        for lane in timeline.audioLanes {
            starts.append(contentsOf: lane.clips.map { $0.timelineStartFrame })
            ends.append(contentsOf: lane.clips.map { $0.timelineEndFrame })
        }

        guard let start = starts.min(), let end = ends.max(), end > start else { return nil }
        return (max(0, start), end)
    }

    /// Zoom and scroll so every reel and clip on the timeline is on screen.
    ///
    /// The timeline is at least two hours long whatever is on it, so fit-to-
    /// timeline zoom renders an imported reel as a sliver against an empty
    /// field. This solves for the zoom that makes the *content* span the track
    /// area instead, then scrolls that span into view.
    ///
    /// Both halves are needed: content sitting at an hour into the timeline is
    /// off screen at any zoom that makes it legible, so zooming without
    /// scrolling would leave the viewport parked on empty timeline.
    private func zoomToFitContent() {
        guard let content = contentFrameRange() else { return }

        // Two different widths, and using one for both jobs is what made the
        // first version of this land wrong.
        //
        // `curveWidth` is the width the zoom curve is a function of, so
        // inverting the curve has to use the *same* number
        // `pixelsPerFrame(for:)` was handed - anything else changes the
        // multiplier and the solved slider position with it.
        //
        // `visibleContentWidth` is how much of the track area a user can
        // actually see, which is less: the scroll view's clip view is narrower
        // than the row the geometry reported (1416pt against 1399pt, measured on
        // a five-lane import), and an import that adds lanes brings the vertical
        // scroller in *after* this runs. Framing against the larger number put
        // the outermost reel behind that scroller.
        let curveWidth = trackAreaWidth > TimelineLayout.headerWidth
            ? trackAreaWidth
            : (cachedScrollView?.contentView.bounds.width ?? 0)
        let curveContentWidth = curveWidth - TimelineLayout.headerWidth
        let visibleContentWidth = curveContentWidth - Self.verticalScrollerAllowance
        let durationFrames = CGFloat(max(1, timeline.config.durationFrames))
        guard curveContentWidth > 0, visibleContentWidth > 0 else { return }

        // Margin comes out of the span on both sides, clamped to the timeline
        // so a reel starting at frame 0 is not asked to scroll to a negative
        // offset.
        let span = CGFloat(content.end - content.start)
        let margin = span * Self.fitContentMarginFraction
        let framedStart = max(0, CGFloat(content.start) - margin)
        let framedEnd = min(durationFrames, CGFloat(content.end) + margin)
        let framedSpan = max(1, framedEnd - framedStart)

        // Invert the geometric zoom curve `pixelsPerFrame(for:)` applies: given
        // the scale that makes the framed span fill the visible track area,
        // solve for the slider position that produces it.
        let fitPixelsPerFrame = curveContentWidth / durationFrames
        let desiredPixelsPerFrame = visibleContentWidth / framedSpan
        let multiplier = maxZoomMultiplier(fitPixelsPerFrame: fitPixelsPerFrame)
        guard fitPixelsPerFrame > 0, multiplier > 1 else { return }

        let solvedZoom = log(desiredPixelsPerFrame / fitPixelsPerFrame) / log(multiplier)
        let targetZoom = min(max(solvedZoom, minZoom), maxZoom)

        // Framing sets the zoom *and* the offset that goes with it, so the
        // playhead anchor must not also act on this change and scroll somewhere
        // else. Only raised when the zoom really changes - otherwise no
        // `onChange` arrives to lower it again, and the next genuine zoom would
        // be the one that got skipped.
        if targetZoom != zoomLevel {
            isFramingContent = true
            zoomLevel = targetZoom
        }

        // The scroll is handed the span in *frames*, not a point offset, so it
        // can convert once the layout has settled. Only the width the document
        // is expected to reach is precomputed, and only to know when that has
        // happened.
        let expectedPixelsPerFrame = fitPixelsPerFrame * pow(multiplier, targetZoom)

        scrollFramedContentIntoView(
            framedStartFrame: framedStart,
            framedSpanFrames: framedSpan,
            expectedDocumentWidth: durationFrames * expectedPixelsPerFrame + TimelineLayout.headerWidth
        )
    }

    /// Keep the playhead on the same pixel while the zoom changes.
    ///
    /// Without this the scroll offset stays put in *points* while the scale
    /// changes underneath it, so the frame at the left edge is `offset / scale` -
    /// and zooming in walks the viewport backwards towards the start of the
    /// timeline. The thing being synced to slides away exactly when a closer look
    /// is wanted.
    ///
    /// Anchored to the playhead rather than the pointer, which is what Pro Tools
    /// and Resolve do and what a picture-sync session wants: the playhead is the
    /// sync point, so it is what should hold still. A playhead already off screen
    /// is brought to the middle instead - the deliberate "snap back" of a
    /// playhead-anchored zoom.
    ///
    /// The before-state is read here, synchronously, while the clip view still
    /// reflects the old scale. Reading it after the layout would mix the old
    /// scale with an offset AppKit may already have clamped for the new document
    /// width, which is wrong in the zoom-out direction.
    ///
    /// - Parameters:
    ///   - oldZoom: Slider position before the change.
    ///   - newZoom: Slider position after it.
    private func anchorPlayheadAcrossZoom(from oldZoom: CGFloat, to newZoom: CGFloat) {
        if isFramingContent {
            isFramingContent = false
            return
        }

        guard let scrollView = cachedScrollView else { return }

        let durationFrames = CGFloat(max(1, timeline.config.durationFrames))
        let previousPixelsPerFrame = pixelsPerFrame(atZoom: oldZoom)
        let newPixelsPerFrame = pixelsPerFrame(atZoom: newZoom)
        guard previousPixelsPerFrame > 0,
              newPixelsPerFrame > 0,
              newPixelsPerFrame != previousPixelsPerFrame else { return }

        let clipView = scrollView.contentView
        let visibleWidth = clipView.bounds.width - TimelineLayout.headerWidth
        guard visibleWidth > 0 else { return }

        let playheadFrame = CGFloat(max(0, playbackEngine.currentFrame))

        // First change of the burst decides where the playhead is being held;
        // the rest of the animation reuses it. A playhead already off screen is
        // brought to the middle instead.
        let anchorX: CGFloat
        if let held = pendingAnchorX {
            anchorX = held
        } else {
            let previousX = playheadFrame * previousPixelsPerFrame - clipView.bounds.origin.x
            anchorX = (0...visibleWidth).contains(previousX) ? previousX : visibleWidth / 2
            pendingAnchorX = anchorX
        }

        anchorToken += 1
        let token = anchorToken

        afterZoomLayout(
            expectedDocumentWidth: durationFrames * newPixelsPerFrame + TimelineLayout.headerWidth
        ) { scrollView, documentWidth in
            // Superseded: the user has zoomed again since, and that change has
            // its own scroll to do.
            guard token == anchorToken else { return }

            setScrollOriginX(
                playheadFrame * newPixelsPerFrame - anchorX,
                in: scrollView,
                documentWidth: documentWidth
            )
            pendingAnchorX = nil
        }
    }

    /// The scale a given slider position produces.
    ///
    /// The same curve as ``pixelsPerFrame(for:)``, addressed by zoom rather than
    /// by width, so a zoom change can be converted to a scale change without
    /// waiting for the layout that will realise it. **If one of these two
    /// changes, the other has to change with it** - the anchor is only correct
    /// while they agree.
    ///
    /// - Parameter zoom: Slider position, clamped to the usable range.
    /// - Returns: Points per frame, or 0 when the track area has no width yet.
    private func pixelsPerFrame(atZoom zoom: CGFloat) -> CGFloat {
        let contentWidth = zoomCurveContentWidth
        guard contentWidth > 0 else { return 0 }

        let durationFrames = CGFloat(max(1, timeline.config.durationFrames))
        let fitPixelsPerFrame = contentWidth / durationFrames
        let multiplier = maxZoomMultiplier(fitPixelsPerFrame: fitPixelsPerFrame)
        return fitPixelsPerFrame * pow(multiplier, min(max(zoom, minZoom), maxZoom))
    }

    /// Width the zoom curve is a function of, less the header column.
    ///
    /// The track area's own geometry, falling back to the scroll view before the
    /// first layout has been recorded. See ``trackAreaWidth`` for why the clip
    /// view is not a substitute.
    private var zoomCurveContentWidth: CGFloat {
        let width = trackAreaWidth > TimelineLayout.headerWidth
            ? trackAreaWidth
            : (cachedScrollView?.contentView.bounds.width ?? 0)
        return width - TimelineLayout.headerWidth
    }

    /// Scroll the track area so the framed span is on screen, once the new zoom
    /// has been laid out.
    ///
    /// Deferred, and retried until the document view is as wide as the new zoom
    /// implies: scrolling in the same run-loop turn as the zoom change clamps
    /// the offset against the old, narrower document and lands short of the
    /// content.
    ///
    /// The offset is derived here, from the settled document and clip view,
    /// rather than passed in as points. The scale the view actually adopts is
    /// not quite the one the solve asked for - the clip view loses width to a
    /// vertical scroller the import itself brings in - and converting frames to
    /// points with the pre-layout scale put the framed span slightly off from
    /// where it was measured to be.
    ///
    /// - Parameters:
    ///   - framedStartFrame: First frame that should be visible.
    ///   - framedSpanFrames: Length of the span being framed.
    ///   - expectedDocumentWidth: Width the document reaches at the new zoom.
    ///   - attempt: Number of turns already waited.
    private func scrollFramedContentIntoView(
        framedStartFrame: CGFloat,
        framedSpanFrames: CGFloat,
        expectedDocumentWidth: CGFloat
    ) {
        afterZoomLayout(expectedDocumentWidth: expectedDocumentWidth) { scrollView, documentWidth in
            let clipView = scrollView.contentView
            let durationFrames = CGFloat(max(1, timeline.config.durationFrames))
            let pixelsPerFrame = (documentWidth - TimelineLayout.headerWidth) / durationFrames
            let contentAreaWidth = clipView.bounds.width - TimelineLayout.headerWidth

            // Content too short to fill the track area even at maximum zoom is
            // centred rather than pinned left, so the blank space it cannot help
            // leaving sits on both sides instead of all trailing off to the right.
            let framedWidth = framedSpanFrames * pixelsPerFrame
            let centringOffset = max(0, contentAreaWidth - framedWidth) / 2

            setScrollOriginX(
                framedStartFrame * pixelsPerFrame - centringOffset,
                in: scrollView,
                documentWidth: documentWidth
            )
        }
    }

    /// Runs `body` once the document view is as wide as a new zoom implies.
    ///
    /// Deferred, and retried, because scrolling in the same run-loop turn as the
    /// zoom change clamps the offset against the old document width and lands
    /// short. Gives up after ``maxFitScrollAttempts`` turns and runs anyway
    /// rather than abandoning the scroll altogether.
    ///
    /// - Parameters:
    ///   - expectedDocumentWidth: Width the document reaches at the new zoom.
    ///   - attempt: Number of turns already waited.
    ///   - body: Given the scroll view and the document width it settled at.
    private func afterZoomLayout(
        expectedDocumentWidth: CGFloat,
        attempt: Int = 0,
        _ body: @escaping (NSScrollView, CGFloat) -> Void
    ) {
        DispatchQueue.main.async {
            guard let scrollView = cachedScrollView else { return }

            let documentWidth = scrollView.documentView?.frame.width ?? 0
            if documentWidth + 1 < expectedDocumentWidth, attempt < Self.maxFitScrollAttempts {
                afterZoomLayout(
                    expectedDocumentWidth: expectedDocumentWidth,
                    attempt: attempt + 1,
                    body
                )
                return
            }

            body(scrollView, documentWidth)
        }
    }

    /// Scrolls the track area horizontally, clamped to the document.
    ///
    /// - Parameters:
    ///   - offsetX: Desired horizontal origin, in document points.
    ///   - scrollView: The track area's scroll view.
    ///   - documentWidth: Width the document settled at.
    private func setScrollOriginX(
        _ offsetX: CGFloat,
        in scrollView: NSScrollView,
        documentWidth: CGFloat
    ) {
        let clipView = scrollView.contentView
        var origin = clipView.bounds.origin
        origin.x = max(0, min(offsetX, max(0, documentWidth - clipView.bounds.width)))
        clipView.setBoundsOrigin(origin)
        scrollView.reflectScrolledClipView(clipView)
    }

    private func registerTimelineUndo(actionName: String) {
        let previousTimeline = timelineManager.timeline
        undoManager?.registerUndo(withTarget: timelineManager) { _ in
            timelineManager.timeline = previousTimeline
        }
        undoManager?.setActionName(actionName)
    }

    private func registerAudioClipMoveUndo(clipId: UUID, laneId: UUID, from oldFrame: Int) {
        undoManager?.registerUndo(withTarget: timelineManager) { _ in
            timelineManager.moveAudioClip(clipId: clipId, inLane: laneId, to: oldFrame)
        }
        undoManager?.setActionName("Move Audio Clip")
    }

    private func registerVideoReelMoveUndo(reelId: UUID, from oldFrame: Int) {
        undoManager?.registerUndo(withTarget: timelineManager) { _ in
            timelineManager.moveVideoReel(id: reelId, to: oldFrame)
        }
        undoManager?.setActionName("Move Video Reel")
    }

    // MARK: - Lane Reorder

    /// Where a lane would land, given how far it has been dragged.
    ///
    /// **Rounding, not a threshold.** A lane changes places once it has been
    /// dragged past the halfway point of its neighbour, which is how every list
    /// with draggable rows behaves and what makes the movement feel proportional
    /// to the hand.
    ///
    /// The previous version fired at a fixed 20pt and then counted whole rows on
    /// top of that, so the *first* swap needed 20pt while every later one needed a
    /// full 81pt row - four times less sensitive after the first step. Worse, at
    /// exactly 20pt the target flipped between two values on the smallest movement,
    /// and each flip animated every other lane: the jumpiness was the lanes
    /// underneath being re-animated, not the lane in hand.
    ///
    /// - Parameters:
    ///   - sourceLaneIndex: Index of the lane being dragged, in `audioLanes`.
    ///   - dragOffset: How far it has been dragged vertically, in points.
    /// - Returns: The index it would be inserted at, clamped to the lane count.
    private func calculateLaneReorderTarget(from sourceLaneIndex: Int, dragOffset: CGFloat) -> Int {
        // Indices are into `audioLanes` while the rows on screen are
        // `standaloneAudioLanes` - the video file's own audio is drawn as a strip
        // under the picture, not as a row here. The two agree because an import
        // creates a video's lanes before any stems, so the stems are contiguous at
        // the end of the array. If a video lane ever ends up *between* stems, one
        // row of movement would stop meaning one index, and this is the place that
        // has to change.
        Self.laneReorder.target(
            source: sourceLaneIndex,
            held: laneReorderTargetIndex,
            dragOffset: dragOffset,
            laneCount: timeline.audioLanes.count
        )
    }

    /// The reorder rule. See ``LaneReorder`` for why it is a type of its own.
    ///
    /// 0.18 of a row is about 15pt at the current height - enough to absorb the
    /// hand's own movement while holding a lane near the point where it locks in,
    /// small enough that a deliberate drag does not feel resisted.
    private static let laneReorder = LaneReorder(rowHeight: laneRowHeight, hysteresisRows: 0.18)

    /// One lane row, including the divider drawn under it.
    ///
    /// The reorder maths and the displacement of the lanes being pushed aside must
    /// use the same number, or the lane you are dragging and the gap it is heading
    /// for disagree about where a row begins.
    private static var laneRowHeight: CGFloat {
        TimelineLayout.audioLaneHeight + laneDividerHeight
    }

    /// The hairline between two lanes.
    private static let laneDividerHeight: CGFloat = 1

    /// Create a long-press + drag gesture for lane reordering.
    ///
    /// - Parameter laneId: The ID of the lane this gesture is attached to
    /// - Parameter laneIndex: The index of the lane in audioLanes array
    /// - Returns: A gesture that handles lane reordering
    private func laneReorderGesture(laneId: UUID, laneIndex: Int) -> some Gesture {
        LongPressGesture(minimumDuration: 0.15)
            // `.global` IS LOAD-BEARING, and the default `.local` is a bug.
            //
            // The row is displaced by `.offset(y: draggingLaneOffset)`, and
            // `draggingLaneOffset` is this gesture's own `translation.height`. In
            // the local coordinate space that translation is measured against a
            // frame the offset is itself moving, so the offset feeds the gesture
            // and the gesture feeds the offset: a positive feedback loop.
            //
            // Measured, holding the mouse still mid-drag: `translation.height`
            // alternated between two values every frame and the gap *grew* -
            // 3.6pt, 4.1, 5.1, 5.9 ... 8.9pt - an oscillator winding up. That was
            // the "shaking", and it is why hesitating made it worse rather than
            // better. The reorder target never flipped once across 377 samples,
            // so the hysteresis rule below was never the cause.
            //
            // The global space does not move when the row is offset, which breaks
            // the loop.
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .onChanged { value in
                switch value {
                case .first(true):
                    // Long press started - immediately show closed hand cursor
                    if !laneReorderCursorPushed {
                        NSCursor.closedHand.push()
                        laneReorderCursorPushed = true
                    }
                case .second(true, let drag):
                    guard let drag = drag else { return }
                    if draggingLaneId == nil {
                        draggingLaneId = laneId
                        draggingLaneSourceIndex = laneIndex
                    }
                    draggingLaneOffset = drag.translation.height
                    laneReorderTargetIndex = calculateLaneReorderTarget(
                        from: laneIndex,
                        dragOffset: drag.translation.height
                    )
                default:
                    break
                }
            }
            .onEnded { value in
                // Pop the closed hand cursor
                if laneReorderCursorPushed {
                    NSCursor.pop()
                    laneReorderCursorPushed = false
                }
                if case .second(true, _) = value,
                   let targetIndex = laneReorderTargetIndex,
                   targetIndex != laneIndex {
                    // Perform the reorder
                    registerTimelineUndo(actionName: "Reorder Lane")
                    timelineManager.moveAudioLane(from: laneIndex, to: targetIndex)
                }
                // Reset state
                draggingLaneId = nil
                draggingLaneSourceIndex = nil
                draggingLaneOffset = 0
                laneReorderTargetIndex = nil
            }
    }

    /// Insertion indicator line shown between lanes during reorder drag.
    private var laneReorderInsertionIndicator: some View {
        Rectangle()
            .fill(Color.accentColor)
            .frame(height: 2)
            .shadow(color: Color.accentColor.opacity(0.5), radius: 2, x: 0, y: 0)
    }

    /// Calculate the displacement offset for a lane during drag reorder.
    /// When dragging a lane to a new position, other lanes slide out of the way.
    private func laneDisplacementOffset(for laneIndex: Int) -> CGFloat {
        guard let sourceIndex = draggingLaneSourceIndex,
              let targetIndex = laneReorderTargetIndex,
              sourceIndex != targetIndex,
              laneIndex != sourceIndex else {
            return 0
        }

        let laneHeight = Self.laneRowHeight

        // Dragging down (source < target): lanes between source and target move UP
        if sourceIndex < targetIndex {
            if laneIndex > sourceIndex && laneIndex <= targetIndex {
                return -laneHeight
            }
        }
        // Dragging up (source > target): lanes between target and source move DOWN
        else {
            if laneIndex >= targetIndex && laneIndex < sourceIndex {
                return laneHeight
            }
        }

        return 0
    }

    // MARK: - Marquee Selection

    /// Computed marquee rectangle in view coordinates
    private var marqueeRect: CGRect {
        let minX = min(marqueeStartPoint.x, marqueeCurrentPoint.x)
        let minY = min(marqueeStartPoint.y, marqueeCurrentPoint.y)
        let maxX = max(marqueeStartPoint.x, marqueeCurrentPoint.x)
        let maxY = max(marqueeStartPoint.y, marqueeCurrentPoint.y)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Selection rectangle overlay view
    private var marqueeSelectionRectangle: some View {
        Rectangle()
            .stroke(Color.accentColor, lineWidth: 1)
            .background(Color.accentColor.opacity(0.1))
            .frame(width: marqueeRect.width, height: marqueeRect.height)
            .position(x: marqueeRect.midX, y: marqueeRect.midY)
            .allowsHitTesting(false)
    }

    /// Update selection based on clips intersecting with marquee rectangle
    /// - Parameters:
    ///   - pixelsPerFrame: Current pixels per frame for calculating clip positions
    ///   - scrollOffset: Current horizontal scroll offset (for position adjustment)
    private func updateMarqueeSelection(pixelsPerFrame: CGFloat, scrollOffset: CGFloat = 0) {
        var newVideoSelection: Set<UUID> = []
        var newAudioSelection: Set<UUID> = []

        // If shift is held, start with existing selection
        if NSEvent.modifierFlags.contains(.shift) {
            newVideoSelection = selectedVideoReelIds
            newAudioSelection = selectedAudioClipIds
        }

        // The marquee coordinates are relative to the scroll content VStack which contains:
        // - 4px spacer at top
        // - Video track (height: videoTrackHeight)
        // - 1px divider
        // - Audio lanes (each height: audioLaneHeight with 1px dividers between)
        // - 8px spacer at bottom
        //
        // The X coordinate needs to account for the header width since clips are positioned
        // starting after the header

        // Adjust marquee X for header (clips start after header)
        let marqueeMinX = marqueeRect.minX - TimelineLayout.headerWidth
        let marqueeMaxX = marqueeRect.maxX - TimelineLayout.headerWidth

        // Video track Y positions in scroll content coordinates
        let videoTrackTop: CGFloat = 4 // After 4px spacer
        let videoTrackBottom = videoTrackTop + TimelineLayout.videoTrackHeight

        for reel in timeline.videoReels {
            let reelX = CGFloat(reel.timelineStartFrame) * pixelsPerFrame
            let reelWidth = CGFloat(reel.durationFrames) * pixelsPerFrame
            let reelMaxX = reelX + reelWidth

            // Check X overlap
            let xOverlap = marqueeMaxX > reelX && marqueeMinX < reelMaxX
            // Check Y overlap
            let yOverlap = marqueeRect.maxY > videoTrackTop && marqueeRect.minY < videoTrackBottom

            if xOverlap && yOverlap {
                newVideoSelection.insert(reel.id)
            }
        }

        // Audio lanes Y positions in scroll content coordinates
        var audioLaneTop = videoTrackBottom + 1 // After 1px divider
        for lane in timeline.audioLanes {
            let audioLaneBottom = audioLaneTop + TimelineLayout.audioLaneHeight

            for clip in lane.clips {
                let clipX = CGFloat(clip.timelineStartFrame) * pixelsPerFrame
                let clipWidth = CGFloat(clip.durationFrames) * pixelsPerFrame
                let clipMaxX = clipX + clipWidth

                // Check X overlap
                let xOverlap = marqueeMaxX > clipX && marqueeMinX < clipMaxX
                // Check Y overlap
                let yOverlap = marqueeRect.maxY > audioLaneTop && marqueeRect.minY < audioLaneBottom

                if xOverlap && yOverlap {
                    newAudioSelection.insert(clip.id)
                }
            }

            audioLaneTop = audioLaneBottom + 1 // Move to next lane (with 1px divider)
        }

        selectedVideoReelIds = newVideoSelection
        selectedAudioClipIds = newAudioSelection

        // Update single selection for compatibility (use first selected item)
        selectedVideoReelId = newVideoSelection.first
        selectedAudioClipId = newAudioSelection.first
        if let clipId = selectedAudioClipId {
            // Find the lane containing this clip
            selectedAudioLaneId = timeline.audioLanes.first { lane in
                lane.clips.contains { $0.id == clipId }
            }?.id
        }

    }

    /// Clear all selections
    private func clearSelection() {
        selectedVideoReelIds.removeAll()
        selectedAudioClipIds.removeAll()
        selectedVideoReelId = nil
        selectedAudioClipId = nil
        selectedAudioLaneId = nil
    }

    /// Deselect all items in the timeline
    private func deselectAll() {
        clearSelection()
    }

    /// Select all items in the timeline
    private func selectAll() {
        // Select all video reels
        selectedVideoReelIds = Set(timeline.videoReels.map { $0.id })

        // Select all audio clips
        selectedAudioClipIds = Set(timeline.audioLanes.flatMap { lane in
            lane.clips.map { $0.id }
        })

        // Update single selection for compatibility (use first item)
        selectedVideoReelId = selectedVideoReelIds.first
        selectedAudioClipId = selectedAudioClipIds.first

        if let clipId = selectedAudioClipId {
            selectedAudioLaneId = timeline.audioLanes.first { lane in
                lane.clips.contains { $0.id == clipId }
            }?.id
        }
    }

    /// Cut selected items (copy to clipboard then delete)
    private func cutSelectedItems() {
        copySelectedItems()
        deleteSelectedItem()
    }

    /// Copy selected items to clipboard
    private func copySelectedItems() {
        // Store selected video reel IDs
        clipboardVideoReelIds = selectedVideoReelIds

        // Store selected audio clip IDs with their lane IDs
        clipboardAudioClipIds = selectedAudioClipIds
    }

    /// Paste items from clipboard at playhead position
    private func pasteItems() {
        let playheadFrame = playbackEngine.currentFrame

        // Paste video reels
        for reelId in clipboardVideoReelIds {
            guard let reel = timeline.videoReels.first(where: { $0.id == reelId }) else { continue }
            // Create a copy at playhead position
            Task { @MainActor in
                do {
                    _ = try await timelineManager.addVideoReel(
                        from: reel.sourceURL,
                        at: playheadFrame,
                        mediaItemId: reel.mediaItemId
                    )
                } catch {
                    pasteErrorMessage = "Failed to paste video: \(error.localizedDescription)"
                    showPasteError = true
                }
            }
        }

        // Paste audio clips
        for clipId in clipboardAudioClipIds {
            for lane in timeline.audioLanes {
                guard let clip = lane.clips.first(where: { $0.id == clipId }) else { continue }
                // Create a copy at playhead position in the same lane
                Task { @MainActor in
                    do {
                        _ = try await timelineManager.addAudioClip(
                            from: clip.sourceURL,
                            toLane: lane.id,
                            at: playheadFrame
                        )
                    } catch {
                        pasteErrorMessage = "Failed to paste audio: \(error.localizedDescription)"
                        showPasteError = true
                    }
                }
                break
            }
        }
    }

    // MARK: - Selection Handling with Modifiers

    /// Handle video reel selection with modifier key support
    ///
    /// - Parameters:
    ///   - reelId: The ID of the clicked reel (nil to deselect)
    ///   - modifiers: Current modifier keys
    private func handleReelSelection(reelId: UUID?, modifiers: SelectionModifiers) {
        isTimelineFocused = true

        guard let reelId else {
            // Nil selection - clear all
            deselectAll()
            return
        }

        if modifiers.contains(.command) {
            // Cmd+Click: Toggle selection
            if selectedVideoReelIds.contains(reelId) {
                selectedVideoReelIds.remove(reelId)
                if selectedVideoReelId == reelId {
                    selectedVideoReelId = selectedVideoReelIds.first
                }
            } else {
                selectedVideoReelIds.insert(reelId)
                selectedVideoReelId = reelId
            }
            // Clear audio selection when toggling video
            selectedAudioClipId = nil
            selectedAudioLaneId = nil
        } else if modifiers.contains(.shift) {
            // Shift+Click: Range selection (extend from last selected to this reel)
            if let anchorId = selectedVideoReelId,
               let anchorReel = timeline.videoReels.first(where: { $0.id == anchorId }),
               let targetReel = timeline.videoReels.first(where: { $0.id == reelId }) {
                // Get reels between anchor and target (by timeline position)
                let startFrame = min(anchorReel.timelineStartFrame, targetReel.timelineStartFrame)
                let endFrame = max(
                    anchorReel.timelineStartFrame + anchorReel.durationFrames,
                    targetReel.timelineStartFrame + targetReel.durationFrames
                )
                // Select all reels that overlap this range
                for reel in timeline.videoReels {
                    let reelEnd = reel.timelineStartFrame + reel.durationFrames
                    if reel.timelineStartFrame < endFrame && reelEnd > startFrame {
                        selectedVideoReelIds.insert(reel.id)
                    }
                }
            } else {
                // No anchor - just select this reel
                selectedVideoReelIds.insert(reelId)
                selectedVideoReelId = reelId
            }
            // Clear audio selection on shift-click
            selectedAudioClipIds.removeAll()
            selectedAudioClipId = nil
            selectedAudioLaneId = nil
        } else {
            // Normal click: Single selection (clear others)
            selectedVideoReelIds.removeAll()
            selectedAudioClipIds.removeAll()
            selectedVideoReelIds.insert(reelId)
            selectedVideoReelId = reelId
            selectedAudioClipId = nil
            selectedAudioLaneId = nil
        }
    }

    /// Handle audio clip selection with modifier key support
    ///
    /// - Parameters:
    ///   - clipId: The ID of the clicked clip (nil to deselect)
    ///   - laneId: The ID of the lane containing the clip
    ///   - modifiers: Current modifier keys
    private func handleClipSelection(clipId: UUID?, laneId: UUID, modifiers: SelectionModifiers) {
        isTimelineFocused = true

        guard let clipId else {
            // Nil selection - clear all
            deselectAll()
            return
        }

        if modifiers.contains(.command) {
            // Cmd+Click: Toggle selection
            if selectedAudioClipIds.contains(clipId) {
                selectedAudioClipIds.remove(clipId)
                if selectedAudioClipId == clipId {
                    selectedAudioClipId = selectedAudioClipIds.first
                    // Update lane ID for new primary selection
                    if let newPrimaryId = selectedAudioClipId {
                        selectedAudioLaneId = timeline.audioLanes.first { lane in
                            lane.clips.contains { $0.id == newPrimaryId }
                        }?.id
                    }
                }
            } else {
                selectedAudioClipIds.insert(clipId)
                selectedAudioClipId = clipId
                selectedAudioLaneId = laneId
            }
            // Clear video selection when toggling audio
            selectedVideoReelId = nil
        } else if modifiers.contains(.shift) {
            // Shift+Click: Range selection (extend from last selected to this clip)
            if let anchorId = selectedAudioClipId,
               let (_, anchorClip) = findClip(by: anchorId),
               let (_, targetClip) = findClip(by: clipId) {
                // Get clips between anchor and target (by timeline position)
                let startFrame = min(anchorClip.timelineStartFrame, targetClip.timelineStartFrame)
                let endFrame = max(
                    anchorClip.timelineStartFrame + anchorClip.durationFrames,
                    targetClip.timelineStartFrame + targetClip.durationFrames
                )
                // Select all clips that overlap this range (across all lanes)
                for lane in timeline.audioLanes {
                    for clip in lane.clips {
                        let clipEnd = clip.timelineStartFrame + clip.durationFrames
                        if clip.timelineStartFrame < endFrame && clipEnd > startFrame {
                            selectedAudioClipIds.insert(clip.id)
                        }
                    }
                }
            } else {
                // No anchor - just select this clip
                selectedAudioClipIds.insert(clipId)
                selectedAudioClipId = clipId
                selectedAudioLaneId = laneId
            }
            // Clear video selection on shift-click
            selectedVideoReelIds.removeAll()
            selectedVideoReelId = nil
        } else {
            // Normal click: Single selection (clear others)
            selectedVideoReelIds.removeAll()
            selectedAudioClipIds.removeAll()
            selectedAudioClipIds.insert(clipId)
            selectedAudioClipId = clipId
            selectedAudioLaneId = laneId
            selectedVideoReelId = nil
        }
    }

    // MARK: - Arrow Key Navigation

    /// Direction for selection navigation
    private enum NavigationDirection {
        case left, right, up, down
    }

    /// Navigate selection using arrow keys
    ///
    /// - Left/Right: Move to previous/next clip by timeline position
    /// - Up/Down: Move between video track and audio lanes
    private func navigateSelection(direction: NavigationDirection) {
        // Build a sorted list of all selectable items
        let videoReels = timeline.videoReels.sorted { $0.timelineStartFrame < $1.timelineStartFrame }
        let audioClips: [(lane: AudioLane, clip: AudioClip, laneIndex: Int)] = timeline.audioLanes.enumerated().flatMap { index, lane in
            lane.clips.map { (lane, $0, index) }
        }.sorted { $0.clip.timelineStartFrame < $1.clip.timelineStartFrame }

        switch direction {
        case .left:
            navigateHorizontal(backward: true, videoReels: videoReels, audioClips: audioClips)
        case .right:
            navigateHorizontal(backward: false, videoReels: videoReels, audioClips: audioClips)
        case .up:
            navigateVertical(upward: true, videoReels: videoReels, audioClips: audioClips)
        case .down:
            navigateVertical(upward: false, videoReels: videoReels, audioClips: audioClips)
        }
    }

    /// Navigate horizontally (left/right) to previous/next item
    private func navigateHorizontal(backward: Bool, videoReels: [VideoReel], audioClips: [(lane: AudioLane, clip: AudioClip, laneIndex: Int)]) {
        // If we have a video reel selected, navigate within video track
        if let selectedId = selectedVideoReelId,
           let currentIndex = videoReels.firstIndex(where: { $0.id == selectedId }) {
            let newIndex = backward ? currentIndex - 1 : currentIndex + 1
            if videoReels.indices.contains(newIndex) {
                clearSelection()
                let newReel = videoReels[newIndex]
                selectedVideoReelId = newReel.id
                selectedVideoReelIds.insert(newReel.id)
            }
            return
        }

        // If we have an audio clip selected, navigate within audio lanes
        if let selectedId = selectedAudioClipId,
           let currentIndex = audioClips.firstIndex(where: { $0.clip.id == selectedId }) {
            let newIndex = backward ? currentIndex - 1 : currentIndex + 1
            if audioClips.indices.contains(newIndex) {
                clearSelection()
                let item = audioClips[newIndex]
                selectedAudioClipId = item.clip.id
                selectedAudioClipIds.insert(item.clip.id)
                selectedAudioLaneId = item.lane.id
            }
            return
        }

        // Nothing selected - select the first/last item depending on direction
        if backward {
            // Select the last video reel if available
            if let lastReel = videoReels.last {
                clearSelection()
                selectedVideoReelId = lastReel.id
                selectedVideoReelIds.insert(lastReel.id)
            } else if let lastClip = audioClips.last {
                clearSelection()
                selectedAudioClipId = lastClip.clip.id
                selectedAudioClipIds.insert(lastClip.clip.id)
                selectedAudioLaneId = lastClip.lane.id
            }
        } else {
            // Select the first video reel if available
            if let firstReel = videoReels.first {
                clearSelection()
                selectedVideoReelId = firstReel.id
                selectedVideoReelIds.insert(firstReel.id)
            } else if let firstClip = audioClips.first {
                clearSelection()
                selectedAudioClipId = firstClip.clip.id
                selectedAudioClipIds.insert(firstClip.clip.id)
                selectedAudioLaneId = firstClip.lane.id
            }
        }
    }

    /// Navigate vertically (up/down) between video track and audio lanes
    private func navigateVertical(upward: Bool, videoReels: [VideoReel], audioClips: [(lane: AudioLane, clip: AudioClip, laneIndex: Int)]) {
        // Get current timeline position for finding items at similar positions
        let currentFrame: Int
        if let selectedId = selectedVideoReelId,
           let reel = videoReels.first(where: { $0.id == selectedId }) {
            currentFrame = reel.timelineStartFrame
        } else if let selectedId = selectedAudioClipId,
                  let item = audioClips.first(where: { $0.clip.id == selectedId }) {
            currentFrame = item.clip.timelineStartFrame
        } else {
            currentFrame = playbackEngine.currentFrame
        }

        if upward {
            // Move up: from audio to video track, or from lower lane to upper lane
            if let selectedId = selectedAudioClipId,
               let currentItem = audioClips.first(where: { $0.clip.id == selectedId }) {
                if currentItem.laneIndex == 0 {
                    // At the top audio lane - move to video track
                    if let nearestReel = findNearestVideoReel(at: currentFrame, in: videoReels) {
                        clearSelection()
                        selectedVideoReelId = nearestReel.id
                        selectedVideoReelIds.insert(nearestReel.id)
                    }
                } else {
                    // Move to upper audio lane
                    let targetLaneIndex = currentItem.laneIndex - 1
                    if let nearestClip = findNearestAudioClip(at: currentFrame, inLaneIndex: targetLaneIndex, audioClips: audioClips) {
                        clearSelection()
                        selectedAudioClipId = nearestClip.clip.id
                        selectedAudioClipIds.insert(nearestClip.clip.id)
                        selectedAudioLaneId = nearestClip.lane.id
                    }
                }
            }
        } else {
            // Move down: from video to audio track, or from upper lane to lower lane
            if selectedVideoReelId != nil {
                // Move from video track to first audio lane
                if let nearestClip = findNearestAudioClip(at: currentFrame, inLaneIndex: 0, audioClips: audioClips) {
                    clearSelection()
                    selectedAudioClipId = nearestClip.clip.id
                    selectedAudioClipIds.insert(nearestClip.clip.id)
                    selectedAudioLaneId = nearestClip.lane.id
                }
            } else if let selectedId = selectedAudioClipId,
                      let currentItem = audioClips.first(where: { $0.clip.id == selectedId }) {
                // Move to lower audio lane
                let targetLaneIndex = currentItem.laneIndex + 1
                if targetLaneIndex < timeline.audioLanes.count {
                    if let nearestClip = findNearestAudioClip(at: currentFrame, inLaneIndex: targetLaneIndex, audioClips: audioClips) {
                        clearSelection()
                        selectedAudioClipId = nearestClip.clip.id
                        selectedAudioClipIds.insert(nearestClip.clip.id)
                        selectedAudioLaneId = nearestClip.lane.id
                    }
                }
            } else if !videoReels.isEmpty {
                // Nothing selected - start with video track
                if let nearestReel = findNearestVideoReel(at: currentFrame, in: videoReels) {
                    clearSelection()
                    selectedVideoReelId = nearestReel.id
                    selectedVideoReelIds.insert(nearestReel.id)
                }
            }
        }
    }

    /// Find the video reel closest to the given frame
    private func findNearestVideoReel(at frame: Int, in reels: [VideoReel]) -> VideoReel? {
        reels.min { abs($0.timelineStartFrame - frame) < abs($1.timelineStartFrame - frame) }
    }

    /// Find the audio clip closest to the given frame in a specific lane
    private func findNearestAudioClip(at frame: Int, inLaneIndex laneIndex: Int, audioClips: [(lane: AudioLane, clip: AudioClip, laneIndex: Int)]) -> (lane: AudioLane, clip: AudioClip, laneIndex: Int)? {
        let laneClips = audioClips.filter { $0.laneIndex == laneIndex }
        return laneClips.min { abs($0.clip.timelineStartFrame - frame) < abs($1.clip.timelineStartFrame - frame) }
    }
}

private struct DragCaptureView: NSViewRepresentable {
    /// Called when drag enters - should also return the operation to accept/reject
    var onEntered: (NSDraggingInfo, CGPoint) -> NSDragOperation
    var onUpdated: (NSDraggingInfo, CGPoint) -> NSDragOperation
    var onExited: () -> Void
    var onPerform: (NSDraggingInfo, CGPoint) -> Bool

    func makeNSView(context: Context) -> DragCaptureNSView {
        let view = DragCaptureNSView()
        view.onEntered = onEntered
        view.onUpdated = onUpdated
        view.onExited = onExited
        view.onPerform = onPerform
        return view
    }

    func updateNSView(_ nsView: DragCaptureNSView, context: Context) {
        nsView.onEntered = onEntered
        nsView.onUpdated = onUpdated
        nsView.onExited = onExited
        nsView.onPerform = onPerform
    }
}

private final class DragCaptureNSView: NSView {
    var onEntered: ((NSDraggingInfo, CGPoint) -> NSDragOperation)?
    var onUpdated: ((NSDraggingInfo, CGPoint) -> NSDragOperation)?
    var onExited: (() -> Void)?
    var onPerform: ((NSDraggingInfo, CGPoint) -> Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([
            .fileURL,
            .URL,
            NSPasteboard.PasteboardType("com.projector.media-item"),
            NSPasteboard.PasteboardType("public.item")
        ])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([
            .fileURL,
            .URL,
            NSPasteboard.PasteboardType("com.projector.media-item"),
            NSPasteboard.PasteboardType("public.item")
        ])
    }

    // CRITICAL: Pass through all mouse events to underlying SwiftUI views
    // This view only handles drag-and-drop operations from external sources
    // We override hitTest to return nil for regular mouse events,
    // but drag-and-drop uses a separate registration system that bypasses hitTest
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Return nil so clicks/drags/scrolls pass through to SwiftUI views underneath
        // Drag-and-drop events still work because they use registerForDraggedTypes
        nil
    }

    // Ensure mouse events pass through to SwiftUI views underneath
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

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
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

/// Separate view for playhead to avoid re-rendering entire timeline on every frame update.
///
/// By isolating the playback engine observation here, only this small view re-renders
/// at display refresh rate, not the entire tracks section.
private struct PlayheadView: View {
    @ObservedObject var playbackEngine: PlaybackEngine
    let pixelsPerFrame: CGFloat
    let horizontalScrollOffset: CGFloat
    let totalHeight: CGFloat

    var body: some View {
        let documentX = TimelineLayout.headerWidth + (CGFloat(playbackEngine.currentFrame) * pixelsPerFrame)
        let xOffset = documentX - horizontalScrollOffset - 1

        if xOffset >= TimelineLayout.headerWidth - TimelineLayout.playheadTriangleWidth {
            VStack(spacing: 0) {
                Triangle()
                    .fill(Color.accentColor)
                    .frame(width: TimelineLayout.playheadTriangleWidth, height: TimelineLayout.playheadTriangleHeight)
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2)
            }
            .frame(height: totalHeight)
            .offset(x: xOffset)
            .allowsHitTesting(false)
        }
    }
}

/// Isolated transport controls that observe PlaybackEngine independently.
/// This prevents the entire MultiTrackTimelineView from re-rendering on playback state changes.
private struct TransportControlsView: View {
    @ObservedObject var playbackEngine: PlaybackEngine

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Button(action: { playbackEngine.stepBackward() }) {
                Image(systemName: "backward.fill")
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .disabled(!playbackEngine.hasContent)
            .help("Step back one frame")
            .accessibilityLabel("Step back one frame")

            Button(action: { playbackEngine.togglePlayback() }) {
                Image(systemName: playbackEngine.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .disabled(!playbackEngine.hasContent)
            .keyboardShortcut(.space, modifiers: [])
            .help(playbackEngine.isPlaying ? "Pause (Space)" : "Play (Space)")
            .accessibilityLabel(playbackEngine.isPlaying ? "Pause" : "Play")

            Button(action: { playbackEngine.stepForward() }) {
                Image(systemName: "forward.fill")
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .disabled(!playbackEngine.hasContent)
            .help("Step forward one frame")
            .accessibilityLabel("Step forward one frame")

            Button(action: { playbackEngine.stop() }) {
                Image(systemName: "stop.fill")
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .disabled(!playbackEngine.hasContent)
            .help("Stop and return to start")
            .accessibilityLabel("Stop and return to start")
        }
    }
}

#Preview {
    struct PreviewWrapper: View {
        @StateObject var timelineManager = TimelineManager()
        @StateObject var playbackEngine = PlaybackEngine()
        @StateObject var waveformCache = WaveformCache()
        @StateObject var audioOutputManager = AudioOutputManager()
        @StateObject var thumbnailCache = ThumbnailCache()
        @StateObject var mediaLibrary = ProjectMediaLibrary()
        @State var zoomLevel: CGFloat = 0.0

        var body: some View {
            MultiTrackTimelineView(
                timelineManager: timelineManager,
                playbackEngine: playbackEngine,
                waveformCache: waveformCache,
                audioOutputManager: audioOutputManager,
                thumbnailCache: thumbnailCache,
                mediaLibrary: mediaLibrary,
                onDropVideoMedia: { _, _, _ in },
                onDropAudioMedia: { _, _, _, _ in },
                onSeek: { _ in },
                onSettingsPressed: { },
                zoomLevel: $zoomLevel
            )
            .frame(width: 800, height: 300)
            .environmentObject(DragContext())
        }
    }

    return PreviewWrapper()
}

private struct TimelineDebugFlags {
    let disableWaveforms: Bool
    let disableThumbnails: Bool
    let disableRulerGesture: Bool
    let disableClipInteractions: Bool

    static var current: TimelineDebugFlags {
        let arguments = ProcessInfo.processInfo.arguments
        return TimelineDebugFlags(
            disableWaveforms: arguments.contains("-debug-disable-waveforms"),
            disableThumbnails: arguments.contains("-debug-disable-thumbnails"),
            disableRulerGesture: arguments.contains("-debug-disable-ruler-gesture"),
            disableClipInteractions: arguments.contains("-debug-disable-clip-interactions")
        )
    }
}

