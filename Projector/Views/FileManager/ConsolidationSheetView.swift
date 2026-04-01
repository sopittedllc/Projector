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
                    .padding(.vertical, 8)

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
                    .font(.system(size: 48))
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
                .font(.system(size: 48))
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
