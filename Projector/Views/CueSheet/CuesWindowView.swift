import SwiftUI
import SwiftTimecodeCore
import Iconoir

/// Standalone window content for popped-out cues view.
///
/// Provides a larger, resizable interface for viewing and editing cues
/// when popped out from the main window's accordion panel.
struct CuesWindowView: View {
    @ObservedObject var timelineManager: TimelineManager
    let projectName: String
    let onSeekToCue: (Int) -> Void

    @State private var selectedCueId: UUID?
    @State private var editingCueId: UUID?
    @State private var editingField: EditingField?
    @State private var editingText: String = ""
    @State private var sortOrder: SortOrder = .byNumber

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
            // Column headers
            tableHeader

            // Rows
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 0) {
                    ForEach(cues) { cue in
                        CueWindowRowView(
                            cue: cue,
                            isSelected: cue.id == selectedCueId,
                            editingField: editingCueId == cue.id ? editingField : nil,
                            editingText: editingCueId == cue.id ? $editingText : .constant(""),
                            timelineConfig: timelineManager.timeline.config,
                            onSelect: { selectedCueId = cue.id },
                            onDoubleClick: { field in startEditing(cue: cue, field: field) },
                            onSeek: { onSeekToCue(cue.startFrame) },
                            onCommitEdit: { commitEdit(for: cue) },
                            onCancelEdit: { cancelEdit() },
                            onDelete: { deleteCue(cue) }
                        )
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
        editingCueId = cue.id
        editingField = .title
        editingText = ""
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
    }

    private func deleteCue(_ cue: Cue) {
        timelineManager.removeCue(id: cue.id)
        if selectedCueId == cue.id {
            selectedCueId = nil
        }
    }
}

/// Row view for the cues window table.
struct CueWindowRowView: View {
    let cue: Cue
    let isSelected: Bool
    let editingField: CuesWindowView.EditingField?
    @Binding var editingText: String
    let timelineConfig: TimelineConfig
    let onSelect: () -> Void
    let onDoubleClick: (CuesWindowView.EditingField) -> Void
    let onSeek: () -> Void
    let onCommitEdit: () -> Void
    let onCancelEdit: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            // Number
            editableCell(
                value: "\(cue.number)",
                width: 50,
                field: .number,
                isEditing: editingField == .number
            )

            // Title
            editableCell(
                value: cue.title.isEmpty ? "-" : cue.title,
                width: 180,
                field: .title,
                isEditing: editingField == .title,
                emptyStyle: cue.title.isEmpty
            )

            // TC IN
            Text(cue.timecodeIn(config: timelineConfig).stringValue())
                .frame(width: 110, alignment: .leading)
                .monospaced()

            // TC OUT
            Text(cue.timecodeOut(config: timelineConfig).stringValue())
                .frame(width: 110, alignment: .leading)
                .monospaced()

            // Duration
            Text(cue.durationTimecode(at: timelineConfig.frameRate).stringValue())
                .frame(width: 90, alignment: .leading)
                .monospaced()

            // Notes
            editableCell(
                value: cue.notes.isEmpty ? "-" : cue.notes,
                width: nil,
                field: .notes,
                isEditing: editingField == .notes,
                emptyStyle: cue.notes.isEmpty
            )

            Spacer()
        }
        .font(.system(size: 12))
        .padding(.horizontal, Spacing.md)
        .frame(height: 32)
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
            Button("Edit Title") {
                onDoubleClick(.title)
            }
            Button("Edit Notes") {
                onDoubleClick(.notes)
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

    @ViewBuilder
    private func editableCell(
        value: String,
        width: CGFloat?,
        field: CuesWindowView.EditingField,
        isEditing: Bool,
        emptyStyle: Bool = false
    ) -> some View {
        if isEditing {
            TextField("", text: $editingText)
                .textFieldStyle(.plain)
                .focused($isTextFieldFocused)
                .frame(width: width.map { $0 - 8 }, alignment: .leading)
                .onSubmit { onCommitEdit() }
                .onExitCommand { onCancelEdit() }
                .onAppear { isTextFieldFocused = true }
        } else {
            Text(value)
                .frame(width: width, alignment: .leading)
                .foregroundColor(emptyStyle ? .secondary : .primary)
                .lineLimit(1)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    onDoubleClick(field)
                }
        }
    }
}

#Preview {
    struct PreviewWrapper: View {
        @StateObject var timelineManager = TimelineManager()

        var body: some View {
            CuesWindowView(
                timelineManager: timelineManager,
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
