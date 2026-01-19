import SwiftUI
import SwiftTimecodeCore
import Iconoir

/// Standalone window content for popped-out cues view.
///
/// Provides a larger, resizable interface for viewing and editing cues
/// when popped out from the main window's accordion panel.
struct CuesWindowView: View {
    @ObservedObject var timelineManager: TimelineManager
    let waveformCache: WaveformCache
    let projectName: String
    let onSeekToCue: (Int) -> Void

    @State private var selectedCueId: UUID?
    @State private var editingCueId: UUID?
    @State private var editingField: EditingField?
    @State private var editingText: String = ""
    @State private var sortOrder: SortOrder = .byNumber
    @FocusState private var isFieldFocused: Bool

    // Cue detection state
    @State private var showDetectedCuesSheet = false
    @State private var detectedCues: [DetectedCue] = []
    @State private var detectedCuesClipName: String = ""

    enum EditingField: Equatable {
        case number
        case title
        case notes
    }

    enum SortOrder: String, CaseIterable {
        case byNumber = "Number"
        case byTime = "Time"
        case byTitle = "Title"
    }

    private var cues: [Cue] {
        let allCues = timelineManager.allCues
        switch sortOrder {
        case .byNumber:
            return allCues.sorted { $0.number < $1.number }
        case .byTime:
            return allCues.sorted { $0.startFrame < $1.startFrame }
        case .byTitle:
            return allCues.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if cues.isEmpty {
                emptyStateView
            } else {
                cueTable
            }
            Divider()
            statusBar
        }
        .frame(minWidth: 600, minHeight: 300)
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

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            // Add cue button
            Button(action: addCue) {
                HStack(spacing: 4) {
                    Iconoir.plus.asImage
                        .frame(width: 14, height: 14)
                    Text("Add Cue")
                }
            }
            .buttonStyle(.bordered)

            // Detect cues from audio menu
            detectCuesMenu

            Spacer()

            // Sort picker
            HStack(spacing: 4) {
                Text("Sort:")
                    .foregroundColor(.secondary)
                Picker("Sort", selection: $sortOrder) {
                    ForEach(SortOrder.allCases, id: \.self) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 100)
            }

            // Renumber button
            Button(action: { timelineManager.renumberCues() }) {
                Text("Renumber")
            }
            .buttonStyle(.bordered)
            .help("Renumber all cues sequentially by position")
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "flag")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.5))

            Text("No Cues")
                .font(.title2)
                .foregroundColor(.secondary)

            Text("Add cues to mark important points in your timeline")
                .font(.body)
                .foregroundColor(.secondary.opacity(0.8))

            Button("Add First Cue") {
                addCue()
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, Spacing.sm)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Spacing.xl)
    }

    // MARK: - Cue Table

    private var cueTable: some View {
        VStack(spacing: 0) {
            tableHeader

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 0) {
                    ForEach(cues) { cue in
                        cueRow(for: cue)
                        Divider()
                    }
                }
            }
        }
    }

    private var tableHeader: some View {
        HStack(spacing: 0) {
            Text("#")
                .frame(width: 50, alignment: .leading)
            Text("Title")
                .frame(width: 180, alignment: .leading)
            Text("TC IN")
                .frame(width: 110, alignment: .leading)
            Text("TC OUT")
                .frame(width: 110, alignment: .leading)
            Text("Duration")
                .frame(width: 90, alignment: .leading)
            Text("Notes")
                .frame(minWidth: 100, alignment: .leading)
            Spacer()
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Cue Row

    @ViewBuilder
    private func cueRow(for cue: Cue) -> some View {
        let isSelected = cue.id == selectedCueId
        let isEditing = editingCueId == cue.id

        HStack(spacing: 0) {
            // Number - editable
            editableCell(
                for: cue,
                field: .number,
                value: "\(cue.number)",
                width: 50,
                isEditing: isEditing && editingField == .number
            )

            // Title - editable
            editableCell(
                for: cue,
                field: .title,
                value: cue.title.isEmpty ? "Untitled" : cue.title,
                width: 180,
                isEditing: isEditing && editingField == .title,
                emptyStyle: cue.title.isEmpty
            )

            // TC IN - read-only
            Text(cue.timecodeIn(config: timelineManager.timeline.config).stringValue())
                .frame(width: 110, alignment: .leading)
                .monospaced()

            // TC OUT - read-only
            Text(cue.timecodeOut(config: timelineManager.timeline.config).stringValue())
                .frame(width: 110, alignment: .leading)
                .monospaced()

            // Duration - read-only
            Text(cue.durationTimecode(at: timelineManager.timeline.config.frameRate).stringValue())
                .frame(width: 90, alignment: .leading)
                .monospaced()

            // Notes - editable
            editableCell(
                for: cue,
                field: .notes,
                value: cue.notes.isEmpty ? "-" : cue.notes,
                width: nil,
                isEditing: isEditing && editingField == .notes,
                emptyStyle: cue.notes.isEmpty
            )

            Spacer()
        }
        .font(.system(size: 12))
        .padding(.horizontal, Spacing.md)
        .frame(height: 32)
        .background(rowBackground(isSelected: isSelected))
        .contentShape(Rectangle())
        // Single click to select
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
            Divider()
            Button("Edit Title") {
                startEditing(cue: cue, field: .title)
            }
            Button("Edit Notes") {
                startEditing(cue: cue, field: .notes)
            }
            Divider()
            Button("Delete Cue", role: .destructive) {
                deleteCue(cue)
            }
        }
    }

    @ViewBuilder
    private func rowBackground(isSelected: Bool) -> some View {
        if isSelected {
            Color.accentColor.opacity(0.2)
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func editableCell(
        for cue: Cue,
        field: EditingField,
        value: String,
        width: CGFloat?,
        isEditing: Bool,
        emptyStyle: Bool = false
    ) -> some View {
        if isEditing {
            TextField("", text: $editingText)
                .textFieldStyle(.plain)
                .focused($isFieldFocused)
                .frame(width: width.map { $0 - 8 }, alignment: .leading)
                .padding(.horizontal, 4)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(2)
                .onSubmit { commitCurrentEdit() }
                .onExitCommand { cancelEdit() }
        } else {
            Text(value)
                .frame(width: width, alignment: .leading)
                .foregroundColor(emptyStyle ? .secondary : .primary)
                .lineLimit(1)
                .contentShape(Rectangle())
                .simultaneousGesture(
                    TapGesture(count: 2)
                        .onEnded { _ in
                            startEditing(cue: cue, field: field)
                        }
                )
        }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack {
            Text("\(cues.count) cue\(cues.count == 1 ? "" : "s")")
                .foregroundColor(.secondary)
                .font(.caption)

            Spacer()

            if let selectedId = selectedCueId,
               let cue = cues.first(where: { $0.id == selectedId }) {
                Text("Selected: Cue \(cue.number)")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
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
        editingCueId = cue.id
        editingField = field
        switch field {
        case .number:
            editingText = "\(cue.number)"
        case .title:
            editingText = cue.title
        case .notes:
            editingText = cue.notes
        }

        // Delay focus to ensure TextField is rendered
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
        case .notes:
            updatedCue.notes = editingText
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
                    .frame(width: 14, height: 14)
                Text("Detect...")
            }
        }
        .menuStyle(.borderedButton)
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
        guard let atlas = waveformCache.clipAtlases[clip.id],
              let level = atlas.levels[4096] ?? atlas.levels.values.first else {
            return
        }

        detectedCues = SilenceDetectionService.detectCues(
            from: level,
            clipStartFrame: clip.timelineStartFrame,
            clipDurationFrames: clip.durationFrames,
            timelineConfig: timelineManager.timeline.config
        )
        detectedCuesClipName = clip.displayName
        showDetectedCuesSheet = true
    }
}

#Preview {
    struct PreviewWrapper: View {
        @StateObject var timelineManager = TimelineManager()
        @StateObject var waveformCache = WaveformCache()

        var body: some View {
            CuesWindowView(
                timelineManager: timelineManager,
                waveformCache: waveformCache,
                projectName: "Sample Project",
                onSeekToCue: { _ in }
            )
            .onAppear {
                timelineManager.addCue(startFrame: 0, endFrame: 100, title: "Opening")
                timelineManager.addCue(startFrame: 150, endFrame: 300, title: "Scene 1")
                timelineManager.addCue(startFrame: 320, endFrame: 400, title: "Transition")
            }
        }
    }

    return PreviewWrapper()
}
