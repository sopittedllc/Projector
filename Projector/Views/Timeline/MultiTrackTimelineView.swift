import SwiftUI
import Foundation
import SwiftTimecodeCore
import Iconoir
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
    @FocusState private var isStartTCFocused: Bool
    @FocusState private var isDurationFocused: Bool
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

    // MARK: - Constants

    /// Height for the inactive "new lane" drop target
    private let newLaneDropInactiveHeight: CGFloat = 20

    // MARK: - Computed Properties

    /// Maximum zoom multiplier relative to fit-to-view.
    private let maxZoomMultiplier: CGFloat = 10.0

    private func pixelsPerFrame(for availableWidth: CGFloat) -> CGFloat {
        let contentWidth = max(1, availableWidth - TimelineLayout.headerWidth)
        let durationFrames = max(1, timeline.config.durationFrames)
        let fitPixelsPerFrame = contentWidth / CGFloat(durationFrames)
        let clampedZoom = min(max(zoomLevel, minZoom), maxZoom)
        let zoomMultiplier = 1 + (clampedZoom * (maxZoomMultiplier - 1))
        return fitPixelsPerFrame * zoomMultiplier
    }

    private func timelineContentWidth(for availableWidth: CGFloat) -> CGFloat {
        CGFloat(timeline.config.durationFrames) * pixelsPerFrame(for: availableWidth) + TimelineLayout.headerWidth
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
            playbackEngine.stop()
            return .handled
        }
        .sheet(isPresented: $showTimecodeEntryDialog) {
            timecodeEntryDialogContent
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
        }
        .onAppear {
            updateActiveAudioClipIds()
        }
    }

    // MARK: - Delete Selected Item

    private func deleteSelectedItem() {
        if let reelId = selectedVideoReelId,
           let reel = timelineManager.timeline.videoReels.first(where: { $0.id == reelId }) {
            registerTimelineUndo(actionName: "Delete Video Reel")
            removeLinkedAudio(for: reel)
            timelineManager.removeVideoReel(id: reelId)
            selectedVideoReelId = nil
            selectedAudioClipId = nil
            selectedAudioLaneId = nil
            return
        }

        if let clipId = selectedAudioClipId,
           let laneId = selectedAudioLaneId,
           let lane = timelineManager.timeline.audioLanes.first(where: { $0.id == laneId }),
           let clip = lane.clips.first(where: { $0.id == clipId }) {
            registerTimelineUndo(actionName: "Delete Audio Clip")
            if clip.sourceType == .videoTrack, let reel = linkedReel(for: clip) {
                removeLinkedAudio(for: reel)
                timelineManager.removeVideoReel(id: reel.id)
                selectedVideoReelId = nil
            } else {
                timelineManager.removeAudioClip(clipId: clipId, fromLane: laneId)
            }
            removeEmptyAudioLanes()
            selectedAudioClipId = nil
            selectedAudioLaneId = nil
        }
    }

    private func linkedReel(for clip: AudioClip) -> VideoReel? {
        timelineManager.timeline.videoReels.first { reel in
            reel.sourceURL == clip.sourceURL &&
            reel.sourceStartFrame == clip.sourceStartFrame &&
            reel.durationFrames == clip.durationFrames &&
            reel.timelineStartFrame == clip.timelineStartFrame
        }
    }

    private func removeLinkedAudio(for reel: VideoReel) {
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

        removeEmptyAudioLanes()
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
        VStack(spacing: 16) {
            Text("Enter New Position")
                .font(.headline)

            TextField("00:00:00:00", text: $timecodeEntryText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
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

            HStack(spacing: 12) {
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
        .padding(24)
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
            HStack(spacing: 12) {
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

                // Settings button
                Button(action: onSettingsPressed) {
                    Iconoir.settings.asImage
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .frame(height: TimelineLayout.toolbarHeight)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))

            Divider()
        }
    }

    private var transportControls: some View {
        HStack(spacing: 8) {
            Button(action: { playbackEngine.stepBackward() }) {
                Iconoir.skipPrev.asImage
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .disabled(!playbackEngine.hasContent)

            Button(action: { playbackEngine.togglePlayback() }) {
                (playbackEngine.isPlaying ? Iconoir.pauseSolid.asImage : Iconoir.playSolid.asImage)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .disabled(!playbackEngine.hasContent)
            .keyboardShortcut(.space, modifiers: [])

            Button(action: { playbackEngine.stepForward() }) {
                Iconoir.skipNext.asImage
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .disabled(!playbackEngine.hasContent)

            Button(action: { playbackEngine.stop() }) {
                Iconoir.square.asImage
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .disabled(!playbackEngine.hasContent)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        )
    }

    private var zoomControls: some View {
        HStack(spacing: 4) {
            Button(action: { zoomOut() }) {
                Image(systemName: "minus.magnifyingglass")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .disabled(zoomLevel <= minZoom)

            Slider(value: $zoomLevel, in: minZoom...maxZoom)
                .frame(width: 80)
                .controlSize(.mini)
                // Use simultaneousGesture instead of onTapGesture for consistency (GP-003)
                .simultaneousGesture(
                    TapGesture(count: 2)
                        .onEnded { _ in resetZoom() }
                )

            Button(action: { zoomIn() }) {
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .disabled(zoomLevel >= maxZoom)
        }
    }

    // MARK: - Editable Timecode Boxes

    private var startTCBox: some View {
        HStack(spacing: 4) {
            Text("Start TC:")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)

            TextField("00:00:00:00", text: $editingStartTCText)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .frame(width: 85)
                .focused($isStartTCFocused)
                .onChange(of: editingStartTCText) { _, newValue in
                    let formatted = formatTimecodeInput(newValue)
                    if formatted != newValue {
                        editingStartTCText = formatted
                    }
                }
                .onSubmit {
                    applyStartTimecode()
                }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(startTCBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isStartTCFocused ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 1)
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
            return Color.clear
        } else if isHoveringStartTC {
            return Color.white.opacity(0.1)
        } else {
            return Color(nsColor: .controlBackgroundColor)
        }
    }

    private var durationBox: some View {
        HStack(spacing: 4) {
            Text("Duration:")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)

            TextField("00:00:00:00", text: $editingDurationText)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .frame(width: 85)
                .focused($isDurationFocused)
                .onChange(of: editingDurationText) { _, newValue in
                    let formatted = formatTimecodeInput(newValue)
                    if formatted != newValue {
                        editingDurationText = formatted
                    }
                }
                .onSubmit {
                    applyDuration()
                }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(durationBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isDurationFocused ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 1)
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
            return Color.clear
        } else if isHoveringDuration {
            return Color.white.opacity(0.1)
        } else {
            return Color(nsColor: .controlBackgroundColor)
        }
    }

    private var fpsBox: some View {
        HStack(spacing: 4) {
            Text("FPS:")
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
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .frame(minWidth: 50)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
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
                // Ruler row (with seek gesture - doesn't scroll)
                HStack(spacing: 0) {
                    Color.clear.frame(width: TimelineLayout.headerWidth)
                    if debug.disableRulerGesture {
                        TimelineRulerView(
                            duration: playbackEngine.duration,
                            frameRate: timeline.config.frameRate,
                            currentTime: playbackEngine.currentTime
                        )
                        .contentShape(Rectangle())
                    } else {
                        TimelineRulerView(
                            duration: playbackEngine.duration,
                            frameRate: timeline.config.frameRate,
                            currentTime: playbackEngine.currentTime
                        )
                        .contentShape(Rectangle())
                        .gesture(seekGesture(contentAreaWidth: contentAreaWidth))
                    }
                }
                .frame(height: TimelineLayout.rulerHeight)
                .background(Color(white: 0.18))

                Rectangle()
                    .fill(Color(nsColor: .separatorColor).opacity(0.5))
                    .frame(height: 1)

                // Scrollable tracks area (horizontal + vertical)
                ScrollView([.horizontal, .vertical], showsIndicators: true) {
                    VStack(spacing: 0) {
                        Spacer().frame(height: 4)

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
                            onReelSelected: { reelId in
                                selectedVideoReelId = reelId
                                selectedAudioClipId = nil
                                selectedAudioLaneId = nil
                                isTimelineFocused = true
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
                            }
                        )
                        .frame(width: totalContentWidth, height: TimelineLayout.videoTrackHeight)
                        .overlay(alignment: .top) {
                            laneBorder
                        }

                        Divider()

                        // Audio lanes
                        ForEach(Array(timeline.audioLanes.enumerated()), id: \.element.id) { index, lane in
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
                                mediaLibrary: mediaLibrary,
                                onMuteToggle: { timelineManager.toggleLaneMute(at: index) },
                                onSoloToggle: { timelineManager.toggleLaneSolo(at: index) },
                                onVolumeChange: { volume in timelineManager.setLaneVolume(at: index, volume: volume) },
                                onOutputMappingChange: { output in timelineManager.setLaneOutputMapping(id: lane.id, mapping: output) },
                                onDropMedia: { urls, frame, isInternal in onDropAudioMedia(index, urls, frame, isInternal) },
                                onClipSelected: { clipId in
                                    selectedAudioClipId = clipId
                                    selectedAudioLaneId = lane.id
                                    selectedVideoReelId = nil
                                    isTimelineFocused = true
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
                                laneChangePreview: laneChangePreview
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
                        Spacer().frame(height: 8)
                    }
                    .frame(minHeight: scrollHeight)
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
            // Unified multi-file drop overlay (shown when dragging multiple files)
            .overlay {
                if isMultiFileDrag || externalDragItemCount > 1 {
                    multiFileDropOverlay
                }
            }
            // DragCaptureView to track external multi-file drags and handle drops
            .overlay {
                DragCaptureView(
                    onEntered: { info, _ in
                        // Track external drag item count
                        if dragContext.mediaItems.isEmpty {
                            let pasteboardItems = info.draggingPasteboard.pasteboardItems ?? []
                            externalDragItemCount = pasteboardItems.count
                        }
                    },
                    onUpdated: { info, _ in
                        // Keep tracking - cursor might move in/out of child views
                        if dragContext.mediaItems.isEmpty {
                            let pasteboardItems = info.draggingPasteboard.pasteboardItems ?? []
                            externalDragItemCount = pasteboardItems.count
                        }
                        // Only accept multi-file drops
                        return (isMultiFileDrag || externalDragItemCount > 1) ? .copy : []
                    },
                    onExited: {
                        externalDragItemCount = 0
                    },
                    onPerform: { info, _ in
                        handleMultiFileDropNative(info: info)
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
    private func marqueeSelectionGesture(pixelsPerFrame: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 5)
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
                }
                marqueeCurrentPoint = value.location
                updateMarqueeSelection(pixelsPerFrame: pixelsPerFrame)
            }
            .onEnded { _ in
                isMarqueeSelecting = false
            }
    }

    /// Handle multi-file drop from NSDraggingInfo
    private func handleMultiFileDropNative(info: NSDraggingInfo) -> Bool {
        // Only handle multi-file drops
        let isInternalMulti = dragContext.mediaItems.count > 1
        let pasteboardItems = info.draggingPasteboard.pasteboardItems ?? []
        let isExternalMulti = dragContext.mediaItems.isEmpty && pasteboardItems.count > 1

        guard isInternalMulti || isExternalMulti else { return false }

        if isInternalMulti {
            // Internal drag from media panel - use dragContext URLs
            let urls = dragContext.mediaItems.map { $0.url }
            var videoURLs: [URL] = []
            var audioURLs: [URL] = []

            for url in urls {
                guard let mediaType = ProjectMediaLibrary.mediaType(for: url) else { continue }
                switch mediaType {
                case .video:
                    videoURLs.append(url)
                case .audio:
                    audioURLs.append(url)
                }
            }

            if let onDropMixedMedia = onDropMixedMedia {
                onDropMixedMedia(videoURLs, audioURLs, 0)
            }
            dragContext.end()
        } else {
            // External drag from Finder - extract URLs from pasteboard
            var videoURLs: [URL] = []
            var audioURLs: [URL] = []

            debugPrint("handleMultiFileDropNative: Processing \(pasteboardItems.count) pasteboard items")
            for item in pasteboardItems {
                if let urlString = item.string(forType: .fileURL),
                   let url = URL(string: urlString) {
                    let mediaType = ProjectMediaLibrary.mediaType(for: url)
                    debugPrint("  URL: \(url.lastPathComponent), mediaType=\(mediaType?.rawValue ?? "nil")")
                    guard let mediaType = mediaType else { continue }
                    switch mediaType {
                    case .video:
                        videoURLs.append(url)
                    case .audio:
                        audioURLs.append(url)
                    }
                }
            }

            debugPrint("handleMultiFileDropNative: Found \(videoURLs.count) videos, \(audioURLs.count) audio")
            if let onDropMixedMedia = onDropMixedMedia, (!videoURLs.isEmpty || !audioURLs.isEmpty) {
                onDropMixedMedia(videoURLs, audioURLs, 0)
            }
        }

        externalDragItemCount = 0
        return true
    }

    /// Overlay shown when dragging multiple files to the timeline
    private var multiFileDropOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.15))

            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 4]))
        }
        .allowsHitTesting(false)
    }

    // Simple playhead using offset positioning (more efficient than .position())
    private func playhead(pixelsPerFrame: CGFloat, totalHeight: CGFloat) -> some View {
        let xOffset = TimelineLayout.headerWidth + (CGFloat(playbackEngine.currentFrame) * pixelsPerFrame) - 1 // -1 for half width

        return VStack(spacing: 0) {
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

    // Simple seek gesture using percentage
    private func seekGesture(contentAreaWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let x = value.location.x
                let totalWidth = max(1, contentAreaWidth * (1 + (zoomLevel * (maxZoomMultiplier - 1))))
                guard totalWidth > 0 else { return }
                let ratio = max(0, min(1, x / totalWidth))
                let frame = Int(ratio * CGFloat(timeline.config.durationFrames))
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
                    VStack(spacing: 2) {
                        Image(systemName: "speaker.slash")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary.opacity(0.4))

                        Text("No audio")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary.opacity(0.4))

                        Text("lanes")
                            .font(.system(size: 9))
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
                                .padding(4)
                        )

                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 16))
                            .foregroundColor(.secondary.opacity(0.4))

                        Text("Click \"+Audio Lane\" to add a lane, or drop audio files here")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.5))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .offset(x: -TimelineLayout.headerWidth / 2)

                    // Don't show preview for multi-file drops (parent handles those)
                    if !isMultiFileDrag, (isEmptyAudioDropAllowed || isEmptyAudioDropLoading),
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
                    VStack(spacing: 4) {
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
                        VStack(spacing: 4) {
                            Text("Drop to create new lane")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary.opacity(0.7))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .offset(x: -TimelineLayout.headerWidth / 2)
                    }

                    // Don't show preview for multi-file drops (parent handles those)
                    if !isMultiFileDrag, (isEmptyAudioDropAllowed || isEmptyAudioDropLoading),
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
        .animation(.easeInOut(duration: 0.12), value: isActive)
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
        let allowed = updateEmptyAudioDrop(from: info, location: location, pixelsPerFrame: pixelsPerFrame)
        return allowed ? .copy : []
    }

    private func handleNewLanePerformDrop(
        info: NSDraggingInfo,
        location: CGPoint,
        pixelsPerFrame: CGFloat,
        laneIndex: Int
    ) -> Bool {
        // For multi-file drags, let the parent timeline view handle it with unified overlay
        if isMultiFileDrag {
            clearEmptyAudioDrop()
            return false
        }

        let urls = audioURLs(from: info)
        guard !urls.isEmpty else {
            clearEmptyAudioDrop()
            return false
        }
        let targetFrame = max(0, Int(location.x / max(pixelsPerFrame, 0.001)))
        let isInternal = dragContext.mediaItem != nil
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
        if let item = dragContext.mediaItem, item.type == .audio {
            return ([item.url], item.duration, true)
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
        var urls: [URL] = []
        let group = DispatchGroup()
        let isInternalDrag = providers.contains { provider in
            provider.hasItemConformingToTypeIdentifier(UTType.projectorMediaItem.identifier)
        }
        let internalItem = dragContext.mediaItem ?? mediaItem(from: providers)

        for provider in providers {
            group.enter()
            if provider.hasItemConformingToTypeIdentifier(UTType.projectorMediaItem.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.projectorMediaItem.identifier) { data, _ in
                    defer { group.leave() }
                    let info = extractProjectorMediaInfo(from: data)
                    if info.type == .audio, let url = info.url {
                        urls.append(url)
                    }
                }
            } else {
                loadURL(from: provider) { url in
                    defer { group.leave() }
                    if let url = url {
                        urls.append(url)
                    }
                }
            }
        }

        group.notify(queue: .main) {
            if urls.isEmpty, let internalItem, internalItem.type == .audio {
                urls.append(internalItem.url)
            }
            let audioURLs = Array(Set(urls.filter { ProjectMediaLibrary.mediaType(for: $0) == .audio }))
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
            .padding(.vertical, 3)
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
        withAnimation(.easeInOut(duration: 0.2)) {
            zoomLevel = min(maxZoom, zoomLevel + zoomStep)
        }
    }

    private func zoomOut() {
        withAnimation(.easeInOut(duration: 0.2)) {
            zoomLevel = max(minZoom, zoomLevel - zoomStep)
        }
    }

    private func resetZoom() {
        withAnimation(.easeInOut(duration: 0.2)) {
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
                debugPrint("Marquee selected video reel: \(reel.displayName)")
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
                    debugPrint("Marquee selected audio clip: \(clip.displayName) in lane \(lane.name)")
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

        if !newVideoSelection.isEmpty || !newAudioSelection.isEmpty {
            debugPrint("Marquee selection: \(newVideoSelection.count) video, \(newAudioSelection.count) audio")
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
    var onEntered: (NSDraggingInfo, CGPoint) -> Void
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
    var onEntered: ((NSDraggingInfo, CGPoint) -> Void)?
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
        onEntered?(sender, localLocation(for: sender))
        return .copy
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
