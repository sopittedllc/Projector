//
//  MissingFileResolutionService.swift
//  Projector
//
//  Service for handling missing file resolution during project loading.
//  Presents alerts for missing files and allows users to locate, skip, or skip all.
//

import Foundation
import AppKit

/// Info about a missing file that needs to be located
struct MissingFileInfo: Identifiable {
    let id: UUID
    let originalPath: String
    let type: MissingFileType

    enum MissingFileType {
        case mediaItem
        case videoReel
        case audioClip(laneId: UUID)
    }
}

/// Service for resolving missing files when loading a project.
///
/// This service checks for missing media files after a project is loaded and
/// presents alerts allowing the user to locate, skip, or skip all missing files.
///
/// - Note: Thread-safe, all state mutations occur on MainActor.
@MainActor
final class MissingFileResolutionService: ObservableObject {

    // MARK: - Dependencies

    private let mediaLibrary: ProjectMediaLibrary
    private let timelineManager: TimelineManager
    private let projectDocument: ProjectDocument

    // MARK: - Published State

    /// Whether the missing file alert should be shown
    @Published var showAlert: Bool = false

    /// Array of missing files to resolve
    @Published var missingFiles: [MissingFileInfo] = []

    /// Current index in the missing files array
    @Published var currentIndex: Int = 0

    // MARK: - Callbacks

    /// Called when all missing files have been resolved (or skipped)
    var onResolutionComplete: (() -> Void)?

    // MARK: - Computed Properties

    /// Message to display in the missing file alert
    var currentMissingFileMessage: String {
        guard currentIndex < missingFiles.count else { return "" }
        let file = missingFiles[currentIndex]
        return "Cannot find file:\n\(file.originalPath)\n\nWould you like to locate it?"
    }

    // MARK: - Initialization

    /// Creates a new missing file resolution service.
    ///
    /// - Parameters:
    ///   - mediaLibrary: The project media library to update when files are located
    ///   - timelineManager: The timeline manager to update when files are located
    ///   - projectDocument: The project document to mark dirty when changes are made
    init(
        mediaLibrary: ProjectMediaLibrary,
        timelineManager: TimelineManager,
        projectDocument: ProjectDocument
    ) {
        self.mediaLibrary = mediaLibrary
        self.timelineManager = timelineManager
        self.projectDocument = projectDocument
    }

    // MARK: - Missing File Handling

    /// Check for missing files and show alert if any are found.
    ///
    /// This method checks all media library items, video reels, and audio clips
    /// for missing source files. If any are found, it populates the `missingFiles`
    /// array and sets `showAlert` to true.
    ///
    /// - Returns: `true` if missing files were found (and alert will be shown)
    @discardableResult
    func checkForMissingFiles() -> Bool {
        var missing: [MissingFileInfo] = []

        // Check media library items
        for item in mediaLibrary.items {
            if !FileManager.default.fileExists(atPath: item.url.path) {
                missing.append(MissingFileInfo(
                    id: item.id,
                    originalPath: item.url.path,
                    type: .mediaItem
                ))
            }
        }

        // Check video reels
        for reel in timelineManager.timeline.videoReels {
            if !FileManager.default.fileExists(atPath: reel.sourceURL.path) {
                missing.append(MissingFileInfo(
                    id: reel.id,
                    originalPath: reel.sourceURL.path,
                    type: .videoReel
                ))
            }
        }

        // Check audio clips
        for lane in timelineManager.timeline.audioLanes {
            for clip in lane.clips {
                if !FileManager.default.fileExists(atPath: clip.sourceURL.path) {
                    missing.append(MissingFileInfo(
                        id: clip.id,
                        originalPath: clip.sourceURL.path,
                        type: .audioClip(laneId: lane.id)
                    ))
                }
            }
        }

        if !missing.isEmpty {
            missingFiles = missing
            currentIndex = 0
            showAlert = true
            return true
        }
        return false
    }

    /// Present an open panel to locate the current missing file.
    ///
    /// If the user selects a file, it offers to copy the file to the project folder
    /// if it's external. Then updates the appropriate reference (media item, video reel,
    /// or audio clip) with the new URL.
    func locateMissingFile() {
        guard currentIndex < missingFiles.count else { return }
        let info = missingFiles[currentIndex]

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Locate Missing File"
        panel.message = "Please locate: \(URL(fileURLWithPath: info.originalPath).lastPathComponent)"

        if panel.runModal() == .OK, let newURL = panel.url {
            // Check if we should offer to copy to project folder
            var finalURL = newURL
            // Use canonical paths to prevent path traversal attacks
            if let projectURL = projectDocument.fileURL {
                let projectCanonical = projectURL.resolvingSymlinksInPath()
                let fileCanonical = newURL.resolvingSymlinksInPath()
                if !fileCanonical.path.hasPrefix(projectCanonical.path) {
                    // File is external - offer to consolidate
                    let consolidateAlert = NSAlert()
                    consolidateAlert.messageText = "Copy to Project Folder?"
                    consolidateAlert.informativeText = "Would you like to copy this file into the project folder? This ensures the project remains portable."
                    consolidateAlert.addButton(withTitle: "Copy to Project")
                    consolidateAlert.addButton(withTitle: "Keep External Reference")

                    if consolidateAlert.runModal() == .alertFirstButtonReturn {
                        // Copy the file to project Media folder
                        if let copiedURL = copyFileToProject(sourceURL: newURL, projectURL: projectURL) {
                            finalURL = copiedURL
                        }
                    }
                }
            }

            // Update the reference
            switch info.type {
            case .mediaItem:
                mediaLibrary.updateItemURL(id: info.id, newURL: finalURL)
            case .videoReel:
                timelineManager.updateVideoReelURL(id: info.id, newURL: finalURL)
            case .audioClip(let laneId):
                timelineManager.updateAudioClipURL(clipId: info.id, inLane: laneId, newURL: finalURL)
            }
            projectDocument.markDirty()
        }

        // Move to next missing file
        advanceToNextMissingFile()
    }

    /// Copy a file to the project's Media folder.
    ///
    /// - Parameters:
    ///   - sourceURL: The source file URL to copy
    ///   - projectURL: The project folder URL
    /// - Returns: The destination URL if successful, nil otherwise
    func copyFileToProject(sourceURL: URL, projectURL: URL) -> URL? {
        let mediaFolder = projectURL.appendingPathComponent("Media")
        let fileManager = FileManager.default

        // Create Media folder if needed
        if !fileManager.fileExists(atPath: mediaFolder.path) {
            do {
                try fileManager.createDirectory(at: mediaFolder, withIntermediateDirectories: true)
            } catch {
                debugPrint("Failed to create Media folder: \(error)")
                return nil
            }
        }

        // Determine destination (handle duplicates)
        let originalName = sourceURL.lastPathComponent
        var destinationURL = mediaFolder.appendingPathComponent(originalName)
        var counter = 1

        while fileManager.fileExists(atPath: destinationURL.path) {
            let nameWithoutExt = sourceURL.deletingPathExtension().lastPathComponent
            let ext = sourceURL.pathExtension
            destinationURL = mediaFolder.appendingPathComponent("\(nameWithoutExt)_\(counter).\(ext)")
            counter += 1
        }

        do {
            // Start security-scoped access
            let didStartAccess = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if didStartAccess {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            debugPrint("Copied missing file to project: \(destinationURL.lastPathComponent)")
            return destinationURL
        } catch {
            debugPrint("Failed to copy file to project: \(error)")
            return nil
        }
    }

    /// Skip the current missing file by removing it from the project.
    ///
    /// Removes the missing item (media item, video reel, or audio clip) and
    /// advances to the next missing file.
    func skipMissingFile() {
        guard currentIndex < missingFiles.count else { return }
        let info = missingFiles[currentIndex]

        // Remove the missing item
        switch info.type {
        case .mediaItem:
            mediaLibrary.removeItem(id: info.id)
        case .videoReel:
            timelineManager.removeVideoReel(id: info.id)
        case .audioClip(let laneId):
            timelineManager.removeAudioClip(clipId: info.id, fromLane: laneId)
        }
        projectDocument.markDirty()

        // Move to next missing file
        advanceToNextMissingFile()
    }

    /// Skip all remaining missing files by removing them from the project.
    ///
    /// Removes all missing items from the current index onwards and
    /// calls the resolution complete callback.
    func skipAllMissingFiles() {
        // Remove all remaining missing items
        for i in currentIndex..<missingFiles.count {
            let info = missingFiles[i]
            switch info.type {
            case .mediaItem:
                mediaLibrary.removeItem(id: info.id)
            case .videoReel:
                timelineManager.removeVideoReel(id: info.id)
            case .audioClip(let laneId):
                timelineManager.removeAudioClip(clipId: info.id, fromLane: laneId)
            }
        }
        projectDocument.markDirty()
        missingFiles = []

        // All missing files handled
        onResolutionComplete?()
    }

    // MARK: - Private Helpers

    /// Advance to the next missing file or complete resolution.
    private func advanceToNextMissingFile() {
        currentIndex += 1
        if currentIndex < missingFiles.count {
            showAlert = true
        } else {
            // All missing files handled
            missingFiles = []
            onResolutionComplete?()
        }
    }
}
