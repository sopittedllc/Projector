//
//  SaveProjectSheet.swift
//  Projector
//
//  Custom sheet for saving projects with proper folder structure.
//  Creates: <location>/<project-name>/<project-name>.projector
//

import SwiftUI
import AppKit

/// Sheet for saving a project with a custom folder structure
struct SaveProjectSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// The project name entered by the user
    @State private var projectName: String = ""

    /// The selected save location
    @State private var saveLocation: URL?

    /// Error message if any
    @State private var errorMessage: String?

    /// Callback when save is confirmed
    let onSave: (URL) -> Void

    /// Default save location (Documents folder)
    private var defaultLocation: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
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

                        HStack(spacing: Spacing.xs) {
                            Image(systemName: "folder")
                                .foregroundColor(.blue)
                            Text("\(sanitizedName)/")
                                .font(.system(.caption, design: .monospaced))
                            Image(systemName: "doc")
                                .foregroundColor(.orange)
                            Text("\(sanitizedName).projector")
                                .font(.system(.caption, design: .monospaced))
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
    }

    private func chooseLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Choose Save Location"
        panel.prompt = "Select"

        if panel.runModal() == .OK, let url = panel.url {
            saveLocation = url
        }
    }

    private func save() {
        guard canSave else { return }

        errorMessage = nil

        let projectFolderURL = effectiveLocation.appendingPathComponent(sanitizedName)
        let projectFileURL = projectFolderURL.appendingPathComponent("\(sanitizedName).projector")

        // Check if folder already exists
        if FileManager.default.fileExists(atPath: projectFolderURL.path) {
            errorMessage = "A folder named \"\(sanitizedName)\" already exists at this location"
            return
        }

        do {
            // Create the project folder
            try FileManager.default.createDirectory(at: projectFolderURL, withIntermediateDirectories: true)

            // Call the save callback with the project file URL
            onSave(projectFileURL)
            dismiss()
        } catch {
            errorMessage = "Failed to create project folder: \(error.localizedDescription)"
        }
    }
}
