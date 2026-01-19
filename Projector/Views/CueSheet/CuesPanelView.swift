import SwiftUI
import SwiftTimecodeCore
import Iconoir

/// Accordion panel for viewing and editing cues.
///
/// Displays cues in a table format with editable fields for title and notes.
/// Supports single-click selection, double-click editing, and pop-out window.
struct CuesPanelView: View {
    @ObservedObject var timelineManager: TimelineManager
    let onSeekToCue: (Int) -> Void
    let onPopOut: () -> Void

    @State private var isExpanded = true
    @State private var selectedCueId: UUID?
    @State private var editingCueId: UUID?
    @State private var editingField: EditingField?
    @State private var editingText: String = ""

    enum EditingField {
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
                    CueRowView(
                        cue: cue,
                        isSelected: cue.id == selectedCueId,
                        editingField: editingCueId == cue.id ? editingField : nil,
                        editingText: editingCueId == cue.id ? $editingText : .constant(""),
                        timelineConfig: timelineManager.timeline.config,
                        onSelect: { selectCue(cue) },
                        onDoubleClick: { field in startEditing(cue: cue, field: field) },
                        onSeek: { onSeekToCue(cue.startFrame) },
                        onCommitEdit: { commitEdit(for: cue) },
                        onCancelEdit: { cancelEdit() },
                        onDelete: { deleteCue(cue) }
                    )
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Actions

    private func addCue() {
        let currentFrame = timelineManager.currentFrame
        let endFrame = currentFrame + Int(timelineManager.timeline.config.frameRate.fps * 5) // 5 second default duration
        let cue = timelineManager.addCue(startFrame: currentFrame, endFrame: endFrame, title: "")
        selectedCueId = cue.id
    }

    private func selectCue(_ cue: Cue) {
        selectedCueId = cue.id
    }

    private func startEditing(cue: Cue, field: EditingField) {
        editingCueId = cue.id
        editingField = field
        switch field {
        case .number:
            editingText = "\(cue.number)"
        case .title:
            editingText = cue.title
        }
    }

    private func commitEdit(for cue: Cue) {
        guard let field = editingField else { return }

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
    }

    private func deleteCue(_ cue: Cue) {
        timelineManager.removeCue(id: cue.id)
        if selectedCueId == cue.id {
            selectedCueId = nil
        }
    }
}

/// Individual cue row in the cues panel.
struct CueRowView: View {
    let cue: Cue
    let isSelected: Bool
    let editingField: CuesPanelView.EditingField?
    @Binding var editingText: String
    let timelineConfig: TimelineConfig
    let onSelect: () -> Void
    let onDoubleClick: (CuesPanelView.EditingField) -> Void
    let onSeek: () -> Void
    let onCommitEdit: () -> Void
    let onCancelEdit: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            // Number column
            numberCell

            // Title column
            titleCell

            // TC IN column
            Text(cue.timecodeIn(config: timelineConfig).stringValue())
                .frame(width: CuesPanelLayout.timecodeColumnWidth, alignment: .leading)
                .monospaced()

            // TC OUT column
            Text(cue.timecodeOut(config: timelineConfig).stringValue())
                .frame(width: CuesPanelLayout.timecodeColumnWidth, alignment: .leading)
                .monospaced()

            // Duration column
            Text(cue.durationTimecode(at: timelineConfig.frameRate).stringValue())
                .frame(width: CuesPanelLayout.durationColumnWidth, alignment: .leading)
                .monospaced()

            Spacer()
        }
        .font(.system(size: 11))
        .padding(.horizontal, Spacing.md)
        .frame(height: CuesPanelLayout.rowHeight)
        .background(rowBackground)
        .onTapGesture {
            onSelect()
        }
        .simultaneousGesture(
            TapGesture(count: 2)
                .onEnded { _ in
                    onSeek()
                }
        )
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            Button("Go to Cue") {
                onSeek()
            }
            Divider()
            Button("Delete Cue", role: .destructive) {
                onDelete()
            }
        }
    }

    private var rowBackground: some View {
        Group {
            if isSelected {
                Color.accentColor.opacity(0.2)
            } else if isHovered {
                Color(nsColor: .controlBackgroundColor).opacity(0.5)
            } else {
                Color.clear
            }
        }
    }

    private var numberCell: some View {
        Group {
            if editingField == .number {
                TextField("", text: $editingText)
                    .textFieldStyle(.plain)
                    .focused($isTextFieldFocused)
                    .frame(width: CuesPanelLayout.numberColumnWidth - 8, alignment: .leading)
                    .onSubmit { onCommitEdit() }
                    .onExitCommand { onCancelEdit() }
                    .onAppear { isTextFieldFocused = true }
            } else {
                Text("\(cue.number)")
                    .frame(width: CuesPanelLayout.numberColumnWidth, alignment: .leading)
                    .monospacedDigit()
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        onDoubleClick(.number)
                    }
            }
        }
    }

    private var titleCell: some View {
        Group {
            if editingField == .title {
                TextField("", text: $editingText)
                    .textFieldStyle(.plain)
                    .focused($isTextFieldFocused)
                    .frame(width: CuesPanelLayout.titleColumnWidth - 8, alignment: .leading)
                    .onSubmit { onCommitEdit() }
                    .onExitCommand { onCancelEdit() }
                    .onAppear { isTextFieldFocused = true }
            } else {
                Text(cue.title.isEmpty ? "-" : cue.title)
                    .frame(width: CuesPanelLayout.titleColumnWidth, alignment: .leading)
                    .foregroundColor(cue.title.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        onDoubleClick(.title)
                    }
            }
        }
    }
}

#Preview {
    struct PreviewWrapper: View {
        @StateObject var timelineManager = TimelineManager()

        var body: some View {
            CuesPanelView(
                timelineManager: timelineManager,
                onSeekToCue: { _ in },
                onPopOut: { }
            )
            .padding()
            .frame(width: 600)
            .onAppear {
                // Add sample cues
                timelineManager.addCue(startFrame: 0, endFrame: 100, title: "Opening")
                timelineManager.addCue(startFrame: 150, endFrame: 300, title: "Scene 1")
                timelineManager.addCue(startFrame: 320, endFrame: 400, title: "Transition")
            }
        }
    }

    return PreviewWrapper()
}
