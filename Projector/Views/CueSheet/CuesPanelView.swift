import SwiftUI
import SwiftTimecodeCore
import Iconoir

/// Accordion panel for viewing and editing cues.
///
/// Displays cues in a table format with editable fields for title and notes.
/// Supports single-click selection, double-click editing, and pop-out window.
struct CuesPanelView: View {
    @ObservedObject var timelineManager: TimelineManager
    let waveformCache: WaveformCache
    let onSeekToCue: (Int) -> Void
    let onPopOut: () -> Void

    @State private var isExpanded = true
    @State private var selectedCueId: UUID?
    @State private var editingCueId: UUID?
    @State private var editingField: EditingField?
    @State private var editingText: String = ""
    @FocusState private var isFieldFocused: Bool

    // Cue detection state
    @State private var showDetectedCuesSheet = false
    @State private var detectedCues: [DetectedCue] = []
    @State private var detectedCuesClipName: String = ""

    enum EditingField: Equatable {
        case number
        case title
    }

    private var cues: [Cue] {
        timelineManager.allCues
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            if isExpanded {
                contentArea
            }
        }
        .frame(height: isExpanded ? CuesPanelLayout.expandedHeight : CuesPanelLayout.collapsedHeight, alignment: .top)
        .contentShape(Rectangle())
        .clipped()
        .glassPanel()
        .sheet(isPresented: $showDetectedCuesSheet) {
            DetectedCueListView(
                cues: detectedCues,
                frameRate: timelineManager.timeline.config.frameRate,
                clipName: detectedCuesClipName,
                onImport: { cues in
                    timelineManager.importDetectedCues(cues)
                }
            )
        }
        // Click outside to commit edit
        .onTapGesture {
            if editingCueId != nil {
                commitCurrentEdit()
            }
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 12) {
            // Expand/collapse area
            Button(action: { isExpanded.toggle() }) {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 12)

                    Image(systemName: "flag.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)

                    Text("Cues")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)

                    if !cues.isEmpty {
                        Text("(\(cues.count))")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                // Add cue button
                Button(action: addCue) {
                    HStack(spacing: 4) {
                        Iconoir.plus.asImage
                            .frame(width: 12, height: 12)
                        Text("Add")
                    }
                }
                .buttonStyle(GlassActionButtonStyle(tint: .accentColor))
                .help("Add a new cue at the playhead position")

                // Detect cues from audio menu
                detectCuesMenu

                // Pop-out button
                Button(action: onPopOut) {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("Open cues in separate window")
            }
        }
        .frame(height: PanelLayout.headerHeight)
        .padding(.horizontal, Spacing.md)
    }

    // MARK: - Content Area

    private var contentArea: some View {
        VStack(spacing: 0) {
            if cues.isEmpty {
                emptyStateView
            } else {
                columnHeaders
                cueList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateView: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "flag")
                .font(.system(size: 24))
                .foregroundColor(.secondary.opacity(0.5))

            Text("No cues")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            Text("Add cues to mark important points")
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var columnHeaders: some View {
        HStack(spacing: 0) {
            Text("#")
                .frame(width: CuesPanelLayout.numberColumnWidth, alignment: .leading)
            Text("Title")
                .frame(width: CuesPanelLayout.titleColumnWidth, alignment: .leading)
            Text("TC IN")
                .frame(width: CuesPanelLayout.timecodeColumnWidth, alignment: .leading)
            Text("TC OUT")
                .frame(width: CuesPanelLayout.timecodeColumnWidth, alignment: .leading)
            Text("Duration")
                .frame(width: CuesPanelLayout.durationColumnWidth, alignment: .leading)
            Spacer()
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var cueList: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: 0) {
                ForEach(cues) { cue in
                    cueRow(for: cue)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Cue Row

    @ViewBuilder
    private func cueRow(for cue: Cue) -> some View {
        let isSelected = cue.id == selectedCueId
        let isEditing = editingCueId == cue.id

        HStack(spacing: 0) {
            // Number column - editable
            numberCell(for: cue, isEditing: isEditing && editingField == .number)

            // Title column - editable
            titleCell(for: cue, isEditing: isEditing && editingField == .title)

            // TC IN column - read-only
            Text(cue.timecodeIn(config: timelineManager.timeline.config).stringValue())
                .frame(width: CuesPanelLayout.timecodeColumnWidth, alignment: .leading)
                .monospaced()

            // TC OUT column - read-only
            Text(cue.timecodeOut(config: timelineManager.timeline.config).stringValue())
                .frame(width: CuesPanelLayout.timecodeColumnWidth, alignment: .leading)
                .monospaced()

            // Duration column - read-only
            Text(cue.durationTimecode(at: timelineManager.timeline.config.frameRate).stringValue())
                .frame(width: CuesPanelLayout.durationColumnWidth, alignment: .leading)
                .monospaced()

            Spacer()
        }
        .font(.system(size: 11))
        .padding(.horizontal, Spacing.md)
        .frame(height: CuesPanelLayout.rowHeight)
        .background(rowBackground(isSelected: isSelected, cueId: cue.id))
        .contentShape(Rectangle())
        // Single click to select (but not when editing)
        .gesture(
            TapGesture()
                .onEnded { _ in
                    if editingCueId == nil {
                        selectedCueId = cue.id
                    }
                }
        )
        // Double-click row to seek
        .simultaneousGesture(
            TapGesture(count: 2)
                .onEnded { _ in
                    if editingCueId == nil {
                        onSeekToCue(cue.startFrame)
                    }
                }
        )
        .contextMenu {
            Button("Go to Cue") {
                onSeekToCue(cue.startFrame)
            }
            Button("Edit Title") {
                startEditing(cue: cue, field: .title)
            }
            Divider()
            Button("Delete Cue", role: .destructive) {
                deleteCue(cue)
            }
        }
    }

    @ViewBuilder
    private func rowBackground(isSelected: Bool, cueId: UUID) -> some View {
        if isSelected {
            Color.accentColor.opacity(0.2)
        } else {
            Color.clear
        }
    }

    // MARK: - Editable Cells

    @ViewBuilder
    private func numberCell(for cue: Cue, isEditing: Bool) -> some View {
        if isEditing {
            TextField("", text: $editingText)
                .textFieldStyle(.plain)
                .focused($isFieldFocused)
                .frame(width: CuesPanelLayout.numberColumnWidth - 8, alignment: .leading)
                .padding(.horizontal, 4)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(2)
                .onSubmit { commitCurrentEdit() }
                .onExitCommand { cancelEdit() }
        } else {
            Text("\(cue.number)")
                .frame(width: CuesPanelLayout.numberColumnWidth, alignment: .leading)
                .monospacedDigit()
                .contentShape(Rectangle())
                .simultaneousGesture(
                    TapGesture(count: 2)
                        .onEnded { _ in
                            startEditing(cue: cue, field: .number)
                        }
                )
        }
    }

    @ViewBuilder
    private func titleCell(for cue: Cue, isEditing: Bool) -> some View {
        if isEditing {
            TextField("Enter title", text: $editingText)
                .textFieldStyle(.plain)
                .focused($isFieldFocused)
                .frame(width: CuesPanelLayout.titleColumnWidth - 8, alignment: .leading)
                .padding(.horizontal, 4)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(2)
                .onSubmit { commitCurrentEdit() }
                .onExitCommand { cancelEdit() }
        } else {
            Text(cue.title.isEmpty ? "Untitled" : cue.title)
                .frame(width: CuesPanelLayout.titleColumnWidth, alignment: .leading)
                .foregroundColor(cue.title.isEmpty ? .secondary : .primary)
                .lineLimit(1)
                .contentShape(Rectangle())
                .simultaneousGesture(
                    TapGesture(count: 2)
                        .onEnded { _ in
                            startEditing(cue: cue, field: .title)
                        }
                )
        }
    }

    // MARK: - Actions

    private func addCue() {
        let currentFrame = timelineManager.currentFrame
        let endFrame = currentFrame + Int(timelineManager.timeline.config.frameRate.fps * 5)
        let cue = timelineManager.addCue(startFrame: currentFrame, endFrame: endFrame, title: "")
        selectedCueId = cue.id
        // Start editing title immediately
        startEditing(cue: cue, field: .title)
    }

    private func startEditing(cue: Cue, field: EditingField) {
        // Set up editing state
        editingCueId = cue.id
        editingField = field
        switch field {
        case .number:
            editingText = "\(cue.number)"
        case .title:
            editingText = cue.title
        }

        // Delay focus to ensure TextField is rendered (pattern from AudioLaneView)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            isFieldFocused = true
        }
    }

    private func commitCurrentEdit() {
        guard let cueId = editingCueId,
              let field = editingField,
              let cue = cues.first(where: { $0.id == cueId }) else {
            cancelEdit()
            return
        }

        var updatedCue = cue
        switch field {
        case .number:
            if let newNumber = Int(editingText) {
                updatedCue.number = newNumber
            }
        case .title:
            updatedCue.title = editingText
        }
        updatedCue.lastModified = Date()

        timelineManager.updateCue(updatedCue)
        cancelEdit()
    }

    private func cancelEdit() {
        editingCueId = nil
        editingField = nil
        editingText = ""
        isFieldFocused = false
    }

    private func deleteCue(_ cue: Cue) {
        timelineManager.removeCue(id: cue.id)
        if selectedCueId == cue.id {
            selectedCueId = nil
        }
    }

    // MARK: - Cue Detection

    /// Menu for detecting cues from audio clips
    private var detectCuesMenu: some View {
        Menu {
            let audioClips = allAudioClips
            if audioClips.isEmpty {
                Text("No audio clips")
            } else {
                ForEach(audioClips, id: \.clip.id) { item in
                    let isReady = isWaveformReady(for: item.clip)
                    let isLoading = waveformCache.isLoading(for: item.clip)
                    Button {
                        detectCuesFromClip(item.clip)
                    } label: {
                        if isReady {
                            Text("\(item.clip.displayName) (Lane \(item.laneIndex + 1))")
                        } else if isLoading {
                            Text("\(item.clip.displayName) (Loading...)")
                        } else {
                            Text("\(item.clip.displayName) (No waveform)")
                        }
                    }
                    .disabled(!isReady)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "waveform.circle")
                    .frame(width: 12, height: 12)
                Text("Detect...")
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Detect cues from audio activity")
    }

    /// Checks if waveform data is ready for detection (atlas exists with levels populated)
    private func isWaveformReady(for clip: AudioClip) -> Bool {
        guard let atlas = waveformCache.clipAtlases[clip.id] else { return false }
        return !atlas.levels.isEmpty
    }

    /// All audio clips from all lanes, with lane index for display
    private var allAudioClips: [(clip: AudioClip, laneIndex: Int)] {
        timelineManager.timeline.audioLanes.enumerated().flatMap { laneIndex, lane in
            lane.clips.map { (clip: $0, laneIndex: laneIndex) }
        }
    }

    /// Detects cues from a specific audio clip's waveform data
    private func detectCuesFromClip(_ clip: AudioClip) {
        debugPrint("detectCuesFromClip: clip=\(clip.displayName), id=\(clip.id)")

        guard let atlas = waveformCache.clipAtlases[clip.id] else {
            debugPrint("detectCuesFromClip: NO ATLAS for clip \(clip.id)")
            return
        }

        debugPrint("detectCuesFromClip: atlas found, levels count=\(atlas.levels.count), keys=\(atlas.levels.keys.sorted())")

        guard let level = atlas.levels[4096] ?? atlas.levels.values.first else {
            debugPrint("detectCuesFromClip: NO LEVELS in atlas")
            return
        }

        debugPrint("detectCuesFromClip: level found, rms count=\(level.rms.count)")

        detectedCues = SilenceDetectionService.detectCues(
            from: level,
            clipStartFrame: clip.timelineStartFrame,
            clipDurationFrames: clip.durationFrames,
            timelineConfig: timelineManager.timeline.config
        )
        debugPrint("detectCuesFromClip: detected \(detectedCues.count) cues")
        detectedCuesClipName = clip.displayName
        showDetectedCuesSheet = true
    }
}

#Preview {
    struct PreviewWrapper: View {
        @StateObject var timelineManager = TimelineManager()
        @StateObject var waveformCache = WaveformCache()

        var body: some View {
            CuesPanelView(
                timelineManager: timelineManager,
                waveformCache: waveformCache,
                onSeekToCue: { _ in },
                onPopOut: { }
            )
            .padding()
            .frame(width: 600)
            .onAppear {
                timelineManager.addCue(startFrame: 0, endFrame: 100, title: "Opening")
                timelineManager.addCue(startFrame: 150, endFrame: 300, title: "Scene 1")
                timelineManager.addCue(startFrame: 320, endFrame: 400, title: "Transition")
            }
        }
    }

    return PreviewWrapper()
}
