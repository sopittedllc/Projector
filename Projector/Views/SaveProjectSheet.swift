//
//  SaveProjectSheet.swift
//  Projector
//
//  Custom sheet for saving projects with proper folder structure.
//  Creates the session folder:
//    <location>/<project-name>/
//      <project-name>.projector
//      Media/
//      Optimized Media/
//

import SwiftUI
import AppKit

/// Sheet for saving a project with a custom folder structure
struct SaveProjectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appSettings = AppSettings.shared

    /// The project name entered by the user
    @State private var projectName: String = ""

    /// The selected save location
    @State private var saveLocation: URL?

    /// Error message if any
    @State private var errorMessage: String?

    /// Show overwrite confirmation
    @State private var showOverwriteConfirmation: Bool = false
    @State private var pendingOverwriteURL: URL?

    /// Focus state for project name field
    @FocusState private var isProjectNameFocused: Bool

    /// Callback when save is confirmed
    let onSave: (URL) -> Void

    /// The source video's folder, when the project contains video.
    var initialDirectoryURL: URL? = nil

    /// Default save location (video folder, last used, or Documents folder)
    private var defaultLocation: URL {
        initialDirectoryURL
            ?? appSettings.lastProjectSaveLocation
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    /// Display name for the save location
    private var locationDisplayName: String {
        if let location = saveLocation {
            return location.lastPathComponent
        }
        return defaultLocation.lastPathComponent
    }

    /// The actual location to use
    private var effectiveLocation: URL {
        saveLocation ?? defaultLocation
    }

    /// Whether the save button should be enabled
    private var canSave: Bool {
        !projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Sanitized project name (removes invalid filename characters)
    private var sanitizedName: String {
        let name = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        // Remove characters that aren't allowed in filenames
        let invalidChars = CharacterSet(charactersIn: ":/\\?%*|\"<>")
        return name.components(separatedBy: invalidChars).joined()
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Save Project")
                    .font(.headline)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            // Content
            VStack(alignment: .leading, spacing: Spacing.lg) {
                // Project name field
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("Project Name")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    TextField("My Project", text: $projectName)
                        .textFieldStyle(.roundedBorder)
                        .focused($isProjectNameFocused)
                        .onSubmit {
                            if canSave {
                                save()
                            }
                        }
                }

                // Location picker
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("Location")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    HStack {
                        Image(systemName: "folder.fill")
                            .foregroundColor(.secondary)
                        Text(locationDisplayName)
                            .lineLimit(1)
                        Spacer()
                        Button("Choose...") {
                            chooseLocation()
                        }
                    }
                    .padding(Spacing.sm)
                    .background(Color.primary.opacity(0.05))
                    .cornerRadius(6)
                }

                // Preview of what will be created
                if canSave {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("Will create:")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            previewRow(icon: "folder", color: .blue, text: "\(sanitizedName)/")
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                previewRow(icon: "doc", color: .orange, text: "\(sanitizedName).projector")
                                previewRow(icon: "folder", color: .blue, text: "\(ProjectFolders.mediaFolderName)/")
                                previewRow(icon: "folder", color: .blue, text: "\(ProjectFolders.optimizedMediaFolderName)/")
                            }
                            .padding(.leading, Spacing.lg)
                        }
                        .foregroundColor(.secondary)
                    }
                }

                // Error message
                if let error = errorMessage {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
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
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding()
        }
        .frame(width: 400)
        .alert("Replace Existing Project?", isPresented: $showOverwriteConfirmation) {
            Button("Cancel", role: .cancel) {
                pendingOverwriteURL = nil
            }
            Button("Replace", role: .destructive) {
                if let url = pendingOverwriteURL {
                    let folderURL = url.deletingLastPathComponent()
                    performSave(projectFolderURL: folderURL, projectFileURL: url, overwrite: true)
                }
                pendingOverwriteURL = nil
            }
        } message: {
            Text("A project named \"\(sanitizedName)\" already exists. Replacing it will delete all files in the existing project folder.")
        }
    }

    /// One line of the "Will create:" tree.
    private func previewRow(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: icon)
                .foregroundColor(color)
            Text(text)
                .font(.system(.caption, design: .monospaced))
        }
    }

    private func chooseLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Choose Save Location"
        panel.prompt = "Select"
        panel.directoryURL = effectiveLocation

        if panel.runModal() == .OK, let url = panel.url {
            saveLocation = url
        }
    }

    private func save() {
        guard canSave else { return }

        errorMessage = nil

        // The app is not sandboxed, so this fails only where the user cannot write
        // either - a read-only volume or a locked folder. Say so before touching disk.
        guard FileManager.default.isWritableFile(atPath: effectiveLocation.path) else {
            errorMessage = "\"\(effectiveLocation.lastPathComponent)\" is read-only. Choose another location."
            return
        }

        let projectFolderURL = effectiveLocation.appendingPathComponent(sanitizedName)
        let projectFileURL = projectFolderURL.appendingPathComponent("\(sanitizedName).projector")

        // Check if folder already exists
        if FileManager.default.fileExists(atPath: projectFolderURL.path) {
            pendingOverwriteURL = projectFileURL
            showOverwriteConfirmation = true
            return
        }

        performSave(projectFolderURL: projectFolderURL, projectFileURL: projectFileURL, overwrite: false)
    }

    private func performSave(projectFolderURL: URL, projectFileURL: URL, overwrite: Bool) {
        do {
            if overwrite {
                // Remove existing folder before creating new one
                try FileManager.default.removeItem(at: projectFolderURL)
            }

            // Create the project folder
            try FileManager.default.createDirectory(at: projectFolderURL, withIntermediateDirectories: true)
            try ProjectFolders.createStandardFolders(forProjectAt: projectFileURL)

            // Remember the parent directory for next time
            appSettings.lastProjectSaveLocation = projectFolderURL.deletingLastPathComponent()

            // Call the save callback with the project file URL
            onSave(projectFileURL)
            dismiss()
        } catch {
            errorMessage = "Failed to create project folder: \(error.localizedDescription)"
        }
    }
}
