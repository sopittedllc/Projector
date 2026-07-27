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
    @ObservedObject var playbackEngine: PlaybackEngine
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

    // MARK: - State

    @State private var isHoveringStartTC = false
    @State private var isHoveringDuration = false
    @State private var editingStartTCText = ""
    @State private var editingDurationText = ""
    @State private var isStartTCFocused: Bool = false
    @State private var isDurationFocused: Bool = false
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

    /// Whether the video file's baked-in audio strip is shown.
    ///
    /// Collapsing it leaves the Video File track as a single picture row, for
    /// when the embedded audio is not what you are working on.
    @State private var isVideoAudioExpanded = true
    @State private var scrollAreaFrame: CGRect = .zero

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

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar (TC display + zoom controls) - only if showHeader is true
            if showHeader {
                headerSection
            }

            // Timeline area (ruler + tracks with unified playhead)
            tracksSection
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .focusable()
        .focusEffectDisabled()
        .focused($isTimelineFocused)
        .onDeleteCommand {
            deleteSelectedItem()
        }
        .onKeyPress(.return) {
            // Yield to an active text field: Return there means "commit".
            guard !isEditingText else { return .ignored }
            playbackEngine.stop()
            return .handled
        }
        .sheet(isPresented: $showTimecodeEntryDialog) {
            timecodeEntryDialogContent
        }
        .alert("Paste Failed", isPresented: $showPasteError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(pasteErrorMessage)
        }
        // Take focus when a clip is selected
        .onChange(of: selectedVideoReelId) { _, newValue in
            if newValue != nil {
                isTimelineFocused = true
            }
        }
        .onChange(of: selectedAudioClipId) { _, newValue in
            if newValue != nil {
                isTimelineFocused = true
            }
        }
        // Update cached active clip IDs when frame changes (throttled)
        .onChange(of: playbackEngine.currentFrame) { _, _ in
            updateActiveAudioClipIds()
            scrollPlayheadIntoViewIfNeeded()
        }
        // Track horizontal scroll so the ruler and playhead can be drawn in the
        // same coordinate space as the scrolling track content. Without this
        // they only agree at fit-to-view, where the scroll offset is always 0.
        .onChange(of: cachedScrollView) { _, scrollView in
            scrollView?.contentView.postsBoundsChangedNotifications = true
            horizontalScrollOffset = scrollView?.contentView.bounds.origin.x ?? 0
        }
        .onReceive(NotificationCenter.default.publisher(for: NSView.boundsDidChangeNotification)) { note in
            guard let clipView = note.object as? NSClipView,
                  clipView === cachedScrollView?.contentView else { return }
            horizontalScrollOffset = clipView.bounds.origin.x
        }
        .onAppear {
            updateActiveAudioClipIds()
        }
        // Edit menu notification handlers
        .onReceive(NotificationCenter.default.publisher(for: .editUndo)) { _ in
            guard isTimelineFocused else { return }
            undoManager?.undo()
        }
        .onReceive(NotificationCenter.default.publisher(for: .editRedo)) { _ in
            guard isTimelineFocused else { return }
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
        // Escape key to deselect all
        .onKeyPress(.escape) {
            // Yield: Escape in a text field means "cancel the edit".
            guard !isEditingText else { return .ignored }
            deselectAll()
            return .handled
        }
        // Arrow keys for navigation
        .onKeyPress(.leftArrow) {
            // Yield: arrows move the insertion point while editing text.
            guard !isEditingText else { return .ignored }
            navigateSelection(direction: .left)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            // Yield: arrows move the insertion point while editing text.
            guard !isEditingText else { return .ignored }
            navigateSelection(direction: .right)
            return .handled
        }
        .onKeyPress(.upArrow) {
            // Yield: arrows move the insertion point while editing text.
            guard !isEditingText else { return .ignored }
            navigateSelection(direction: .up)
            return .handled
        }
        .onKeyPress(.downArrow) {
            // Yield: arrows move the insertion point while editing text.
            guard !isEditingText else { return .ignored }
            navigateSelection(direction: .down)
            return .handled
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
                .onChange(of: timecodeEntryText) { _, newValue in
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

        // Check if region would extend beyond timeline duration
        let regionEndFrame = newFrame + regionDuration
        if regionEndFrame > timeline.config.durationFrames {
            let maxStartFrame = timeline.config.durationFrames - regionDuration
            let maxStartTC = Timecode(.frames(maxStartFrame + timeline.config.startTimecode.frameCount.wholeFrames), at: timeline.config.frameRate, by: .clamping)
            timecodeEntryError = "Region would extend beyond timeline.\nMax start: \(maxStartTC.stringValue())"
            return
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
            // Toolbar: Start TC | Duration | FPS | Transport | Zoom | Settings
            HStack(spacing: Spacing.md) {
                // Start timecode (editable)
                startTCBox

                // Duration (editable)
                durationBox

                // Frame rate (dropdown)
                fpsBox

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

                // Settings button
                Button(action: onSettingsPressed) {
                    Image(systemName: "gearshape")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("Timeline settings")
                .accessibilityLabel("Timeline settings")
            }
            .padding(.horizontal, Spacing.md)
            .frame(height: TimelineLayout.toolbarHeight)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))

            Divider()
        }
    }

    private var transportControls: some View {
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
                // Use simultaneousGesture instead of onTapGesture for consistency (GP-003)
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
            .onChange(of: editingStartTCText) { _, newValue in
                let formatted = formatTimecodeInput(newValue)
                if formatted != newValue {
                    editingStartTCText = formatted
                }
            }
            .onChange(of: isStartTCFocused) { _, focused in
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

    private var durationBox: some View {
        HStack(spacing: Spacing.xs) {
            Text("Duration:")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize()

            TransparentTextField(
                text: $editingDurationText,
                placeholder: "00:00:00:00",
                font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
                onSubmit: {
                    applyDuration()
                },
                onEscape: {
                    editingDurationText = durationTimecodeString
                },
                isFocused: $isDurationFocused
            )
            .frame(width: 85)
            .onChange(of: editingDurationText) { _, newValue in
                let formatted = formatTimecodeInput(newValue)
                if formatted != newValue {
                    editingDurationText = formatted
                }
            }
            .onChange(of: isDurationFocused) { _, focused in
                // Save on blur
                if !focused {
                    applyDuration()
                }
            }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(durationBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isDurationFocused ? Color.accentColor : AppColors.borderLight, lineWidth: PanelLayout.borderWidth)
        )
        .onHover { hovering in
            isHoveringDuration = hovering
        }
        .onChange(of: timeline.config.durationFrames) { _, _ in
            if !isDurationFocused {
                editingDurationText = durationTimecodeString
            }
        }
        .onAppear {
            editingDurationText = durationTimecodeString
        }
    }

    private var durationBackground: Color {
        if isDurationFocused {
            return Color(nsColor: .controlBackgroundColor)
        } else if isHoveringDuration {
            return Color.white.opacity(0.08)
        } else {
            return Color.white.opacity(0.04)
        }
    }

    private var fpsBox: some View {
        HStack(spacing: Spacing.xs) {
            Text("FPS:")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize()

            Menu {
                ForEach(availableFrameRates, id: \.self) { rate in
                    Button(rate.displayName) {
                        changeFrameRate(to: rate)
                    }
                }
            } label: {
                Text(timeline.config.frameRate.displayName)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .frame(minWidth: 50)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
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
        // Update text fields
        editingStartTCText = config.startTimecode.stringValue()
        editingDurationText = durationTimecodeString
    }

    /// Duration as a timecode string (HH:MM:SS:FF)
    private var durationTimecodeString: String {
        let durationTC = Timecode(.frames(timeline.config.durationFrames), at: timeline.config.frameRate, by: .clamping)
        return durationTC.stringValue()
    }

    /// Format timecode input as the user types, inserting colons every 2 digits
    private func formatTimecodeInput(_ input: String) -> String {
        let digits = input.filter { $0.isNumber }
        let limited = String(digits.prefix(8))
        var result = ""
        for (index, char) in limited.enumerated() {
            if index > 0 && index % 2 == 0 {
                result += ":"
            }
            result.append(char)
        }
        return result
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

    private func applyDuration() {
        isDurationFocused = false
        if let durationTC = parseTimecode(editingDurationText) {
            let durationFrames = durationTC.frameCount.wholeFrames
            let newEndFrames = timeline.config.startTimecode.frameCount.wholeFrames + durationFrames
            let newEnd = Timecode(.frames(newEndFrames), at: timeline.config.frameRate, by: .clamping)
            timelineManager.setTimelineBounds(start: timeline.config.startTimecode, end: newEnd)
            editingDurationText = durationTimecodeString
        } else {
            // Reset to current value if invalid
            editingDurationText = durationTimecodeString
        }
    }

    private func parseTimecode(_ string: String) -> Timecode? {
        let digits = string.filter { $0.isNumber }
        let padded = String(repeating: "0", count: max(0, 8 - digits.count)) + digits
        let trimmed = String(padded.suffix(8))
        guard trimmed.count == 8 else { return nil }

        let h = Int(trimmed.prefix(2)) ?? 0
        let m = Int(trimmed.dropFirst(2).prefix(2)) ?? 0
        let s = Int(trimmed.dropFirst(4).prefix(2)) ?? 0
        let f = Int(trimmed.dropFirst(6).prefix(2)) ?? 0

        return Timecode(
            .components(h: h, m: m, s: s, f: f),
            at: timeline.config.frameRate,
            by: .clamping
        )
    }

    // MARK: - Tracks Section

    private var tracksSection: some View {
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
                    Color.clear.frame(width: TimelineLayout.headerWidth)

                    let rulerWidth = max(contentAreaWidth, CGFloat(timeline.config.durationFrames) * ppf)
                    let ruler = TimelineRulerView(
                        duration: playbackEngine.duration,
                        frameRate: timeline.config.frameRate,
                        currentTime: playbackEngine.currentTime
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
                    VStack(spacing: 0) {
                        // Invisible helper to capture NSScrollView reference for auto-scroll
                        ScrollViewCaptureHelper(scrollView: $cachedScrollView)
                            .frame(width: 0, height: 0)

                        Spacer().frame(height: Spacing.xs)

                        // Video track
                        VideoTrackView(
                            timelineManager: timelineManager,
                            playbackEngine: playbackEngine,
                            thumbnailCache: thumbnailCache,
                            mediaLibrary: mediaLibrary,
                            pixelsPerFrame: ppf,
                            scrollOffset: 0,
                            showThumbnails: !debug.disableThumbnails,
                            clipInteractionsEnabled: !debug.disableClipInteractions,
                            onDropMedia: onDropVideoMedia,
                            onDropMixedMedia: onDropMixedMedia,
                            onReelRename: { reelId, newName in
                                timelineManager.renameVideoReel(id: reelId, name: newName)
                            },
                            onReelSelected: { reelId, modifiers in
                                handleReelSelection(reelId: reelId, modifiers: modifiers)
                            },
                            onReelDoubleClick: { reel in
                                editingReelId = reel.id
                                let tc = Timecode(.frames(reel.timelineStartFrame + timeline.config.startTimecode.frameCount.wholeFrames), at: timeline.config.frameRate, by: .clamping)
                                timecodeEntryText = tc.stringValue()
                                showTimecodeEntryDialog = true
                            },
                            onReelMove: { reelId, newFrame in
                                guard let reel = timelineManager.timeline.videoReels.first(where: { $0.id == reelId }),
                                      reel.timelineStartFrame != newFrame else { return }
                                registerVideoReelMoveUndo(reelId: reelId, from: reel.timelineStartFrame)
                                timelineManager.moveVideoReel(id: reelId, to: newFrame)
                            },
                            linkedDragPreview: linkedDragPreview,
                            onReelDragPreview: { reel, previewFrame in
                                if let previewFrame {
                                    linkedDragPreview = LinkedDragPreview(
                                        sourceURL: reel.sourceURL,
                                        sourceStartFrame: reel.sourceStartFrame,
                                        durationFrames: reel.durationFrames,
                                        fromFrame: reel.timelineStartFrame,
                                        toFrame: previewFrame
                                    )
                                } else {
                                    linkedDragPreview = nil
                                }
                            },
                            selectedReelIds: selectedVideoReelIds,
                            availableAudioOutputs: audioOutputManager.mappedOutputs
                        )
                        .frame(width: totalContentWidth, height: TimelineLayout.videoTrackHeight)
                        .overlay(alignment: .top) {
                            laneBorder
                        }

                        // The video file's own audio, drawn as a short strip
                        // directly beneath the picture with no divider between
                        // them, so the two read as one Video File track. Its
                        // controls are in the video header above.
                        if let linked = timeline.videoAudioLane,
                           let linkedIndex = timeline.audioLanes.firstIndex(where: { $0.id == linked.id }),
                           isVideoAudioExpanded {
                            linkedAudioStrip(lane: linked, index: linkedIndex, ppf: ppf, width: totalContentWidth)
                        }

                        Divider()

                        // Audio lanes the user added. The video file's own audio
                        // is excluded - it is part of the track above, and would
                        // otherwise appear twice.
                        ForEach(Array(timeline.standaloneAudioLanes.enumerated()), id: \.element.id) { _, lane in
                            let index = timeline.audioLanes.firstIndex(where: { $0.id == lane.id }) ?? 0
                            AudioLaneView(
                                lane: lane,
                                laneIndex: index,
                                activeClipIds: activeAudioClipIds,
                                waveformCache: waveformCache,
                                pixelsPerFrame: ppf,
                                frameRate: timeline.config.frameRate,
                                scrollOffset: 0,
                                timelineDurationFrames: timeline.config.durationFrames,
                                showWaveforms: !debug.disableWaveforms,
                                clipInteractionsEnabled: !debug.disableClipInteractions,
                                availableAudioOutputs: audioOutputManager.mappedOutputs,
                                linkedDragPreview: linkedDragPreview,
                                timelineStartFrames: timeline.config.startTimecode.frameCount.wholeFrames,
                                mediaLibrary: mediaLibrary,
                                onMuteToggle: { timelineManager.toggleLaneMute(at: index) },
                                onSoloToggle: { timelineManager.toggleLaneSolo(at: index) },
                                onVolumeChange: { volume in timelineManager.setLaneVolume(at: index, volume: volume) },
                                onOutputMappingChange: { output in timelineManager.setLaneOutputMapping(id: lane.id, mapping: output) },
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
                            .overlay(alignment: .bottom) {
                                if index == timeline.audioLanes.count - 1 {
                                    laneBorder
                                }
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
            // Playhead overlay spanning full height
            .overlay(alignment: .topLeading) {
                playhead(pixelsPerFrame: ppf, totalHeight: geometry.size.height)
                    .allowsHitTesting(false)
            }
            // NOTE: the whole-timeline drop highlight was removed here.
            //
            // It lit the entire track area when files were dragged over it,
            // which promised a drop the timeline never accepted - drops are
            // handled per lane, and the parent drag capture deliberately never
            // claims them. Highlighting the target the user cannot use, while
            // the lane they *can* use highlights too, read as the timeline
            // rejecting a legitimate drop.
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

    // NOTE: `handleMultiFileDropNative` was removed here. It had no call sites -
    // the parent DragCaptureView deliberately never claims drops (see its
    // onPerform above), so multi-file drops are routed by the per-lane handlers
    // instead. It also hardcoded a drop frame of 0, so wiring it up as-written
    // would have silently ignored the cursor position on every batch drop.

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
        let documentX = TimelineLayout.headerWidth + (CGFloat(playbackEngine.currentFrame) * pixelsPerFrame)
        let xOffset = documentX - horizontalScrollOffset - 1 // -1 for half width

        if xOffset >= TimelineLayout.headerWidth - TimelineLayout.playheadTriangleWidth {
            VStack(spacing: 0) {
                // Triangle at top
                Triangle()
                    .fill(Color.accentColor)
                    .frame(width: TimelineLayout.playheadTriangleWidth, height: TimelineLayout.playheadTriangleHeight)
                // Vertical line
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2)
            }
            .frame(height: totalHeight)
            .offset(x: xOffset)
            .allowsHitTesting(false)
        }
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
    /// The video file's baked-in audio, as a short strip under the picture.
    ///
    /// Reuses `AudioLaneView` at a third height with its header suppressed, so
    /// clips, waveforms and selection behave exactly as they do on any lane -
    /// only the chrome differs.
    private func linkedAudioStrip(lane: AudioLane, index: Int, ppf: CGFloat, width: CGFloat) -> some View {
        AudioLaneView(
            lane: lane,
            laneIndex: index,
            activeClipIds: activeAudioClipIds,
            waveformCache: waveformCache,
            pixelsPerFrame: ppf,
            frameRate: timeline.config.frameRate,
            scrollOffset: 0,
            timelineDurationFrames: timeline.config.durationFrames,
            showWaveforms: !TimelineDebugFlags.current.disableWaveforms,
            clipInteractionsEnabled: !TimelineDebugFlags.current.disableClipInteractions,
            availableAudioOutputs: audioOutputManager.mappedOutputs,
            linkedDragPreview: linkedDragPreview,
            timelineStartFrames: timeline.config.startTimecode.frameCount.wholeFrames,
            mediaLibrary: mediaLibrary,
            onMuteToggle: { timelineManager.toggleLaneMute(at: index) },
            onSoloToggle: { timelineManager.toggleLaneSolo(at: index) },
            onVolumeChange: { volume in timelineManager.setLaneVolume(at: index, volume: volume) },
            onOutputMappingChange: { output in
                timelineManager.setLaneOutputMapping(id: lane.id, mapping: output)
            },
            // Nothing may be dropped here: this lane is the video file's own
            // audio, one clip per reel, and anything else landing on it would
            // stop it being that.
            onDropMedia: { _, _, _ in },
            onDropMixedMedia: nil,
            onClipSelected: { clipId, modifiers in
                handleClipSelection(clipId: clipId, laneId: lane.id, modifiers: modifiers)
            },
            onClipDoubleClick: { _ in },
            onClipMove: { _, _ in },
            onClipDragPreview: { _, _ in },
            onLaneRename: { _ in },
            // Deleting the audio deletes the video it came from: they are one
            // file, so removing half would leave picture with no sound or the
            // reverse, which the timeline has no way to represent.
            onDeleteLane: { deleteVideoFileTrack() },
            laneHeight: TimelineLayout.linkedAudioStripHeight,
            showsHeader: false,
            onClipLaneChangeRequested: nil,
            onClipLaneChangePreview: nil,
            laneChangePreview: nil,
            selectedClipIds: selectedAudioClipIds
        )
        .frame(width: width, height: TimelineLayout.linkedAudioStripHeight)
    }

    /// Remove the video reels and the audio baked into them, together.
    private func deleteVideoFileTrack() {
        registerTimelineUndo(actionName: "Delete Video File")
        for reel in timelineManager.timeline.videoReels {
            removeLinkedAudio(for: reel, cleanupLanes: false)
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


    private var laneBorder: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(0.5))
            .frame(height: 1)
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
        guard !urls.isEmpty else {
            clearEmptyAudioDrop()
            return false
        }
        let targetFrame = max(0, Int(location.x / max(pixelsPerFrame, 0.001)))
        let isInternal = dragContext.isDragging
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

private struct EmptyAudioLaneDropDelegate: DropDelegate {
    @Binding var isDropAllowed: Bool
    let enterHandler: ([NSItemProvider], CGPoint) -> Void
    let exitHandler: () -> Void
    let dropHandler: ([NSItemProvider], CGPoint) -> Bool
    let updateHandler: (CGPoint) -> Void
    private let supportedTypes: [UTType] = [.item]
    let isLoading: () -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        !info.itemProviders(for: supportedTypes).isEmpty
    }

    func dropEntered(info: DropInfo) {
        let providers = info.itemProviders(for: supportedTypes)
        enterHandler(providers, info.location)
    }

    func dropExited(info: DropInfo) {
        exitHandler()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateHandler(info.location)
        return DropProposal(operation: .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        exitHandler()
        let providers = info.itemProviders(for: supportedTypes)
        return dropHandler(providers, info.location)
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

// MARK: - Transparent TextField

/// A TextField that removes all macOS system styling (focus ring, background)
/// so parent views can apply custom styling without interference.
private struct TransparentTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    var font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .medium)
    var alignment: NSTextAlignment = .left
    var onSubmit: (() -> Void)?
    var onEscape: (() -> Void)?

    @Binding var isFocused: Bool

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField()
        textField.delegate = context.coordinator
        textField.isBordered = false
        textField.drawsBackground = false
        textField.backgroundColor = .clear
        textField.focusRingType = .none
        textField.font = font
        textField.alignment = alignment
        textField.placeholderString = placeholder
        textField.cell?.sendsActionOnEndEditing = true
        return textField
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.font = font
        nsView.alignment = alignment
        nsView.placeholderString = placeholder

        // Handle focus changes from SwiftUI
        DispatchQueue.main.async {
            if isFocused && nsView.window?.firstResponder != nsView.currentEditor() {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TransparentTextField

        init(_ parent: TransparentTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let textField = obj.object as? NSTextField else { return }
            parent.text = textField.stringValue
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            DispatchQueue.main.async {
                self.parent.isFocused = true
            }
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            DispatchQueue.main.async {
                self.parent.isFocused = false
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                // Return key pressed
                parent.onSubmit?()
                // Resign first responder to exit edit mode
                control.window?.makeFirstResponder(nil)
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                // Escape key pressed
                parent.onEscape?()
                control.window?.makeFirstResponder(nil)
                return true
            }
            return false
        }
    }
}
