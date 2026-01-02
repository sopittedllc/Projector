import SwiftUI
import SwiftTimecodeCore
import Iconoir

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
    let thumbnails: [UUID: ThumbnailStrip]
    let onDropVideoMedia: ([URL]) -> Void
    let onDropAudioMedia: (Int, [URL]) -> Void
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

    // Selection state
    @State private var selectedVideoReelId: UUID?
    @State private var selectedAudioClipId: UUID?
    @State private var selectedAudioLaneId: UUID?

    // Timecode entry dialog state
    @State private var showTimecodeEntryDialog = false
    @State private var timecodeEntryText = ""
    @State private var timecodeEntryError: String?
    @State private var editingReelId: UUID?
    @State private var editingClipId: UUID?
    @State private var editingLaneId: UUID?

    // MARK: - Constants

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

    /// Calculate pixels per frame based on available width so 100% fits the entire timeline
    private func pixelsPerFrame(for availableWidth: CGFloat) -> CGFloat {
        let contentWidth = availableWidth - headerWidth // Space for timeline content
        guard timeline.config.durationFrames > 0 else { return 1.0 }

        // At 100% zoom (zoomLevel = 1.0), entire timeline fits in view
        let basePixelsPerFrame = contentWidth / CGFloat(timeline.config.durationFrames)

        // Apply zoom - higher zoom = more pixels per frame = more detail
        return basePixelsPerFrame * zoomLevel
    }

    /// Calculate content width based on zoom level
    private func timelineContentWidth(for availableWidth: CGFloat) -> CGFloat {
        let ppf = pixelsPerFrame(for: availableWidth)
        return CGFloat(timeline.config.durationFrames) * ppf + headerWidth
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

    private var activeAudioClipIds: Set<UUID> {
        Set(timeline.activeAudioClips(at: playbackEngine.currentFrame).map { $0.clip.id })
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
        .gesture(magnificationGesture)
        .onDeleteCommand {
            deleteSelectedItem()
        }
        .sheet(isPresented: $showTimecodeEntryDialog) {
            timecodeEntryDialogContent
        }
    }

    // MARK: - Delete Selected Item

    private func deleteSelectedItem() {
        if let reelId = selectedVideoReelId {
            timelineManager.removeVideoReel(id: reelId)
            selectedVideoReelId = nil
        } else if let clipId = selectedAudioClipId, let laneId = selectedAudioLaneId {
            timelineManager.removeAudioClip(clipId: clipId, fromLane: laneId)
            selectedAudioClipId = nil
            selectedAudioLaneId = nil
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
            timelineManager.moveVideoReel(id: reelId, to: newFrame)
        } else if let clipId = editingClipId, let laneId = editingLaneId {
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
                .onTapGesture(count: 2) { resetZoom() }

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
                    Button(frameRateDisplayName(rate)) {
                        changeFrameRate(to: rate)
                    }
                }
            } label: {
                Text(frameRateDisplayName(timeline.config.frameRate))
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

    private func frameRateDisplayName(_ rate: TimecodeFrameRate) -> String {
        switch rate {
        case .fps23_976: return "23.976"
        case .fps24: return "24"
        case .fps25: return "25"
        case .fps29_97: return "29.97"
        case .fps29_97d: return "29.97 DF"
        case .fps30: return "30"
        default: return "\(rate.fps)"
        }
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
            let contentAreaWidth = geometry.size.width - headerWidth
            let totalTrackHeight = rulerHeight + rulerSpacing + tracksHeight

            ScrollView(.horizontal, showsIndicators: true) {
                ZStack(alignment: .topLeading) {
                    // Timeline content
                    VStack(spacing: 0) {
                        // Ruler - slightly lighter background spanning full width
                        HStack(spacing: 0) {
                            Color.clear.frame(width: headerWidth)
                            TimelineRulerView(
                                duration: playbackEngine.duration,
                                frameRate: timeline.config.frameRate,
                                currentTime: playbackEngine.currentTime
                            )
                        }
                        .frame(height: rulerHeight)
                        .background(Color(white: 0.18))

                        Rectangle()
                            .fill(Color(nsColor: .separatorColor).opacity(0.5))
                            .frame(height: 1)

                        Spacer().frame(height: 4)

                        // Video track
                        VideoTrackView(
                            timelineManager: timelineManager,
                            playbackEngine: playbackEngine,
                            thumbnails: thumbnails,
                            pixelsPerFrame: pixelsPerFrame(for: geometry.size.width),
                            scrollOffset: 0,
                            onDropMedia: onDropVideoMedia,
                            onReelSelected: { reelId in
                                selectedVideoReelId = reelId
                                selectedAudioClipId = nil
                                selectedAudioLaneId = nil
                            },
                            onReelDoubleClick: { reel in
                                editingReelId = reel.id
                                let tc = Timecode(.frames(reel.timelineStartFrame + timeline.config.startTimecode.frameCount.wholeFrames), at: timeline.config.frameRate, by: .clamping)
                                timecodeEntryText = tc.stringValue()
                                showTimecodeEntryDialog = true
                            }
                        )
                        .frame(height: videoTrackHeight)

                        Divider()

                        // Audio lanes
                        ForEach(Array(timeline.audioLanes.enumerated()), id: \.element.id) { index, lane in
                            AudioLaneView(
                                lane: lane,
                                laneIndex: index,
                                activeClipIds: activeAudioClipIds,
                                waveformCache: waveformCache,
                                pixelsPerFrame: pixelsPerFrame(for: geometry.size.width),
                                scrollOffset: 0,
                                availableAudioDevices: audioOutputManager.availableDevices,
                                onMuteToggle: { timelineManager.toggleLaneMute(at: index) },
                                onSoloToggle: { timelineManager.toggleLaneSolo(at: index) },
                                onVolumeChange: { volume in timelineManager.setLaneVolume(at: index, volume: volume) },
                                onOutputDeviceChange: { deviceUID in timelineManager.setLaneOutputDevice(id: lane.id, deviceUID: deviceUID) },
                                onDropMedia: { urls in onDropAudioMedia(index, urls) },
                                onClipSelected: { clipId in
                                    selectedAudioClipId = clipId
                                    selectedAudioLaneId = lane.id
                                    selectedVideoReelId = nil
                                },
                                onClipDoubleClick: { clip in
                                    editingClipId = clip.id
                                    editingLaneId = lane.id
                                    let tc = Timecode(.frames(clip.timelineStartFrame + timeline.config.startTimecode.frameCount.wholeFrames), at: timeline.config.frameRate, by: .clamping)
                                    timecodeEntryText = tc.stringValue()
                                    showTimecodeEntryDialog = true
                                }
                            )
                            .frame(height: audioLaneHeight)

                            if index < timeline.audioLanes.count - 1 {
                                Divider()
                            }
                        }

                        if timeline.audioLanes.isEmpty {
                            emptyAudioLanesPlaceholder
                        }

                        // Bottom padding
                        Spacer().frame(height: 8)
                    }

                    // Playhead - positioned inside scroll content
                    playhead(contentAreaWidth: contentAreaWidth, totalHeight: totalTrackHeight)
                }
                .frame(width: headerWidth + contentAreaWidth * zoomLevel, height: totalTrackHeight)
                .contentShape(Rectangle())
                .gesture(seekGesture(contentAreaWidth: contentAreaWidth))
            }
        }
        .frame(height: rulerHeight + rulerSpacing + tracksHeight)
    }

    // Simple playhead using percentage positioning
    private func playhead(contentAreaWidth: CGFloat, totalHeight: CGFloat) -> some View {
        let progress = timeline.config.durationFrames > 0
            ? CGFloat(playbackEngine.currentFrame) / CGFloat(timeline.config.durationFrames)
            : 0
        let xPos = headerWidth + (contentAreaWidth * zoomLevel * progress)

        return Rectangle()
            .fill(Color.accentColor)
            .frame(width: 2, height: totalHeight)
            .overlay(alignment: .top) {
                // Triangle at top
                Triangle()
                    .fill(Color.accentColor)
                    .frame(width: 10, height: 8)
                    .offset(y: -4)
            }
            .position(x: xPos, y: totalHeight / 2)
            .allowsHitTesting(false)
    }

    // Simple seek gesture using percentage
    private func seekGesture(contentAreaWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let x = value.location.x - headerWidth
                let totalWidth = contentAreaWidth * zoomLevel
                guard totalWidth > 0 else { return }
                let ratio = max(0, min(1, x / totalWidth))
                let frame = Int(ratio * CGFloat(timeline.config.durationFrames))
                onSeek(max(0, min(frame, timeline.config.durationFrames - 1)))
            }
    }

    /// Spacing between ruler and tracks (separator + spacer)
    private let rulerSpacing: CGFloat = 5

    private var tracksHeight: CGFloat {
        let audioHeight = max(50, CGFloat(timeline.audioLanes.count) * (audioLaneHeight + 1))
        return videoTrackHeight + 1 + audioHeight + 8 // +8 for bottom padding
    }

    private var emptyAudioLanesPlaceholder: some View {
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
            DustyBackground()
                .overlay(
                    VStack(spacing: 4) {
                        Image(systemName: "waveform.badge.plus")
                            .font(.system(size: 20))
                            .foregroundColor(.secondary.opacity(0.6))

                        Text("Drop audio files here")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                )
        }
        .frame(height: audioLaneHeight)
    }

    // MARK: - Zoom

    /// Minimum zoom: 100% = fit entire timeline
    private let minZoom: CGFloat = 1.0
    /// Maximum zoom: 10x for detail work
    private let maxZoom: CGFloat = 10.0

    @State private var lastMagnification: CGFloat = 1.0

    private var magnificationGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                // Calculate delta from last magnification to avoid runaway zoom
                let delta = value.magnification / lastMagnification
                lastMagnification = value.magnification
                let newZoom = zoomLevel * delta
                zoomLevel = max(minZoom, min(maxZoom, newZoom))
            }
            .onEnded { _ in
                lastMagnification = 1.0
            }
    }

    private func zoomIn() {
        withAnimation(.easeInOut(duration: 0.2)) {
            zoomLevel = min(maxZoom, zoomLevel * 1.5)
        }
    }

    private func zoomOut() {
        withAnimation(.easeInOut(duration: 0.2)) {
            zoomLevel = max(minZoom, zoomLevel / 1.5)
        }
    }

    private func resetZoom() {
        withAnimation(.easeInOut(duration: 0.2)) {
            zoomLevel = 1.0
        }
    }
}


#Preview {
    struct PreviewWrapper: View {
        @StateObject var timelineManager = TimelineManager()
        @StateObject var playbackEngine = PlaybackEngine()
        @StateObject var waveformCache = WaveformCache()
        @StateObject var audioOutputManager = AudioOutputManager()
        @State var zoomLevel: CGFloat = 1.0

        var body: some View {
            MultiTrackTimelineView(
                timelineManager: timelineManager,
                playbackEngine: playbackEngine,
                waveformCache: waveformCache,
                audioOutputManager: audioOutputManager,
                thumbnails: [:],
                onDropVideoMedia: { _ in },
                onDropAudioMedia: { _, _ in },
                onSeek: { _ in },
                onSettingsPressed: { },
                zoomLevel: $zoomLevel
            )
            .frame(width: 800, height: 300)
        }
    }

    return PreviewWrapper()
}
