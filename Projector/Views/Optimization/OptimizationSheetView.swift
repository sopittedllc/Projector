//
//  OptimizationSheetView.swift
//  Projector
//
//  Sheet for analyzing and optimizing media files.
//  Shows analysis results, progress, and verification report.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Main optimization sheet view
struct OptimizationSheetView: View {
    @ObservedObject var viewModel: OptimizationViewModel
    @ObservedObject var projectDocument: ProjectDocument
    @Environment(\.dismiss) private var dismiss
    let onSaveProject: () -> Void
    /// Called when user saves from unsaved project view - signals to re-open optimization after save
    var onRequestOptimizationAfterSave: (() -> Void)?

    var body: some View {
        Group {
            // Show a simple alert if project isn't saved
            if !viewModel.isProjectSaved {
                unsavedProjectView
            } else {
                VStack(spacing: 0) {
                    // Header
                    header

                    Divider()

                    // Content based on state
                    switch viewModel.state {
                    case .idle:
                        idleView
                    case .analyzing:
                        analyzingView
                    case .ready:
                        readyView
                    case .optimizing:
                        optimizingView
                    case .complete:
                        completeView
                    case .error(let message):
                        errorView(message: message)
                    }

                    Divider()

                    // Footer with actions
                    footer
                }
                .frame(width: 600, height: 500)
            }
        }
        .onAppear {
            debugPrint("OptimizationSheetView: onAppear - projectURL: \(String(describing: projectDocument.fileURL)), isProjectSaved: \(viewModel.isProjectSaved), state: \(viewModel.state)")
            debugPrint("OptimizationSheetView: media library has \(viewModel.analysisResult.items.count) items analyzed")
            // Only analyze if project is saved
            if viewModel.isProjectSaved && viewModel.state == .idle {
                debugPrint("OptimizationSheetView: calling analyze()")
                viewModel.analyze()
            } else {
                debugPrint("OptimizationSheetView: NOT calling analyze() - isProjectSaved: \(viewModel.isProjectSaved), state: \(viewModel.state)")
            }
        }
        .onChangeCompat(of: viewModel.state) { newState in
            debugPrint("OptimizationSheetView: state changed to \(newState)")
        }
        .onChangeCompat(of: projectDocument.fileURL) { newURL in
            debugPrint("OptimizationSheetView: projectDocument.fileURL changed to \(String(describing: newURL))")
        }
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
        switch viewModel.state {
        case .idle, .analyzing: return "Analyzing Media..."
        case .ready: return "Optimize Media"
        case .optimizing: return "Optimizing..."
        case .complete: return "Optimization Complete"
        case .error: return "Optimization Error"
        }
    }

    // MARK: - Idle View

    private var idleView: some View {
        VStack {
            Spacer()
            ProgressView()
                .scaleEffect(1.5)
            Text("Preparing...")
                .foregroundColor(.secondary)
                .padding(.top)
            Spacer()
        }
    }

    // MARK: - Analyzing View

    private var analyzingView: some View {
        VStack {
            Spacer()
            ProgressView()
                .scaleEffect(1.5)
            Text("Analyzing media files...")
                .foregroundColor(.secondary)
                .padding(.top)
            Spacer()
        }
    }

    // MARK: - Ready View (Analysis Complete)

    private var readyView: some View {
        VStack(spacing: 0) {
            // File list
            fileListView

            Divider()

            // Summary
            summaryView

            // Optimization info (no options needed - we always preserve originals)
            optimizationInfoView
        }
    }

    private var fileListView: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // Header row with select all optimizable (2.4)
                HStack {
                    // Select all optimizable checkbox
                    Button(action: {
                        if viewModel.allSelected {
                            viewModel.deselectAll()
                        } else {
                            viewModel.selectAll()
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: viewModel.allSelected ? "checkmark.square.fill" : "square")
                                .foregroundColor(viewModel.allSelected ? .accentColor : .secondary)
                            Text(viewModel.allSelected ? "Deselect All" : "Select All Optimizable")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Selects only files that can be optimized (skips already-optimized)")

                    Spacer()

                    Text("File")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Current")
                        .frame(width: 80, alignment: .trailing)
                    Text("Optimized")
                        .frame(width: 80, alignment: .trailing)
                    Text("Savings / Status")
                        .frame(width: 140, alignment: .trailing)
                }
                .font(.caption.bold())
                .foregroundColor(.secondary)
                .padding(.horizontal)
                .padding(.vertical, Spacing.sm)

                Divider()

                // File rows (3.2 - with alternating backgrounds)
                ForEach(Array(viewModel.analysisResult.items.enumerated()), id: \.element.id) { index, item in
                    FileAnalysisRow(
                        item: item,
                        isSelected: viewModel.isSelected(item.id),
                        rowIndex: index,
                        onToggle: { viewModel.toggleSelection(for: item.id) }
                    )
                }
            }
        }
        .frame(maxHeight: 200)
    }

    private var summaryView: some View {
        HStack {
            Text("Selected: \(viewModel.selectedCount) of \(viewModel.itemsNeedingOptimizationCount)")
                .font(.headline)

            Spacer()

            if viewModel.selectedCount > 0 {
                Text(ByteCountFormatter.string(fromByteCount: Int64(viewModel.selectedTotalSize), countStyle: .file))
                    .foregroundColor(.secondary)

                Image(systemName: "arrow.right")
                    .foregroundColor(.secondary)
                    .padding(.horizontal, Spacing.xs)

                Text(ByteCountFormatter.string(fromByteCount: Int64(viewModel.selectedEstimatedSize), countStyle: .file))
                    .foregroundColor(.green)

                Text("(Save \(viewModel.selectedSavingsFormatted))")
                    .foregroundColor(.green)
                    .fontWeight(.semibold)
            }
        }
        .padding()
    }

    private var optimizationInfoView: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack {
                Image(systemName: "folder.badge.plus")
                    .foregroundColor(.blue)
                Text("Optimized files will be saved to \"Optimized Media\" folder")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack {
                Image(systemName: "info.circle")
                    .foregroundColor(.blue)
                Text("Video: H.264 720p ~2Mbps  |  Audio: AAC Stereo 160kbps")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack {
                Image(systemName: "checkmark.circle")
                    .foregroundColor(.green)
                Text("Original files will not be modified")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack {
                Image(systemName: "checkmark.circle")
                    .foregroundColor(.green)
                Text("Frame rates and sample rates will be preserved")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
    }

    // MARK: - Optimizing View

    private var optimizingView: some View {
        VStack(spacing: Spacing.xl) {
            Spacer()

            Text(viewModel.progressText)
                .font(.headline)

            // Current item progress
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Current file:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                ProgressView(value: viewModel.currentItemProgress)
                    .progressViewStyle(.linear)
            }
            .padding(.horizontal, 40)

            // Overall progress
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Overall progress:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                ProgressView(value: viewModel.overallProgress)
                    .progressViewStyle(.linear)
                HStack {
                    Text("\(Int(viewModel.overallProgress * 100))%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    if let timeRemaining = viewModel.timeRemainingFormatted {
                        Text(timeRemaining)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 40)

            Spacer()
        }
    }

    // MARK: - Complete View (Two-Step Cleanup)

    private var completeView: some View {
        VStack(spacing: 0) {
            Spacer()

            // Success icon
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(Typography.iconEmptyState)
                .padding(.bottom, Spacing.md)

            // Success message
            VStack(spacing: Spacing.xs) {
                Text("Optimization Complete")
                    .font(.headline)

                if let result = viewModel.result {
                    let saved = result.totalSavedBytes
                    if saved > 0 {
                        Text("\(result.optimizedCount) files optimized, saving \(ByteCountFormatter.string(fromByteCount: Int64(saved), countStyle: .file))")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.bottom, Spacing.lg)

            // Explanation
            Text("Original files are still in library.")
                .font(.body)
                .foregroundColor(.secondary)
                .padding(.bottom, Spacing.xs)

            Text("What would you like to do with them?")
                .font(.body)
                .foregroundColor(.primary)
                .padding(.bottom, Spacing.lg)

            // Cleanup options (radio buttons)
            VStack(alignment: .leading, spacing: Spacing.sm) {
                CleanupOptionButton(
                    title: "Keep originals where they are",
                    isSelected: viewModel.cleanupAction == nil,
                    action: { viewModel.cleanupAction = nil }
                )

                CleanupOptionButton(
                    title: "Move to \"Raw Files\" folder",
                    isSelected: viewModel.cleanupAction == .moveToRawFolder,
                    action: { viewModel.cleanupAction = .moveToRawFolder }
                )

                CleanupOptionButton(
                    title: "Move to Trash",
                    isSelected: viewModel.cleanupAction == .deleteOriginals,
                    action: { viewModel.cleanupAction = .deleteOriginals }
                )
            }
            .padding(.horizontal, 40)

            Spacer()
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Error View

    private func errorView(message: String) -> some View {
        VStack(spacing: Spacing.xl) {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .font(Typography.iconEmptyState)
                .foregroundColor(.orange)

            Text("Optimization Error")
                .font(.headline)

            Text(message)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Spacer()
        }
    }

    // MARK: - Unsaved Project View

    /// Simple alert shown when trying to optimize an unsaved project
    private var unsavedProjectView: some View {
        VStack(spacing: 0) {
            // Content area
            VStack(spacing: Spacing.lg) {
                Image(systemName: "doc.badge.gearshape")
                    .font(.system(size: 56))
                    .foregroundColor(.secondary)

                Text("Save Project to Optimize")
                    .font(.headline)

                Text("Projects must be saved before media can be optimized.\nThis allows optimized files to be stored in your project folder.")
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            .frame(maxHeight: .infinity)

            Divider()

            // Footer with buttons
            HStack(spacing: Spacing.md) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                    .controlSize(.regular)

                Button("Save Project...") {
                    // Request optimization to re-open after save completes
                    onRequestOptimizationAfterSave?()
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

    // MARK: - Footer

    private var footer: some View {
        HStack {
            // Left side info
            if viewModel.state == .ready {
                if viewModel.selectedCount > 0 {
                    Text("\(viewModel.selectedCount) of \(viewModel.itemsNeedingOptimizationCount) files selected")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("Select files to optimize")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            Spacer()

            // Action buttons
            switch viewModel.state {
            case .idle, .analyzing:
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

            case .ready:
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button("Optimize \(viewModel.selectedCount) File\(viewModel.selectedCount == 1 ? "" : "s")") {
                    viewModel.startOptimization()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!viewModel.canOptimize)

            case .optimizing:
                Button("Cancel") {
                    viewModel.cancel()
                }
                .keyboardShortcut(.cancelAction)

            case .complete:
                Button("Done") {
                    Task {
                        // Execute cleanup if user selected an action
                        if viewModel.cleanupAction != nil {
                            try? await viewModel.executeCleanup()
                        }
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)

            case .error:
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
    }

    // MARK: - Save Panel

    /// Shows an NSSavePanel for saving the project.
    /// Uses NSSavePanel with beginSheetModal on the main window to get proper sandbox access.
    private func showSavePanel() {
        // Use NSSavePanel to save the .projector package
        let panel = NSSavePanel()
        panel.title = "Save Project"
        panel.prompt = "Save"
        panel.nameFieldLabel = "Project Name:"
        panel.nameFieldStringValue = "Untitled"
        // Set up for package/bundle type
        if let projectorType = UTType(filenameExtension: "projector") {
            panel.allowedContentTypes = [projectorType]
        }
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.message = "Choose a name and location for your project"
        // Treat as directory (package)
        panel.treatsFilePackagesAsDirectories = false

        debugPrint("OptimizationSheetView.showSavePanel: opening save panel")

        // Find the main application window (not the sheet)
        guard let mainWindow = NSApp.windows.first(where: { $0.isVisible && !$0.isSheet }) else {
            debugPrint("OptimizationSheetView.showSavePanel: could not find main window, falling back to runModal")
            // Fallback to runModal if we can't find a window
            if panel.runModal() == .OK, let fileURL = panel.url {
                saveProjectToURL(fileURL)
            }
            return
        }

        debugPrint("OptimizationSheetView.showSavePanel: showing as sheet on main window")

        // Show as sheet on the main window - this grants sandbox permissions
        panel.beginSheetModal(for: mainWindow) { [weak projectDocument] response in
            if response == .OK, let fileURL = panel.url, let document = projectDocument {
                Self.performSave(document: document, to: fileURL)
            } else {
                debugPrint("OptimizationSheetView.showSavePanel: user cancelled")
            }
        }
    }

    /// Save project to the specified URL
    private func saveProjectToURL(_ fileURL: URL) {
        Self.performSave(document: projectDocument, to: fileURL)
    }

    /// Static method to perform save (allows use from closure)
    private static func performSave(document: ProjectDocument, to fileURL: URL) {
        debugPrint("OptimizationSheetView: saving to \(fileURL.path)")

        // Ensure the file has .projector extension
        var saveURL = fileURL
        if saveURL.pathExtension != "projector" {
            saveURL = saveURL.appendingPathExtension("projector")
        }

        do {
            // Save the project to the selected location
            try document.save(to: saveURL)
            debugPrint("OptimizationSheetView: project saved to \(saveURL.path)")
        } catch {
            debugPrint("OptimizationSheetView: save failed - \(error.localizedDescription)")
        }
    }
}

// MARK: - Supporting Views

/// Row showing file analysis result with selection checkbox
private struct FileAnalysisRow: View {
    let item: MediaAnalysisItem
    let isSelected: Bool
    let rowIndex: Int
    let onToggle: () -> Void

    @State private var isHovered = false

    // Alternating background (3.2)
    private var rowBackground: Color {
        if isSelected {
            return Color.accentColor.opacity(0.15)
        }
        if isHovered && item.needsOptimization {
            return Color.accentColor.opacity(0.08)
        }
        return rowIndex.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.03)
    }

    var body: some View {
        HStack {
            // Checkbox (only for items needing optimization)
            if item.needsOptimization {
                Button(action: onToggle) {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .foregroundColor(isSelected ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 20)
                .help(isSelected ? "Exclude from optimization" : "Include in optimization")
                .accessibilityLabel(isSelected ? "Selected for optimization" : "Not selected for optimization")
            } else {
                // Placeholder for alignment
                Color.clear.frame(width: 20)
            }

            // File info
            HStack(spacing: Spacing.sm) {
                Image(systemName: item.isVideo ? "film" : "waveform")
                    .foregroundColor(item.isVideo ? .blue : .green)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(item.displayName)
                        .lineLimit(1)
                    if let codec = item.currentCodec {
                        Text(codec)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Sizes
            Text(formatBytes(item.originalSize))
                .font(.system(.body, design: .monospaced))
                .frame(width: 80, alignment: .trailing)
                .foregroundColor(.secondary)

            Text(formatBytes(item.estimatedOptimizedSize))
                .font(.system(.body, design: .monospaced))
                .frame(width: 80, alignment: .trailing)
                .foregroundColor(item.needsOptimization ? .primary : .secondary)

            // Savings or skip reason
            if item.needsOptimization {
                Text("\(formatBytes(item.estimatedSavings)) (\(Int(item.savingsPercentage * 100))%)")
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 140, alignment: .trailing)
                    .foregroundColor(.green)
            } else {
                Text(item.skipReason ?? "Already optimized")
                    .font(.caption)
                    .frame(width: 140, alignment: .trailing)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture {
            // Click anywhere on row to toggle (3.2)
            if item.needsOptimization {
                onToggle()
            }
        }
        .cursor(item.needsOptimization ? .pointingHand : .arrow)
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// Radio button option for cleanup actions
private struct CleanupOptionButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .font(.system(size: 14))

                Text(title)
                    .font(Typography.body)
                    .foregroundColor(.primary)

                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Cleanup Original Files Dialog

/// Dialog for cleaning up original files after optimization
private struct CleanupOriginalFilesDialog: View {
    @ObservedObject var viewModel: OptimizationViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var isProcessing = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Cleanup Original Files")
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

            Divider()

            // Content
            VStack(spacing: Spacing.lg) {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    Text("Optimized files are now in use.")
                        .font(.subheadline)

                    Text("What would you like to do with the original files?")
                        .font(.subheadline)

                    Text("(\(ByteCountFormatter.string(fromByteCount: Int64(viewModel.totalOriginalFilesSize), countStyle: .file)))")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    // Keep originals
                    Button {
                        viewModel.cleanupAction = nil
                    } label: {
                        HStack {
                            Image(systemName: viewModel.cleanupAction == nil ? "largecircle.fill.circle" : "circle")
                                .foregroundColor(viewModel.cleanupAction == nil ? .accentColor : .secondary)
                            Text("Keep original files")
                        }
                    }
                    .buttonStyle(.plain)

                    // Move to Raw Files folder
                    Button {
                        viewModel.cleanupAction = .moveToRawFolder
                    } label: {
                        HStack {
                            Image(systemName: viewModel.cleanupAction == .moveToRawFolder ? "largecircle.fill.circle" : "circle")
                                .foregroundColor(viewModel.cleanupAction == .moveToRawFolder ? .accentColor : .secondary)
                            Text("Move to \"Raw Files\" folder")
                        }
                    }
                    .buttonStyle(.plain)

                    // Delete originals
                    Button {
                        viewModel.cleanupAction = .deleteOriginals
                    } label: {
                        HStack {
                            Image(systemName: viewModel.cleanupAction == .deleteOriginals ? "largecircle.fill.circle" : "circle")
                                .foregroundColor(viewModel.cleanupAction == .deleteOriginals ? .accentColor : .secondary)
                            Text("Delete originals (move to Trash)")
                        }
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Error message if cleanup failed
                if let errorMessage = errorMessage {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(Spacing.sm)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(4)
                }
            }
            .padding()
            .frame(maxHeight: .infinity)

            Divider()

            // Footer
            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isProcessing)

                Button("Confirm") {
                    Task {
                        await performCleanup()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isProcessing)
            }
            .padding()
        }
        .frame(width: 450, height: 300)
    }

    private func performCleanup() async {
        // If user chose to keep originals, just dismiss
        guard viewModel.cleanupAction != nil else {
            dismiss()
            return
        }

        isProcessing = true
        errorMessage = nil

        do {
            try await viewModel.executeCleanup()
            dismiss()
        } catch {
            errorMessage = "Cleanup failed: \(error.localizedDescription)"
            isProcessing = false
        }
    }
}

// MARK: - Cursor Helper

extension View {
    /// Sets the cursor shown while the pointer is over this view.
    func cursor(_ cursor: NSCursor) -> some View {
        onHover { isHovered in
            if isHovered {
                cursor.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
