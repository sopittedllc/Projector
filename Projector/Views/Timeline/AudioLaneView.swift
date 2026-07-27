import SwiftUI
import Foundation
import UniformTypeIdentifiers
import SwiftTimecodeCore
import AVFoundation
import AppKit

/// Audio lane container showing clips and lane controls
struct AudioLaneView: View {
    let lane: AudioLane
    let laneIndex: Int
    let activeClipIds: Set<UUID>
    let waveformCache: WaveformCache
    let pixelsPerFrame: CGFloat
    let frameRate: TimecodeFrameRate
    let scrollOffset: CGFloat
    let timelineDurationFrames: Int
    let showWaveforms: Bool
    let clipInteractionsEnabled: Bool
    let availableAudioOutputs: [MappedAudioOutput]
    let linkedDragPreview: LinkedDragPreview?
    let timelineStartFrames: Int
    @ObservedObject var mediaLibrary: ProjectMediaLibrary
    let onMuteToggle: () -> Void
    let onSoloToggle: () -> Void
    let onVolumeChange: (Float) -> Void
    let onOutputMappingChange: (MappedAudioOutput?) -> Void

    /// Route the lane to nothing, silencing it.
    let onOutputNone: () -> Void
    let onDropMedia: ([URL], Int, Bool) -> Void
    /// Called when a drop contains BOTH video and audio files.
    ///
    /// - Parameters:
    ///   - videoURLs: Array of video file URLs from the drop
    ///   - audioURLs: Array of audio file URLs from the drop
    ///   - targetFrame: Timeline frame position where the drop occurred
    var onDropMixedMedia: (([URL], [URL], Int) -> Void)?
    let onClipSelected: (UUID?, SelectionModifiers) -> Void
    let onClipDoubleClick: (AudioClip) -> Void
    let onClipSetTimelineStart: (AudioClip) -> Void
    let onClipMove: (UUID, Int) -> Void
    let onClipDragPreview: (AudioClip, Int?) -> Void
    let onLaneRename: (String) -> Void

    /// Remove this lane and everything on it.
    let onDeleteLane: () -> Void

    /// Height of the lane row.
    ///
    /// Short for the video file's baked-in audio, which is drawn as a strip
    /// under the video rather than a lane of its own.
    var laneHeight: CGFloat = TimelineLayout.audioLaneHeight

    /// Whether to draw the lane's own header column.
    ///
    /// Off for the video file's audio: its controls live in the combined Video
    /// File track header above it, so a second header would duplicate them.
    var showsHeader: Bool = true
    /// Called when a video-linked clip is dragged vertically to change lanes
    /// Parameters: clipId, laneOffset (+1 = next lane down, -1 = previous lane up)
    let onClipLaneChangeRequested: ((UUID, Int) -> Void)?
    /// Called during vertical drag to show preview in target lane
    /// Parameters: clip, targetLaneOffset (nil to clear preview)
    let onClipLaneChangePreview: ((AudioClip, Int?) -> Void)?
    /// Preview of a clip being dragged to this lane from another lane
    let laneChangePreview: LaneChangePreview?
    /// Set of clip IDs selected via marquee selection (from parent)
    var selectedClipIds: Set<UUID> = []

    @State private var selectedClipId: UUID?
    @State private var isDropTargeted = false
    @State private var dropPreviewFrame: Int?
    @State private var dropPreviewDurationFrames: Int?
    @State private var isLoadingDropPreview = false
    @State private var isDropAllowed = false
    @State private var latestDropLocation: CGPoint?
    @State private var isExpanded = true
    @State private var isEditingName = false
    @State private var editedName = ""
    @State private var draggingClipId: UUID?
    @State private var dragStartFrame: Int = 0
    @State private var dragOffsetFrames: Int = 0
    @State private var dragVerticalOffset: CGFloat = 0
    @FocusState private var isNameFieldFocused: Bool
    @EnvironmentObject private var dragContext: DragContext

    /// Whether we're in a multi-file drag from the media panel
    private var isMultiFileDrag: Bool {
        dragContext.mediaItems.count > 1
    }

    /// Check if NSDraggingInfo represents a multi-file external drag
    private func isMultiFileExternalDrag(_ info: NSDraggingInfo) -> Bool {
        guard dragContext.mediaItems.isEmpty else { return false }
        let pasteboardItems = info.draggingPasteboard.pasteboardItems ?? []
        return pasteboardItems.count > 1
    }

    var body: some View {
        HStack(spacing: 0) {
            if showsHeader {
                laneHeader
            } else {
                // Keep the clips aligned with every other lane even when the
                // header column is not drawn.
                Color.clear.frame(width: TimelineLayout.headerWidth)
            }

            clipsArea
        }
        .frame(height: laneHeight)
        .background(laneBackground)
        // Covers the header and the empty track area. Clips carry their own
        // menu, which takes precedence where one is under the cursor - so
        // right-clicking a clip still offers clip actions, not lane actions.
        .contextMenu {
            Button(deleteLaneTitle, role: .destructive) {
                onDeleteLane()
            }
        }
        .onAppear {
            applyDefaultMappingIfNeeded()
        }
        .onChange(of: availableAudioOutputs) { _, _ in
            applyDefaultMappingIfNeeded()
        }
    }

    /// Names what will be lost, so deleting a lane holding work is a
    /// deliberate act rather than the same click as deleting an empty one.
    private var deleteLaneTitle: String {
        switch lane.clips.count {
        case 0: return "Delete Lane"
        case 1: return "Delete Lane and 1 Clip"
        case let count: return "Delete Lane and \(count) Clips"
        }
    }

    // MARK: - Lane Background

    private var laneBackground: some View {
        // Alternate lane backgrounds for visual separation
        let baseOpacity = laneIndex.isMultiple(of: 2) ? 0.03 : 0.06
        return Color.white
            .opacity(lane.isMuted ? baseOpacity * 0.5 : baseOpacity)
    }

    // MARK: - Lane Header

    private var laneHeader: some View {
        HStack(spacing: 0) {
            // Left padding to align with panel header
            Spacer()
                .frame(width: Spacing.md)

            VStack(spacing: Spacing.xs) {
                // Lane name (editable on double-click)
                if isEditingName {
                    // Inline rename, standard macOS semantics: Return commits,
                    // Escape reverts, clicking away commits, and the existing
                    // text is selected on entry so typing replaces it.
                    TextField("", text: $editedName)
                        .font(.system(size: 10, weight: .medium))
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.center)
                        .focused($isNameFieldFocused)
                        .onSubmit { commitNameEdit() }
                        .onExitCommand { cancelNameEdit() }
                        .onChange(of: isNameFieldFocused) { _, focused in
                            if focused {
                                selectAllInFieldEditor()
                            } else if isEditingName {
                                // Clicking away commits, matching Finder.
                                commitNameEdit()
                            }
                        }
                        .frame(maxWidth: TimelineLayout.headerWidth - Spacing.md - Spacing.sm - 12)
                        .help("Return to rename, Escape to cancel")
                } else {
                    // Button rather than onTapGesture: a tap gesture inside scrollable
                    // content delays trackpad scrolling.
                    Button(action: {}) {
                        Text(lane.name)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(
                        TapGesture(count: 2)
                            .onEnded { _ in
                                startNameEdit()
                            }
                    )
                    .help("\(lane.name) - double-click to rename")
                    .accessibilityLabel("Lane name: \(lane.name)")
                }

                // Shared with the combined Video File track's header, so a
                // lane's controls and the video's baked-in audio controls are
                // the same component rather than two that drift apart.
                AudioLaneControls(
                    lane: lane,
                    availableAudioOutputs: availableAudioOutputs,
                    onMuteToggle: onMuteToggle,
                    onSoloToggle: onSoloToggle,
                    onOutputMappingChange: onOutputMappingChange,
                    onOutputNone: onOutputNone
                )
            }
            .frame(maxWidth: .infinity)

            Spacer()
                .frame(width: Spacing.sm)
        }
        .frame(width: TimelineLayout.headerWidth, height: laneHeight)
    }



    private func startNameEdit() {
        editedName = lane.name
        isEditingName = true
        // Delay focus to ensure TextField is rendered
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            isNameFieldFocused = true
        }
    }

    /// Commit the edit. An empty or whitespace-only name reverts rather than
    /// being accepted - a nameless lane is unusable, and silently keeping the
    /// old name is what Finder and Logic both do.
    private func commitNameEdit() {
        guard isEditingName else { return }   // guards a double-commit from submit + blur
        isEditingName = false
        isNameFieldFocused = false

        let trimmed = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != lane.name else { return }
        onLaneRename(trimmed)
    }

    private func cancelNameEdit() {
        isEditingName = false
        isNameFieldFocused = false
        editedName = lane.name
    }

    /// Select the whole name when the field takes focus, so typing replaces it.
    ///
    /// SwiftUI has no API for this on macOS; the field editor is an NSTextView
    /// owned by the window, so we reach it through the first responder.
    private func selectAllInFieldEditor() {
        DispatchQueue.main.async {
            guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
            editor.selectAll(nil)
        }
    }


    /// Get display name for current output device

    private func applyDefaultMappingIfNeeded() {
        // A lane routed to None has an answer already - it is just not an output.
        guard !lane.isOutputDisabled,
              lane.outputMappingId == nil,
              !availableAudioOutputs.isEmpty else { return }
        let index = min(laneIndex, max(0, availableAudioOutputs.count - 1))
        onOutputMappingChange(availableAudioOutputs[index])
    }

    // MARK: - Clips Area

    private var clipsArea: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background with drop zone
                dropZoneBackground

                // Clips
                clipsContent

                // Lane change preview ghost (orange)
                if let preview = laneChangePreview, preview.targetLaneIndex == laneIndex {
                    laneChangePreviewGhost(preview: preview, height: geometry.size.height)
                }

                // Show preview for all drops (single and multi-file)
                if (isDropAllowed || isLoadingDropPreview), let previewFrame = dropPreviewFrame {
                    dropPreviewOverlay(frame: previewFrame, height: geometry.size.height, width: geometry.size.width)
                }

            }
            .frame(maxWidth: .infinity, maxHeight: .infinity) // Ensure ZStack fills available space
            .contentShape(Rectangle())
            .overlay {
                AudioLaneDragCaptureView(
                    onEntered: { info, location in
                        beginDropPreviewNative(info: info, at: location)
                        // Accept single-file audio drops (multi-file handled by parent)
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
                    if lane.clips.isEmpty {
                        emptyDropPrompt
                    }
                }
            )
    }

    private var emptyDropPrompt: some View {
        VStack(spacing: Spacing.xs) {
            Image(systemName: "music.note.list")
                .frame(width: 20, height: 20)
                .foregroundColor(.secondary.opacity(0.6))

            Text("Drop audio files here")
                .font(Typography.caption)
                .foregroundColor(.secondary.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func dropPreviewOverlay(frame: Int, height: CGFloat, width: CGFloat) -> some View {
        let durationFrames = dropPreviewDurationFrames ?? Int(frameRate.fps)
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

    /// Orange ghost preview for a clip being dragged to this lane from another lane
    private func laneChangePreviewGhost(preview: LaneChangePreview, height: CGFloat) -> some View {
        let clipWidth = CGFloat(preview.durationFrames) * pixelsPerFrame
        let xOffset = CGFloat(preview.timelineStartFrame) * pixelsPerFrame - scrollOffset
        let fillColor = preview.isValidDrop ? Color.orange : Color.red

        return RoundedRectangle(cornerRadius: 4)
            .stroke(fillColor, lineWidth: 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(fillColor.opacity(0.2))
            )
            .frame(width: max(12, clipWidth), height: max(6, height - 6))
            .offset(x: xOffset)
            .padding(.vertical, Spacing.xs)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var clipsContent: some View {
        ForEach(lane.clips) { clip in
            AudioClipView(
                clip: clip,
                lane: lane,
                laneIndex: laneIndex,
                isActive: activeClipIds.contains(clip.id),
                pixelsPerFrame: pixelsPerFrame,
                frameRate: frameRate,
                isSelected: selectedClipId == clip.id || selectedClipIds.contains(clip.id),
                waveformCache: waveformCache,
                showWaveform: showWaveforms,
                interactionsEnabled: clipInteractionsEnabled,
                isOptimized: isClipOptimized(clip),
                timelineStartTimecode: formatTimecode(forFrame: clip.timelineStartFrame),
                onSelect: { modifiers in
                    selectedClipId = clip.id
                    onClipSelected(clip.id, modifiers)
                },
                onDoubleClick: {
                    onClipDoubleClick(clip)
                },
                onSetTimelineStart: {
                    onClipSetTimelineStart(clip)
                }
            )
            .offset(x: clipOffset(for: clip))
            .simultaneousGesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        guard clipInteractionsEnabled else { return }
                        if draggingClipId != clip.id {
                            draggingClipId = clip.id
                            dragStartFrame = clip.timelineStartFrame
                            dragOffsetFrames = 0
                            dragVerticalOffset = 0
                            selectedClipId = clip.id
                            onClipSelected(clip.id, SelectionModifiers.current)
                        }

                        // Track vertical offset for lane changes
                        dragVerticalOffset = value.translation.height

                        // For video-linked clips, lock horizontal position but allow vertical lane changes
                        if clip.sourceType == .videoTrack {
                            // Don't allow horizontal movement - clip is locked to video
                            dragOffsetFrames = 0

                            // Show preview in target lane when crossing threshold
                            let laneChangeThreshold: CGFloat = TimelineLayout.audioLaneHeight / 2
                            if abs(dragVerticalOffset) > laneChangeThreshold {
                                let laneOffset = dragVerticalOffset > 0 ? 1 : -1
                                onClipLaneChangePreview?(clip, laneOffset)
                            } else {
                                onClipLaneChangePreview?(clip, nil)
                            }
                        } else {
                            // Regular clips can move horizontally
                            let deltaFrames = Int(round(value.translation.width / max(pixelsPerFrame, 0.001)))
                            dragOffsetFrames = deltaFrames
                        }

                        let desired = dragStartFrame + dragOffsetFrames
                        let allowedRange = allowedFrameRange(for: clip)
                        let previewFrame = min(max(desired, allowedRange.lowerBound), allowedRange.upperBound)
                        if clip.sourceType == .videoTrack {
                            onClipDragPreview(clip, previewFrame)
                        }
                    }
                    .onEnded { _ in
                        guard draggingClipId == clip.id else { return }

                        // Check for vertical lane change (threshold: half a lane height)
                        let laneChangeThreshold: CGFloat = TimelineLayout.audioLaneHeight / 2
                        let verticalOffset = dragVerticalOffset

                        if clip.sourceType == .videoTrack && abs(verticalOffset) > laneChangeThreshold {
                            // Video-linked clip dragged vertically - request lane change
                            let laneOffset = verticalOffset > 0 ? 1 : -1
                            onClipLaneChangeRequested?(clip.id, laneOffset)
                            onClipDragPreview(clip, nil)
                            onClipLaneChangePreview?(clip, nil)  // Clear lane change preview
                        } else if clip.sourceType != .videoTrack {
                            // Regular clip - move horizontally
                            let unclamped = dragStartFrame + dragOffsetFrames
                            let allowedRange = allowedFrameRange(for: clip)
                            let newFrame = min(max(unclamped, allowedRange.lowerBound), allowedRange.upperBound)
                            onClipMove(clip.id, newFrame)
                        } else {
                            // Video-linked clip not moved far enough - clear preview
                            onClipLaneChangePreview?(clip, nil)
                        }

                        draggingClipId = nil
                        dragOffsetFrames = 0
                        dragVerticalOffset = 0

                        if clip.sourceType == .videoTrack {
                            onClipDragPreview(clip, nil)
                        }
                    }
            )
        }
    }

    private func clipOffset(for clip: AudioClip) -> CGFloat {
        let base = CGFloat(clip.timelineStartFrame) * pixelsPerFrame - scrollOffset

        // Video-linked clips don't move horizontally when dragged
        if draggingClipId == clip.id && clip.sourceType != .videoTrack {
            let desired = dragStartFrame + dragOffsetFrames
            let allowedRange = allowedFrameRange(for: clip)
            let clamped = min(max(desired, allowedRange.lowerBound), allowedRange.upperBound)
            return base + (CGFloat(clamped - clip.timelineStartFrame) * pixelsPerFrame)
        }

        if let preview = linkedDragPreview,
           isLinkedPreview(clip, preview: preview) {
            let delta = preview.toFrame - preview.fromFrame
            return base + (CGFloat(delta) * pixelsPerFrame)
        }

        return base
    }

    private func isLinkedPreview(_ clip: AudioClip, preview: LinkedDragPreview) -> Bool {
        clip.sourceType == .videoTrack &&
        clip.sourceURL == preview.sourceURL &&
        clip.sourceStartFrame == preview.sourceStartFrame &&
        clip.durationFrames == preview.durationFrames &&
        clip.timelineStartFrame == preview.fromFrame
    }

    private func allowedFrameRange(for clip: AudioClip) -> ClosedRange<Int> {
        let sortedClips = lane.clips.sorted { $0.timelineStartFrame < $1.timelineStartFrame }
        guard let index = sortedClips.firstIndex(where: { $0.id == clip.id }) else {
            let maxStart = max(0, timelineDurationFrames - clip.durationFrames)
            return 0...maxStart
        }

        let previous = index > 0 ? sortedClips[index - 1] : nil
        let next = index + 1 < sortedClips.count ? sortedClips[index + 1] : nil

        var minStart = 0
        var maxStart = max(0, timelineDurationFrames - clip.durationFrames)

        if let previous {
            minStart = max(minStart, previous.timelineEndFrame)
        }
        if let next {
            maxStart = min(maxStart, next.timelineStartFrame - clip.durationFrames)
        }

        if maxStart < minStart {
            maxStart = minStart
        }

        return minStart...maxStart
    }

    private var channelCount: Int {
        // Assume stereo for now; could be derived from clips
        2
    }

    /// Check if an audio clip is optimized based on its mediaItemId or sourceURL
    private func isClipOptimized(_ clip: AudioClip) -> Bool {
        // First try to look up by mediaItemId (most reliable)
        if let mediaItemId = clip.mediaItemId,
           let item = mediaLibrary.items.first(where: { $0.id == mediaItemId }) {
            return item.isOptimized
        }
        // Fallback to URL lookup
        let item = mediaLibrary.items.first { $0.url == clip.sourceURL }
        return item?.isOptimized ?? false
    }

    private var laneColor: Color {
        let colors: [Color] = [
            .blue, .green, .orange, .purple, .pink, .cyan, .mint, .indigo
        ]
        return colors[laneIndex % colors.count]
    }

    // MARK: - Timecode Formatting

    /// Format a frame number as timecode string
    private func formatTimecode(forFrame frame: Int) -> String {
        let absoluteFrame = timelineStartFrames + frame
        let fps = Int(frameRate.fps.rounded())
        guard fps > 0 else { return "00:00:00:00" }

        let totalSeconds = absoluteFrame / fps
        let frames = absoluteFrame % fps
        let seconds = totalSeconds % 60
        let totalMinutes = totalSeconds / 60
        let minutes = totalMinutes % 60
        let hours = totalMinutes / 60

        let separator = frameRate.isDrop ? ";" : ":"
        return String(format: "%02d:%02d:%02d%@%02d", hours, minutes, seconds, separator, frames)
    }

    // MARK: - Drop Handling

    private func handleDrop(providers: [NSItemProvider], at location: CGPoint) -> Bool {
        let targetFrame = dropFrame(for: location)
        let isInternalDrag = isInternalMediaDrag(providers)

        // For internal drags with multiple selected items, use DragContext
        if isInternalDrag && dragContext.isDragging && !dragContext.mediaItems.isEmpty {
            let audioURLs = dragContext.mediaItems
                .filter { $0.type == .audio }
                .map { $0.url }
            if !audioURLs.isEmpty {
                onDropMedia(audioURLs, targetFrame, isInternalDrag)
            }
            dragContext.end()
            clearDropPreview()
            return true
        }

        // Fall back to extracting URLs from providers (external drops).
        // Each provider writes to its own reserved slot so the results stay in
        // drag order; appending would order them by completion time instead.
        var slots = [URL?](repeating: nil, count: providers.count)
        let lock = NSLock()
        let group = DispatchGroup()

        for (index, provider) in providers.enumerated() {
            group.enter()
            loadURL(from: provider) { url in
                defer { group.leave() }
                if let url = url {
                    lock.lock()
                    slots[index] = url
                    lock.unlock()
                }
            }
        }

        group.notify(queue: .main) {
            let audioURLs = slots
                .compactMap { $0 }
                .filter { self.isAudioFile($0) }
                .orderedDeduplicated()
            if !audioURLs.isEmpty {
                self.onDropMedia(audioURLs, targetFrame, isInternalDrag)
            }
            if isInternalDrag {
                self.dragContext.end()
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
        return max(0, rawFrame)  // Only clamp lower bound, let business logic auto-extend
    }

    private func updateDropPreview(location: CGPoint) {
        latestDropLocation = location
        let frame = dropFrame(for: location)
        dropPreviewFrame = frame

        // Disallow drop if cursor is over an existing clip
        if dropPreviewDurationFrames != nil {
            let isOverExisting = isFrameInsideExistingClip(frame)
            isDropAllowed = !isOverExisting
        }
    }

    /// Check if a frame position is within any existing audio clip in this lane
    private func isFrameInsideExistingClip(_ frame: Int, excluding clipId: UUID? = nil) -> Bool {
        for clip in lane.clips {
            if clip.id == clipId { continue }

            if frame >= clip.timelineStartFrame && frame < clip.timelineEndFrame {
                return true
            }
        }
        return false
    }

    private func beginDropPreview(with providers: [NSItemProvider], at location: CGPoint) {
        updateDropPreview(location: location)
        if dropPreviewDurationFrames != nil || isLoadingDropPreview {
            return
        }
        isLoadingDropPreview = true
        isDropAllowed = false

        // Check dragContext first for internal Media panel drags (supports multi-select)
        if dragContext.isDragging {
            let audioItems = dragContext.mediaItems.filter { $0.type == .audio }
            if let firstItem = audioItems.first {
                isDropAllowed = true
                dropPreviewDurationFrames = max(1, Int(firstItem.duration * frameRate.fps))
                isLoadingDropPreview = false
                return
            }
        }

        if let quickType = quickMediaType(from: providers) {
            guard quickType == .audio else {
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
            guard isAudioFile(url) else {
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
                    let frames = max(1, Int(duration.seconds * frameRate.fps))
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

    // MARK: - Native Drop Handling (AppKit)

    /// Get all media candidates from NSDraggingInfo, checking dragContext first for internal drags
    private func allMediaCandidates(from info: NSDraggingInfo) -> (videoURLs: [URL], audioURLs: [URL], audioDuration: Double?, isInternal: Bool) {
        // Check dragContext first for internal Media panel drags (supports multi-select)
        if dragContext.isDragging && !dragContext.mediaItems.isEmpty {
            let videoURLs = dragContext.mediaItems.filter { $0.type == .video }.map { $0.url }
            let audioItems = dragContext.mediaItems.filter { $0.type == .audio }
            let audioURLs = audioItems.map { $0.url }
            // Use first audio item's duration for preview (multi-file will place sequentially)
            let audioDuration = audioItems.first?.duration
            return (videoURLs, audioURLs, audioDuration, true)
        }

        // Fall back to pasteboard for Finder drags
        let pasteboard = info.draggingPasteboard
        let allURLs = (pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL]) ?? []

        let videoURLs = allURLs.filter { ProjectMediaLibrary.mediaType(for: $0) == .video }
        let audioURLs = allURLs.filter { ProjectMediaLibrary.mediaType(for: $0) == .audio }

        return (videoURLs, audioURLs, nil, false)
    }

    /// Get audio candidate from NSDraggingInfo, checking dragContext first for internal drags
    private func audioCandidate(from info: NSDraggingInfo) -> (urls: [URL], duration: Double?, isInternal: Bool) {
        let candidates = allMediaCandidates(from: info)
        return (candidates.audioURLs, candidates.audioDuration, candidates.isInternal)
    }

    private func beginDropPreviewNative(info: NSDraggingInfo, at location: CGPoint) {
        // Handle both single and multi-file drops in this lane

        updateDropPreview(location: location)

        if dropPreviewDurationFrames != nil || isLoadingDropPreview {
            return
        }

        isLoadingDropPreview = true
        isDropAllowed = false

        let candidate = audioCandidate(from: info)
        guard !candidate.urls.isEmpty else {
            isLoadingDropPreview = false
            clearDropPreview()
            return
        }

        // Check if cursor is over an existing clip
        let targetFrame = dropFrame(for: location)
        let isOverExisting = isFrameInsideExistingClip(targetFrame)
        isDropAllowed = !isOverExisting

        // Use duration from dragContext if available (internal drag)
        if let duration = candidate.duration {
            dropPreviewDurationFrames = max(1, Int(duration * frameRate.fps))
            isLoadingDropPreview = false
            return
        }

        // Load duration async for Finder drags
        if let url = candidate.urls.first {
            Task {
                let asset = AVAsset(url: url)
                do {
                    let duration = try await asset.load(.duration)
                    let frames = max(1, Int(duration.seconds * frameRate.fps))
                    await MainActor.run {
                        dropPreviewDurationFrames = frames
                        isLoadingDropPreview = false
                    }
                } catch {
                    await MainActor.run {
                        dropPreviewDurationFrames = nil
                        isLoadingDropPreview = false
                    }
                }
            }
        } else {
            isLoadingDropPreview = false
        }
    }

    /// Routes video/audio URLs to the appropriate handler.
    ///
    /// - Mixed drops (video + audio): routes to onDropMixedMedia
    /// - Audio-only drops: routes to onDropMedia
    /// - Video-only drops: ignored (video track handles these)
    ///
    /// - Parameters:
    ///   - videoURLs: Array of video file URLs
    ///   - audioURLs: Array of audio file URLs
    ///   - targetFrame: Timeline frame position for placement
    ///   - isInternalDrag: Whether this originated from the media panel
    /// - Returns: true if drop was handled, false if no valid content
    private func routeDroppedMedia(videoURLs: [URL], audioURLs: [URL], targetFrame: Int, isInternalDrag: Bool) -> Bool {
        if !videoURLs.isEmpty && !audioURLs.isEmpty, let onMixed = onDropMixedMedia {
            onMixed(videoURLs, audioURLs, targetFrame)
            return true
        } else if !audioURLs.isEmpty {
            onDropMedia(audioURLs, targetFrame, isInternalDrag)
            return true
        }
        // Video-only drops on audio lane: ignored (video track handles these)
        return false
    }

    private func handleDropNative(info: NSDraggingInfo, at location: CGPoint) -> Bool {
        let candidates = allMediaCandidates(from: info)
        let targetFrame = dropFrame(for: location)

        let handled = routeDroppedMedia(
            videoURLs: candidates.videoURLs,
            audioURLs: candidates.audioURLs,
            targetFrame: targetFrame,
            isInternalDrag: candidates.isInternal
        )

        if candidates.isInternal {
            dragContext.end()
        }
        clearDropPreview()
        return handled
    }

    private func loadFirstURL(from providers: [NSItemProvider], completion: @escaping (URL?) -> Void) {
        guard let provider = providers.first else {
            completion(nil)
            return
        }

        loadURL(from: provider, completion: completion)
    }

    private func isAudioFile(_ url: URL) -> Bool {
        ProjectMediaLibrary.mediaType(for: url) == .audio
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

// MARK: - Native Drag Capture View (AppKit)

/// SwiftUI wrapper for native AppKit drag handling, enabling synchronous access to dragContext
private struct AudioLaneDragCaptureView: NSViewRepresentable {
    var onEntered: (NSDraggingInfo, CGPoint) -> NSDragOperation
    var onUpdated: (NSDraggingInfo, CGPoint) -> NSDragOperation
    var onExited: () -> Void
    var onPerform: (NSDraggingInfo, CGPoint) -> Bool

    func makeNSView(context: Context) -> AudioLaneDragCaptureNSView {
        let view = AudioLaneDragCaptureNSView()
        view.onEntered = onEntered
        view.onUpdated = onUpdated
        view.onExited = onExited
        view.onPerform = onPerform
        return view
    }

    func updateNSView(_ nsView: AudioLaneDragCaptureNSView, context: Context) {
        nsView.onEntered = onEntered
        nsView.onUpdated = onUpdated
        nsView.onExited = onExited
        nsView.onPerform = onPerform
    }
}

private final class AudioLaneDragCaptureNSView: NSView {
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
        // Return nil so clicks/drags pass through to SwiftUI clips underneath
        // Drag-and-drop events still work because they use registerForDraggedTypes
        nil
    }

    // Ensure mouse events pass through to SwiftUI views underneath
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        false
    }

    override func mouseDown(with event: NSEvent) {
        // Pass through to next responder (SwiftUI views underneath)
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
        @StateObject var waveformCache = WaveformCache()
        @StateObject var mediaLibrary = ProjectMediaLibrary()

        var lane: AudioLane {
            var l = AudioLane(name: "Audio 1")
            l.clips = [
                AudioClip(
                    sourceURL: URL(fileURLWithPath: "/audio1.wav"),
                    timelineStartFrame: 0,
                    durationFrames: 2400,
                    sourceStartFrame: 0,
                    sourceType: .audioFile
                ),
                AudioClip(
                    sourceURL: URL(fileURLWithPath: "/audio2.wav"),
                    timelineStartFrame: 3000,
                    durationFrames: 1800,
                    sourceStartFrame: 0,
                    sourceType: .audioFile
                )
            ]
            return l
        }

        var body: some View {
            AudioLaneView(
                lane: lane,
                laneIndex: 0,
                activeClipIds: Set([lane.clips.first!.id]),
                waveformCache: waveformCache,
                pixelsPerFrame: 0.5,
                frameRate: .fps24,
                scrollOffset: 0,
                timelineDurationFrames: 10000,
                showWaveforms: true,
                clipInteractionsEnabled: true,
                availableAudioOutputs: [],
                linkedDragPreview: nil,
                timelineStartFrames: 86400,  // 01:00:00:00 at 24fps
                mediaLibrary: mediaLibrary,
                onMuteToggle: {},
                onSoloToggle: {},
                onVolumeChange: { _ in },
                onOutputMappingChange: { _ in },
                onOutputNone: {},
                onDropMedia: { _, _, _ in },
                onClipSelected: { _, _ in },
                onClipDoubleClick: { _ in },
                onClipSetTimelineStart: { _ in },
                onClipMove: { _, _ in },
                onClipDragPreview: { _, _ in },
                onLaneRename: { _ in },
                onDeleteLane: {},
                onClipLaneChangeRequested: nil,
                onClipLaneChangePreview: nil,
                laneChangePreview: nil
            )
            .frame(width: 800)
            .background(Color(white: 0.15))
        }
    }

    return PreviewWrapper()
}

// MARK: - Shared Lane Controls

/// Mute/solo, sample rate, and output routing for one audio lane.
///
/// Shared so the combined Video File track can present the same controls for
/// its baked-in audio as an ordinary lane does for its own. Extracted rather
/// than duplicated: two copies of a routing menu would drift, and routing is
/// the part that has to behave identically wherever it appears.
struct AudioLaneControls: View {
    let lane: AudioLane
    let availableAudioOutputs: [MappedAudioOutput]
    let onMuteToggle: () -> Void
    let onSoloToggle: () -> Void
    let onOutputMappingChange: (MappedAudioOutput?) -> Void

    /// Route the lane to nothing, silencing it.
    let onOutputNone: () -> Void

    var body: some View {
        VStack(spacing: Spacing.xs) {
            HStack(spacing: Spacing.sm) {
                sampleRate
                muteSolo
            }
            outputPicker
        }
    }

    @ViewBuilder
    private var sampleRate: some View {
        if let firstClip = lane.clips.first {
            Text(String(format: "%.0fkHz", firstClip.sampleRate / 1000))
                .font(.system(size: 8, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }

    private var muteSolo: some View {
        HStack(spacing: Spacing.xs) {
            toggleButton(
                "M",
                isOn: lane.isMuted,
                tint: .red,
                help: lane.isMuted ? "Unmute" : "Mute",
                action: onMuteToggle
            )
            toggleButton(
                "S",
                isOn: lane.isSolo,
                tint: .yellow,
                help: lane.isSolo ? "Unsolo" : "Solo - silences all other lanes",
                action: onSoloToggle
            )
        }
    }

    /// Mute and solo read as controls rather than stray letters: a bordered
    /// well that fills with the state colour when engaged.
    private func toggleButton(
        _ label: String,
        isOn: Bool,
        tint: Color,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(isOn ? .black : .secondary)
                .frame(width: 16, height: 14)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(isOn ? tint : AppColors.surfaceLight)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(isOn ? tint : AppColors.borderMedium, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private var outputPicker: some View {
        Menu {
            // Silences the lane without touching its clips, volume or M state.
            Button {
                onOutputNone()
            } label: {
                HStack {
                    Text("None")
                    if lane.isOutputDisabled {
                        Spacer()
                        Image(systemName: "checkmark")
                    }
                }
            }

            Divider()

            ForEach(availableAudioOutputs) { output in
                Button {
                    onOutputMappingChange(output)
                } label: {
                    HStack {
                        Text(output.name)
                        if !lane.isOutputDisabled && lane.outputMappingId == output.id {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: Spacing.xs) {
                Text(outputPickerLabel)
                    .font(Typography.captionSmall)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7))
            }
            .foregroundColor(.white)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    // Unfilled when routed nowhere, so a silent lane reads as
                    // silent across the stack rather than looking like the rest.
                    .fill(lane.isOutputDisabled ? AppColors.surfaceMedium : Color.accentColor.opacity(0.8))
            )
        }
        .buttonStyle(.plain)
        .help(lane.isOutputDisabled ? "Routed to no output - this lane is silent" : "Audio output routing")
    }

    /// What the button reads: the chosen output, "None", or the unassigned state.
    private var outputPickerLabel: String {
        if lane.isOutputDisabled { return "None" }
        return availableAudioOutputs.first { $0.id == lane.outputMappingId }?.name ?? "Output"
    }
}
