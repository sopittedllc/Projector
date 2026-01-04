import SwiftUI
import SwiftTimecodeCore
import Iconoir
import UniformTypeIdentifiers
import AVFoundation

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
    @Environment(\.undoManager) private var undoManager
    let onDropVideoMedia: ([URL], Int, Bool) -> Void
    let onDropAudioMedia: (Int, [URL], Int, Bool) -> Void
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

    // Selection state
    @State private var selectedVideoReelId: UUID?
    @State private var selectedAudioClipId: UUID?
    @State private var selectedAudioLaneId: UUID?

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

    // MARK: - Constants
    // TODO: Use LayoutConstants after adding to Xcode project

    /// Track header width (for lane labels/controls)
    private let headerWidth: CGFloat = 120

    /// Video track height
    private let videoTrackHeight: CGFloat = 60

    /// Audio lane height
    private let audioLaneHeight: CGFloat = 60

    /// Ruler height
    private let rulerHeight: CGFloat = 24

    /// Toolbar height (TC display + zoom controls)
    private let toolbarHeight: CGFloat = 40

    // MARK: - Computed Properties

    /// Maximum zoom multiplier relative to fit-to-view.
    private let maxZoomMultiplier: CGFloat = 10.0

    private func pixelsPerFrame(for availableWidth: CGFloat) -> CGFloat {
        let contentWidth = max(1, availableWidth - headerWidth)
        let durationFrames = max(1, timeline.config.durationFrames)
        let fitPixelsPerFrame = contentWidth / CGFloat(durationFrames)
        let clampedZoom = min(max(zoomLevel, minZoom), maxZoom)
        let zoomMultiplier = 1 + (clampedZoom * (maxZoomMultiplier - 1))
        return fitPixelsPerFrame * zoomMultiplier
    }

    private func timelineContentWidth(for availableWidth: CGFloat) -> CGFloat {
        CGFloat(timeline.config.durationFrames) * pixelsPerFrame(for: availableWidth) + headerWidth
    }

    private var timeline: Timeline {
        timelineManager.timeline
    }

    private var totalHeight: CGFloat {
        var height = toolbarHeight + rulerHeight + 1 // Toolbar + ruler + divider
        height += videoTrackHeight + 1 // Video track + divider
        height += max(audioLaneHeight, CGFloat(timeline.audioLanes.count) * (audioLaneHeight + 1)) // Audio lanes
        return height
    }

    /// Active audio clip IDs - uses cached value to avoid recalculation on scroll
    private var activeAudioClipIds: Set<UUID> {
        cachedActiveAudioClipIds
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
            .frame(height: toolbarHeight)
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
            let contentAreaWidth = geometry.size.width - headerWidth
            let totalContentWidth = timelineContentWidth(for: geometry.size.width)
            let ppf = pixelsPerFrame(for: geometry.size.width)

            VStack(spacing: 0) {
                // Ruler row (with seek gesture - doesn't scroll)
                HStack(spacing: 0) {
                    Color.clear.frame(width: headerWidth)
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
                .frame(height: rulerHeight)
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
                        .frame(width: totalContentWidth, height: videoTrackHeight)
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
                                }
                            )
                            .frame(width: totalContentWidth, height: audioLaneHeight)
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
                            emptyAudioLanesPlaceholder(pixelsPerFrame: ppf)
                                .frame(width: totalContentWidth)
                                .overlay(alignment: .bottom) {
                                    laneBorder
                                }
                        }

                        // Bottom padding
                        Spacer().frame(height: 8)
                    }
                }
            }
            // Playhead overlay spanning full height
            .overlay(alignment: .topLeading) {
                playhead(pixelsPerFrame: ppf, totalHeight: geometry.size.height)
                    .allowsHitTesting(false)
            }
        }
    }

    // Simple playhead using offset positioning (more efficient than .position())
    private func playhead(pixelsPerFrame: CGFloat, totalHeight: CGFloat) -> some View {
        let xOffset = headerWidth + (CGFloat(playbackEngine.currentFrame) * pixelsPerFrame) - 1 // -1 for half width

        return VStack(spacing: 0) {
            // Triangle at top
            Triangle()
                .fill(Color.accentColor)
                .frame(width: 10, height: 8)
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

    /// Spacing between ruler and tracks (separator + spacer)
    private let rulerSpacing: CGFloat = 5

    private var laneBorder: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(0.5))
            .frame(height: 1)
    }

    private var tracksHeight: CGFloat {
        let audioHeight = max(50, CGFloat(timeline.audioLanes.count) * (audioLaneHeight + 1))
        return videoTrackHeight + 1 + audioHeight + 8 // +8 for bottom padding
    }

    private func emptyAudioLanesPlaceholder(pixelsPerFrame: CGFloat) -> some View {
        HStack(spacing: 0) {
            // Header area - overlay centers content
            Color.clear
                .frame(width: headerWidth, height: audioLaneHeight)
                .overlay(
                    VStack(spacing: 4) {
                        Text("Audio")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.primary)

                        Image(systemName: "waveform")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)

                        Text("No lanes")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary.opacity(0.5))
                    }
                    .padding(.bottom, 4)
                )

            // Empty content area with drop prompt
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    DustyBackground()

                    VStack(spacing: 4) {
                        Image(systemName: "waveform.badge.plus")
                            .font(.system(size: 20))
                            .foregroundColor(.secondary.opacity(0.6))

                        Text("Drop audio files here")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .offset(x: -headerWidth / 2)

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
                .onDrop(of: [UTType.fileURL, UTType.url, UTType.projectorMediaItem], delegate: EmptyAudioLaneDropDelegate(
                    isDropAllowed: $isEmptyAudioDropAllowed,
                    enterHandler: { providers, location in
                        beginEmptyAudioDrop(with: providers, at: location, pixelsPerFrame: pixelsPerFrame)
                    },
                    exitHandler: {
                        clearEmptyAudioDrop()
                    },
                    dropHandler: { providers, location in
                        handleEmptyAudioDrop(providers: providers, at: location, pixelsPerFrame: pixelsPerFrame)
                    },
                    updateHandler: { location in
                        updateEmptyAudioDropPreview(location: location, pixelsPerFrame: pixelsPerFrame)
                    },
                    isLoading: { isEmptyAudioDropLoading }
                ))
            }
        }
        .frame(height: audioLaneHeight)
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

        if let quickType = quickMediaType(from: providers) {
            guard quickType == .audio else {
                isEmptyAudioDropLoading = false
                clearEmptyAudioDrop()
                return
            }
            isEmptyAudioDropAllowed = true
        }

        loadFirstURL(from: providers) { url in
            guard let url, ProjectMediaLibrary.mediaType(for: url) == .audio else {
                isEmptyAudioDropLoading = false
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
    }

    private func handleEmptyAudioDrop(
        providers: [NSItemProvider],
        at location: CGPoint,
        pixelsPerFrame: CGFloat
    ) -> Bool {
        var urls: [URL] = []
        let group = DispatchGroup()
        let isInternalDrag = providers.contains { provider in
            provider.hasItemConformingToTypeIdentifier(UTType.projectorMediaItem.identifier)
        }

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
            let audioURLs = urls.filter { ProjectMediaLibrary.mediaType(for: $0) == .audio }
            guard !audioURLs.isEmpty else { return }
            let targetFrame = max(0, Int(location.x / max(pixelsPerFrame, 0.001)))
            onDropAudioMedia(0, audioURLs, targetFrame, isInternalDrag)
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
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            if let url = extractURL(from: item) {
                completion(url)
                return
            }
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                completion(extractURL(from: item))
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
}

private struct EmptyAudioLaneDropDelegate: DropDelegate {
    @Binding var isDropAllowed: Bool
    let enterHandler: ([NSItemProvider], CGPoint) -> Void
    let exitHandler: () -> Void
    let dropHandler: ([NSItemProvider], CGPoint) -> Bool
    let updateHandler: (CGPoint) -> Void
    private let supportedTypes: [UTType] = [.fileURL, .url, .projectorMediaItem]
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
        return DropProposal(operation: isLoading() || isDropAllowed ? .copy : .cancel)
    }

    func performDrop(info: DropInfo) -> Bool {
        exitHandler()
        let providers = info.itemProviders(for: supportedTypes)
        return dropHandler(providers, info.location)
    }
}

#Preview {
    struct PreviewWrapper: View {
        @StateObject var timelineManager = TimelineManager()
        @StateObject var playbackEngine = PlaybackEngine()
        @StateObject var waveformCache = WaveformCache()
        @StateObject var audioOutputManager = AudioOutputManager()
        @StateObject var thumbnailCache = ThumbnailCache()
        @State var zoomLevel: CGFloat = 0.0

        var body: some View {
            MultiTrackTimelineView(
                timelineManager: timelineManager,
                playbackEngine: playbackEngine,
                waveformCache: waveformCache,
                audioOutputManager: audioOutputManager,
                thumbnailCache: thumbnailCache,
                onDropVideoMedia: { _, _, _ in },
                onDropAudioMedia: { _, _, _, _ in },
                onSeek: { _ in },
                onSettingsPressed: { },
                zoomLevel: $zoomLevel
            )
            .frame(width: 800, height: 300)
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
