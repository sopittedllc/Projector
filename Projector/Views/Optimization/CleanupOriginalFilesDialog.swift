//
//  CleanupOriginalFilesDialog.swift
//  Projector
//
//  Dialog for managing original files after optimization.
//  Offers options to keep, move to Raw Files folder, or trash originals.
//

import SwiftUI

/// Dialog for cleaning up original files after optimization completes
struct CleanupOriginalFilesDialog: View {
    @ObservedObject var viewModel: OptimizationViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedOption: CleanupOption = .keep
    @State private var isProcessing = false
    @State private var errorMessage: String?
    @State private var showTrashConfirmation = false

    /// Cleanup options for the user
    enum CleanupOption: String, CaseIterable {
        case keep = "Keep originals where they are"
        case moveToRawFiles = "Move originals to \"Raw Files\" folder"
        case moveToTrash = "Move originals to Trash"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Manage Original Files")
                    .font(.headline)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(isProcessing)
            }
            .padding()

            Divider()

            // Content
            VStack(alignment: .leading, spacing: Spacing.lg) {
                // Explanation text
                Text("Your original files are no longer needed for playback. What would you like to do with them?")
                    .font(Typography.body)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Size info
                if let result = viewModel.result {
                    HStack {
                        Image(systemName: "doc.on.doc.fill")
                            .foregroundColor(.accentColor)
                        Text("\(result.successfulItems.count) files")
                        Text("•")
                            .foregroundColor(.secondary)
                        Text(ByteCountFormatter.string(
                            fromByteCount: Int64(totalOriginalSize),
                            countStyle: .file
                        ))
                        .foregroundColor(.secondary)
                    }
                    .font(Typography.body)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppColors.surfaceSubtle)
                    .cornerRadius(8)
                }

                // Options
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    ForEach(CleanupOption.allCases, id: \.self) { option in
                        CleanupOptionRow(
                            option: option,
                            isSelected: selectedOption == option,
                            rawFilesFolderName: rawFilesFolderName
                        ) {
                            selectedOption = option
                        }
                    }
                }

                // Error message
                if let error = errorMessage {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.yellow)
                        Text(error)
                            .font(Typography.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color.yellow.opacity(0.1))
                    .cornerRadius(8)
                }
            }
            .padding()

            Divider()

            // Footer
            HStack {
                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(isProcessing)

                Button(action: performCleanup) {
                    if isProcessing {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.horizontal, Spacing.sm)
                    } else {
                        Text(buttonTitle)
                    }
                }
                .keyboardShortcut(.return, modifiers: [])
                .buttonStyle(.borderedProminent)
                .disabled(isProcessing)
            }
            .padding()
        }
        .frame(width: 450)
        .alert("Move Original Files to Trash?", isPresented: $showTrashConfirmation) {
            Button("Move to Trash", role: .destructive) {
                executeCleanup()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            if let result = viewModel.result {
                Text("This will move \(result.successfulItems.count) files to Trash. Optimized files will remain in your project.")
            }
        }
    }

    // MARK: - Computed Properties

    private var totalOriginalSize: UInt64 {
        viewModel.result?.successfulItems.reduce(0) { $0 + $1.originalSize } ?? 0
    }

    private var rawFilesFolderName: String {
        viewModel.rawFilesFolderURL?.lastPathComponent ?? "Raw Files"
    }

    private var buttonTitle: String {
        switch selectedOption {
        case .keep:
            return "Done"
        case .moveToRawFiles:
            return "Move to Raw Files"
        case .moveToTrash:
            return "Move to Trash"
        }
    }

    // MARK: - Actions

    private func performCleanup() {
        guard !isProcessing else { return }

        // If keeping, just dismiss
        if selectedOption == .keep {
            dismiss()
            return
        }

        // If trash selected, show confirmation alert first
        if selectedOption == .moveToTrash {
            showTrashConfirmation = true
            return
        }

        // For other options (moveToRawFiles), execute directly
        executeCleanup()
    }

    private func executeCleanup() {
        isProcessing = true
        errorMessage = nil

        // Map our option to ViewModel's action
        viewModel.cleanupAction = selectedOption == .moveToRawFiles
            ? .moveToRawFolder
            : .deleteOriginals

        Task {
            do {
                try await viewModel.executeCleanup()
                await MainActor.run {
                    isProcessing = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isProcessing = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Option Row

/// A single cleanup option row
private struct CleanupOptionRow: View {
    let option: CleanupOriginalFilesDialog.CleanupOption
    let isSelected: Bool
    let rawFilesFolderName: String
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: Spacing.md) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(optionTitle)
                        .font(Typography.body)
                        .foregroundColor(.primary)

                    Text(optionDescription)
                        .font(Typography.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding(Spacing.sm)
            .background(isSelected ? AppColors.surfaceLight : Color.clear)
            .cornerRadius(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var optionTitle: String {
        switch option {
        case .keep:
            return "Keep originals"
        case .moveToRawFiles:
            return "Move to \(rawFilesFolderName)"
        case .moveToTrash:
            return "Move to Trash"
        }
    }

    private var optionDescription: String {
        switch option {
        case .keep:
            return "Original files remain in their current location"
        case .moveToRawFiles:
            return "Organize originals in a folder next to your project"
        case .moveToTrash:
            return "Free up disk space by removing original files"
        }
    }
}

// MARK: - Preview

#Preview {
    CleanupOriginalFilesDialog(viewModel: OptimizationViewModel(
        mediaLibrary: ProjectMediaLibrary(),
        projectURL: URL(fileURLWithPath: "/tmp/test.projector")
    ))
}
