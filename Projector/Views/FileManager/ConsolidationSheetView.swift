//
//  ConsolidationSheetView.swift
//  Projector
//
//  Sheet for consolidating external media files into the project folder.
//

import SwiftUI
import AppKit

/// Sheet view for consolidating external media into the project folder
struct ConsolidationSheetView: View {
    @ObservedObject var mediaLibrary: ProjectMediaLibrary
    @ObservedObject var projectDocument: ProjectDocument
    @Environment(\.dismiss) private var dismiss
    let onSaveProject: () -> Void
    var onRequestConsolidationAfterSave: (() -> Void)?

    @State private var state: ConsolidationState = .ready
    @State private var result: ProjectMediaLibrary.ConsolidationResult?

    private enum ConsolidationState: Equatable {
        case ready
        case consolidating
        case complete
        case error(String)
    }

    /// Whether the project has been saved
    private var isProjectSaved: Bool {
        projectDocument.fileURL != nil
    }

    /// External media items that need consolidation
    private var externalItems: [MediaItem] {
        guard let projectURL = projectDocument.fileURL else { return [] }
        return mediaLibrary.externalMediaItems(projectURL: projectURL)
    }

    var body: some View {
        Group {
            if !isProjectSaved {
                unsavedProjectView
            } else {
                mainContentView
            }
        }
    }

    // MARK: - Unsaved Project View

    private var unsavedProjectView: some View {
        VStack(spacing: 0) {
            VStack(spacing: Spacing.lg) {
                Image(systemName: "doc.badge.arrow.up")
                    .font(.system(size: 56))
                    .foregroundColor(.secondary)

                Text("Save Project to Consolidate")
                    .font(.headline)

                Text("Projects must be saved before media can be consolidated.\nThis allows media files to be stored in your project folder.")
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            .frame(maxHeight: .infinity)

            Divider()

            HStack(spacing: Spacing.md) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                    .controlSize(.regular)

                Button("Save Project...") {
                    onRequestConsolidationAfterSave?()
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        onSaveProject()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
            .frame(height: 52)
            .padding(.horizontal)
        }
        .frame(width: 400, height: 260)
    }

    // MARK: - Main Content View

    private var mainContentView: some View {
        VStack(spacing: 0) {
            // Header
            header

            Divider()

            // Content based on state
            switch state {
            case .ready:
                readyView
            case .consolidating:
                consolidatingView
            case .complete:
                completeView
            case .error(let message):
                errorView(message: message)
            }

            Divider()

            // Footer
            footer
        }
        .frame(width: 500, height: 400)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text(headerTitle)
                .font(.headline)
            Spacer()
            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close")
            .accessibilityLabel("Close")
        }
        .padding()
    }

    private var headerTitle: String {
        switch state {
        case .ready: return "Consolidate Media"
        case .consolidating: return "Consolidating..."
        case .complete: return "Consolidation Complete"
        case .error: return "Consolidation Error"
        }
    }

    // MARK: - Ready View

    private var readyView: some View {
        VStack(spacing: 0) {
            // File list
            ScrollView {
                LazyVStack(spacing: 0) {
                    HStack {
                        Text("File")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Location")
                            .frame(width: 200, alignment: .leading)
                    }
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
                    .padding(.vertical, Spacing.sm)

                    Divider()

                    ForEach(externalItems) { item in
                        HStack {
                            Image(systemName: item.type == .video ? "film" : "waveform")
                                .foregroundColor(item.type == .video ? .blue : .green)
                                .frame(width: 16)

                            Text(item.displayName)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Text(item.url.deletingLastPathComponent().lastPathComponent)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .frame(width: 200, alignment: .leading)
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 6)
                    }
                }
            }
            .frame(maxHeight: 200)

            Divider()

            // Info section
            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack {
                    Image(systemName: "folder.badge.plus")
                        .foregroundColor(.orange)
                    Text("\(externalItems.count) file(s) will be copied to the project's Media folder")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack {
                    Image(systemName: "checkmark.circle")
                        .foregroundColor(.green)
                    Text("Original files will not be modified or deleted")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack {
                    Image(systemName: "checkmark.circle")
                        .foregroundColor(.green)
                    Text("Project will remain portable and self-contained")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
        }
    }

    // MARK: - Consolidating View

    private var consolidatingView: some View {
        VStack(spacing: Spacing.xl) {
            Spacer()
            ProgressView()
                .scaleEffect(1.5)
            Text("Copying files to project folder...")
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    // MARK: - Complete View

    private var completeView: some View {
        VStack(spacing: Spacing.xl) {
            Spacer()

            if let result = result {
                Image(systemName: result.failedCount == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(Typography.iconEmptyState)
                    .foregroundColor(result.failedCount == 0 ? .green : .orange)

                VStack(spacing: Spacing.sm) {
                    Text("Copied \(result.copiedCount) file(s)")
                        .font(.headline)

                    if result.skippedCount > 0 {
                        Text("\(result.skippedCount) file(s) were already local")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    if result.failedCount > 0 {
                        Text("\(result.failedCount) file(s) failed")
                            .font(.subheadline)
                            .foregroundColor(.red)

                        ScrollView {
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                ForEach(result.errors, id: \.self) { error in
                                    Text("• \(error)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .frame(maxHeight: 80)
                        .padding(.horizontal)
                    }
                }
            }

            Spacer()
        }
    }

    // MARK: - Error View

    private func errorView(message: String) -> some View {
        VStack(spacing: Spacing.xl) {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .font(Typography.iconEmptyState)
                .foregroundColor(.orange)

            Text("Consolidation Error")
                .font(.headline)

            Text(message)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Spacer()
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if state == .ready {
                Text("\(externalItems.count) external file(s)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            switch state {
            case .ready:
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button("Consolidate \(externalItems.count) File\(externalItems.count == 1 ? "" : "s")") {
                    startConsolidation()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(externalItems.isEmpty)

            case .consolidating:
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(true)

            case .complete, .error:
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
    }

    // MARK: - Actions

    private func startConsolidation() {
        guard let projectURL = projectDocument.fileURL else { return }

        state = .consolidating

        Task {
            let consolidationResult = await mediaLibrary.consolidateMedia(projectURL: projectURL)
            result = consolidationResult

            if consolidationResult.failedCount > 0 && consolidationResult.copiedCount == 0 {
                state = .error("All files failed to consolidate")
            } else {
                state = .complete
            }
        }
    }
}

// MARK: - Prepare Media

/// Single entry point for the two media-housekeeping operations.
///
/// Collecting and reducing are genuinely different jobs — one moves files, the
/// other re-encodes them — but they used to sit side by side in the Media header
/// as similar pill buttons with no indication of which did what, so they read as
/// two buttons for the same thing. They're now steps inside one sheet, each
/// stating what it will do and how many files it affects, independently
/// selectable, and run in order (collect first, so reduction operates on files
/// already inside the project).
struct PrepareMediaSheetView: View {
    @ObservedObject var mediaLibrary: ProjectMediaLibrary
    @ObservedObject var projectDocument: ProjectDocument
    @Environment(\.dismiss) private var dismiss

    /// Runs the existing consolidation flow.
    let onCollect: () -> Void
    /// Runs the existing optimization flow.
    let onReduce: () -> Void
    /// Project must be saved before either step can run.
    let onSaveProject: () -> Void

    @State private var collectSelected = true
    @State private var reduceSelected = false

    private var isProjectSaved: Bool { projectDocument.fileURL != nil }

    private var externalCount: Int {
        guard let projectURL = projectDocument.fileURL else { return 0 }
        return mediaLibrary.externalMediaItems(projectURL: projectURL).count
    }

    private var reducibleCount: Int {
        mediaLibrary.items.filter { item in
            if case .needsOptimization = OptimizationStatusHelper.status(for: item) { return true }
            return false
        }.count
    }

    private var canRun: Bool {
        isProjectSaved
            && ((collectSelected && externalCount > 0) || (reduceSelected && reducibleCount > 0))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if isProjectSaved {
                stepsList
            } else {
                unsavedPrompt
            }

            Divider()
            footer
        }
        .frame(width: 520)
        .onAppear {
            // Preselect whatever there is actually work for.
            collectSelected = externalCount > 0
            reduceSelected = externalCount == 0 && reducibleCount > 0
        }
    }

    private var header: some View {
        HStack {
            Text("Prepare Media")
                .font(.headline)
            Spacer()
            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close")
            .accessibilityLabel("Close")
        }
        .padding()
    }

    private var stepsList: some View {
        VStack(spacing: 0) {
            stepRow(
                isOn: $collectSelected,
                enabled: externalCount > 0,
                icon: "folder.badge.plus",
                tint: AppColors.accentGreen,
                title: "Collect files into project folder",
                detail: externalCount > 0
                    ? "\(externalCount) file\(externalCount == 1 ? " is" : "s are") stored outside the project. Copies them in so the project stays portable. Originals are left untouched."
                    : "All media is already inside the project folder."
            )

            Divider().padding(.leading, 52)

            stepRow(
                isOn: $reduceSelected,
                enabled: reducibleCount > 0,
                icon: "bolt.fill",
                tint: AppColors.accent,
                title: "Reduce file sizes for playback",
                detail: reducibleCount > 0
                    ? "\(reducibleCount) file\(reducibleCount == 1 ? "" : "s") could play back more smoothly. Re-encodes to smaller files — you'll be asked before any original is removed."
                    : "No files need reducing."
            )
        }
        .padding(.vertical, Spacing.sm)
    }

    private func stepRow(
        isOn: Binding<Bool>,
        enabled: Bool,
        icon: String,
        tint: Color,
        title: String,
        detail: String
    ) -> some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            Button(action: { if enabled { isOn.wrappedValue.toggle() } }) {
                Image(systemName: isOn.wrappedValue && enabled ? "checkmark.square.fill" : "square")
                    .font(.system(size: 16))
                    .foregroundColor(enabled ? (isOn.wrappedValue ? tint : .secondary) : .secondary.opacity(0.4))
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .accessibilityLabel(title)

            Image(systemName: icon)
                .font(Typography.iconMedium)
                .foregroundColor(enabled ? tint : .secondary.opacity(0.4))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(title)
                    .font(Typography.heading)
                    .foregroundColor(enabled ? .primary : .secondary)
                Text(detail)
                    .font(Typography.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, Spacing.md)
        .contentShape(Rectangle())
    }

    private var unsavedPrompt: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "doc.badge.arrow.up")
                .font(Typography.iconEmptyState)
                .foregroundColor(.secondary)
            Text("Save the project first")
                .font(Typography.heading)
            Text("Media can only be collected or reduced once the project has a folder on disk.")
                .font(Typography.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(Spacing.xl)
    }

    private var footer: some View {
        HStack(spacing: Spacing.md) {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.bordered)

            if isProjectSaved {
                Button("Continue") {
                    // Collect first: reduction should operate on files that are
                    // already inside the project folder.
                    let doCollect = collectSelected && externalCount > 0
                    let doReduce = reduceSelected && reducibleCount > 0
                    dismiss()
                    if doCollect {
                        onCollect()
                    } else if doReduce {
                        onReduce()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canRun)
            } else {
                Button("Save Project...") {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        onSaveProject()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(height: 52)
        .padding(.horizontal)
    }
}
