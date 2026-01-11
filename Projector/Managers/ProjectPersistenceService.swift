//
//  ProjectPersistenceService.swift
//  Projector
//
//  Service responsible for project save/load/consolidate operations.
//  Extracted from ContentView to maintain separation of concerns.
//

import Foundation
import AppKit

/// Service for handling project file persistence operations.
///
/// This service manages saving, loading, and consolidating project files.
/// It coordinates between the project document, media library, and timeline manager.
///
/// ## Callbacks
///
/// The service uses callbacks to communicate with the view layer:
/// - `onNeedsMissingFileCheck`: Called to check for missing files after loading
/// - `onLoadProjectReels`: Called to load video reels after project is opened
/// - `onError`: Called when an error occurs during save/load operations
///
/// - Note: This service requires `@MainActor` because it interacts with
///   UI-bound managers like `ProjectDocument` and `TimelineManager`.
@MainActor
final class ProjectPersistenceService: ObservableObject {

    // MARK: - Dependencies

    /// The project document containing the serialized project state
    private let projectDocument: ProjectDocument

    /// The media library containing imported media files
    private let mediaLibrary: ProjectMediaLibrary

    /// The timeline manager containing timeline state
    private let timelineManager: TimelineManager

    /// The playback engine for syncing timeline changes
    private let playbackEngine: PlaybackEngine

    // MARK: - Callbacks

    /// Callback to check for missing files after loading a project.
    /// Returns true if missing files were found (and will be handled by caller).
    var onNeedsMissingFileCheck: (() -> Bool)?

    /// Callback to load project reels after project is opened and missing files are resolved.
    var onLoadProjectReels: (() -> Void)?

    /// Callback when an error occurs.
    var onError: ((String) -> Void)?

    // MARK: - Initialization

    /// Creates a new project persistence service.
    ///
    /// - Parameters:
    ///   - projectDocument: The project document to save/load.
    ///   - mediaLibrary: The media library for media file management.
    ///   - timelineManager: The timeline manager for timeline state.
    ///   - playbackEngine: The playback engine for syncing changes.
    init(
        projectDocument: ProjectDocument,
        mediaLibrary: ProjectMediaLibrary,
        timelineManager: TimelineManager,
        playbackEngine: PlaybackEngine
    ) {
        self.projectDocument = projectDocument
        self.mediaLibrary = mediaLibrary
        self.timelineManager = timelineManager
        self.playbackEngine = playbackEngine
    }

    // MARK: - Save Operations

    /// Saves the project to its current file URL, or shows Save As if never saved.
    ///
    /// If the project has a file URL, saves directly. Otherwise, triggers
    /// the Save As flow by returning false.
    ///
    /// - Returns: `true` if save succeeded or was not needed, `false` if Save As is required.
    @discardableResult
    func saveProject() -> Bool {
        if projectDocument.fileURL != nil {
            do {
                try projectDocument.save()
                return true
            } catch {
                onError?(error.localizedDescription)
                return false
            }
        } else {
            // No file URL - caller should show Save As
            return false
        }
    }

    /// Handles saving the project to a specific URL.
    ///
    /// This is called from the Save Project Sheet when the user confirms a save location.
    ///
    /// - Parameter url: The URL to save the project to.
    func handleProjectSave(to url: URL) {
        do {
            try projectDocument.save(to: url)
        } catch {
            onError?(error.localizedDescription)
        }
    }

    // MARK: - Open Operations

    /// Shows the standard macOS Open panel for opening a project.
    ///
    /// Presents an NSOpenPanel configured for .projector files.
    /// If the user selects a file, opens it via `openProject(from:)`.
    func showOpenProjectPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.projectorProject]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Open Project"

        if panel.runModal() == .OK, let url = panel.url {
            openProject(from: url)
        }
    }

    /// Opens a project from the specified URL.
    ///
    /// Loads the project document, restores timeline and media library,
    /// syncs to the playback engine, and checks for missing files.
    ///
    /// - Parameter url: The URL of the .projector package to open.
    func openProject(from url: URL) {
        do {
            try projectDocument.load(from: url)

            // Restore timeline and media library
            timelineManager.timeline = projectDocument.timeline
            mediaLibrary.load(items: projectDocument.mediaLibrary)

            // Sync to playback engine
            syncTimelineToPlaybackEngine()

            // Check for missing files - if any are found, don't load reels yet
            // (the callback handlers will call loadProjectReels when done)
            let hasMissingFiles = onNeedsMissingFileCheck?() ?? false
            if !hasMissingFiles {
                // No missing files, load reels immediately
                onLoadProjectReels?()
            }

            debugPrint("openProject: loaded timeline with \(projectDocument.timeline.videoReels.count) reels")
        } catch {
            onError?(error.localizedDescription)
        }
    }

    // MARK: - Consolidate Operations

    /// Consolidates all external media files into the project folder.
    ///
    /// This copies any media files that are stored outside the project package
    /// into the project's Media folder, making the project portable.
    ///
    /// Shows appropriate alerts for:
    /// - Project not saved (must save first)
    /// - No external media (nothing to consolidate)
    /// - Confirmation before consolidating
    /// - Results after consolidation
    func consolidateMedia() {
        guard let projectURL = projectDocument.fileURL else {
            // Project must be saved first
            let alert = NSAlert()
            alert.messageText = "Save Project First"
            alert.informativeText = "Please save your project before consolidating media. This allows media files to be copied into the project folder."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        // Check if there are external files to consolidate
        let externalItems = mediaLibrary.externalMediaItems(projectURL: projectURL)
        if externalItems.isEmpty {
            let alert = NSAlert()
            alert.messageText = "No External Media"
            alert.informativeText = "All media files are already stored within the project folder."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        // Confirm consolidation
        let alert = NSAlert()
        alert.messageText = "Consolidate Media"
        alert.informativeText = "This will copy \(externalItems.count) external media file(s) into the project folder. The original files will not be modified."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Consolidate")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Perform consolidation
        Task {
            let result = await mediaLibrary.consolidateMedia(projectURL: projectURL)

            // Show result
            let resultAlert = NSAlert()
            if result.failedCount == 0 {
                resultAlert.messageText = "Consolidation Complete"
                resultAlert.informativeText = "Copied \(result.copiedCount) file(s) to project folder.\n\(result.skippedCount) file(s) were already local."
                resultAlert.alertStyle = .informational
            } else {
                resultAlert.messageText = "Consolidation Completed with Errors"
                resultAlert.informativeText = "Copied \(result.copiedCount) file(s).\nFailed: \(result.failedCount)\n\nErrors:\n\(result.errors.joined(separator: "\n"))"
                resultAlert.alertStyle = .warning
            }
            resultAlert.addButton(withTitle: "OK")
            resultAlert.runModal()

            // Save project to persist the updated paths
            if result.copiedCount > 0 {
                syncMediaLibraryToDocument()
                _ = saveProject()
            }
        }
    }

    // MARK: - Private Helpers

    /// Syncs the timeline manager's timeline to the playback engine.
    private func syncTimelineToPlaybackEngine() {
        playbackEngine.timeline = timelineManager.timeline
    }

    /// Syncs the media library to the project document.
    private func syncMediaLibraryToDocument() {
        projectDocument.mediaLibrary = mediaLibrary.exportItems()
    }
}
