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

    /// Called after the user locates a missing file and the reference has been
    /// updated, so the file can be copied into the project if it lives outside it.
    var onFileRelinked: (() -> Void)?

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
            if !Self.isReachable(item.url) {
                missing.append(MissingFileInfo(
                    id: item.id,
                    originalPath: item.url.path,
                    type: .mediaItem
                ))
            }
        }

        // Check video reels
        for reel in timelineManager.timeline.videoReels {
            if !Self.isReachable(reel.sourceURL) {
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
                if !Self.isReachable(clip.sourceURL) {
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

    /// Whether the app can actually open a referenced file, not merely see it.
    ///
    /// Existence alone is the wrong test under the sandbox. A file whose
    /// security-scoped bookmark failed to resolve (moved, or made by a build
    /// with a different code identity) still exists on disk, but the first read
    /// fails with "you don't have permission to view it". Treating it as missing
    /// routes it through the Locate flow, which re-picks the file and mints a
    /// bookmark this build can resolve.
    ///
    /// - Parameter url: The referenced media file.
    /// - Returns: `true` if the file exists and this process may read it.
    nonisolated static func isReachable(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: url.path)
            && fileManager.isReadableFile(atPath: url.path)
    }

    /// Present an open panel to locate the current missing file.
    ///
    /// If the user selects a file, updates the appropriate reference (media item,
    /// video reel, or audio clip) with the new URL. A file outside the project is
    /// then copied in through ``onFileRelinked`` - without asking.
    func locateMissingFile() {
        guard currentIndex < missingFiles.count else { return }
        let info = missingFiles[currentIndex]

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Locate Missing File"
        panel.message = "Please locate: \(URL(fileURLWithPath: info.originalPath).lastPathComponent)"

        if panel.runModal() == .OK, let newURL = panel.url {
            // The located file may be anywhere. It is used as-is for now and
            // `onFileRelinked` brings it into the project, with no prompt - every
            // file in a project is copied into it.
            // Update the reference
            switch info.type {
            case .mediaItem:
                mediaLibrary.updateItemURL(id: info.id, newURL: newURL)
            case .videoReel:
                timelineManager.updateVideoReelURL(id: info.id, newURL: newURL)
            case .audioClip(let laneId):
                timelineManager.updateAudioClipURL(clipId: info.id, inLane: laneId, newURL: newURL)
            }
            projectDocument.markDirty()
            onFileRelinked?()
        }

        // Move to next missing file
        advanceToNextMissingFile()
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
