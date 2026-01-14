import SwiftUI
import UniformTypeIdentifiers

// MARK: - File Handling
extension ContentView {
    // MARK: - Project Loading

    /// Load the video reels after project is opened (and missing files resolved)
    func loadProjectReels() {
        if let firstReel = timelineManager.timeline.sortedVideoReels.first {
            Task {
                do {
                    try await playbackEngine.loadReel(firstReel)

                    // Prime thumbnail cache for all reels
                    for reel in timelineManager.timeline.videoReels {
                        await generateThumbnail(for: reel)
                    }
                } catch {
                    loadError = error.localizedDescription
                    showErrorAlert = true
                }
            }
        }
    }

    // MARK: - Media Item Deletion

    /// Remove media items from the project and register undo.
    func handleDeleteMediaItems(_ items: [MediaItem]) {
        guard !items.isEmpty else { return }

        let previousTimeline = timelineManager.timeline
        let previousItems = mediaLibrary.exportItems()
        let reelsToPrewarm = previousTimeline.videoReels

        undoManager?.registerUndo(withTarget: timelineManager) { _ in
            timelineManager.timeline = previousTimeline
            mediaLibrary.load(items: previousItems)
            syncTimelineToPlaybackEngine()
            for reel in reelsToPrewarm {
                thumbnailCache.prewarm(for: reel)
            }
        }
        undoManager?.setActionName(items.count == 1 ? "Remove Media Item" : "Remove Media Items")

        for item in items {
            removeMediaItem(item)
        }
    }

    /// Remove a media item from the project and clean up timeline references.
    private func removeMediaItem(_ item: MediaItem) {
        // Remove any video reels that reference this item.
        let reelsToRemove = timelineManager.timeline.videoReels.filter { $0.sourceURL == item.url }
        for reel in reelsToRemove {
            timelineManager.removeVideoReel(id: reel.id)
            thumbnailCache.remove(reelId: reel.id)
        }

        // Remove any audio clips that reference this item.
        for lane in timelineManager.timeline.audioLanes {
            let clipsToRemove = lane.clips.filter { $0.sourceURL == item.url }
            for clip in clipsToRemove {
                waveformCache.cancelGeneration(for: clip.id)
                waveformCache.removeCachedWaveform(for: clip.id)
                timelineManager.removeAudioClip(clipId: clip.id, fromLane: lane.id)
            }
        }

        mediaLibrary.removeItem(id: item.id)
    }

    // MARK: - Open Media Panel

    /// Called from menu File > Open Media
    func openMediaFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            .movie,
            .mpeg4Movie,
            .quickTimeMovie,
            .audio,
            .mp3,
            .wav,
            UTType(filenameExtension: "mov")!,
            UTType(filenameExtension: "mp4")!,
            UTType(filenameExtension: "m4v")!,
            UTType(filenameExtension: "aif")!,
            UTType(filenameExtension: "aiff")!
        ]

        panel.begin { response in
            if response == .OK {
                Task { @MainActor in
                    let urls = panel.urls.filter { ProjectMediaLibrary.isSupported(url: $0) }
                    let (newURLs, duplicateNames) = self.mediaImportCoordinator.partitionDuplicateMediaURLs(urls)

                    if !duplicateNames.isEmpty {
                        self.mediaImportCoordinator.duplicateMediaNames = duplicateNames
                        self.mediaImportCoordinator.showDuplicateMediaAlert = true
                    }

                    for url in newURLs {
                        if let mediaType = ProjectMediaLibrary.mediaType(for: url) {
                            switch mediaType {
                            case .video:
                                await self.addVideoToTimeline(url: url, atFrame: nil)
                            case .audio:
                                // Create a new lane for each audio file
                                let laneNumber = self.timelineManager.timeline.audioLanes.count + 1
                                let newLane = self.timelineManager.addAudioLane(name: "Audio \(laneNumber)")
                                _ = await self.addAudioToTimeline(url: url, laneId: newLane.id, atFrame: nil)
                            }
                        }
                    }
                    // Auto-expand timeline
                    self.timelineViewModel.expandIfNeeded()
                }
            }
        }
    }

    // MARK: - Media Import Coordinator Setup

    /// Wire up callbacks for the media import coordinator
    func setupMediaImportCoordinatorCallbacks() {
        mediaImportCoordinator.onImportVideo = { [self] url, atFrame in
            await addVideoToTimeline(url: url, atFrame: atFrame)
        }

        // Batch video import with timecode detection
        mediaImportCoordinator.onImportVideos = { [self] urls, atFrame in
            handleVideoDropOnTimeline(urls, atFrame, false)
        }

        mediaImportCoordinator.onImportAudio = { [self] url, laneId, atFrame in
            await addAudioToTimeline(url: url, laneId: laneId, atFrame: atFrame)
        }

        // Batch audio import with timecode detection
        mediaImportCoordinator.onImportAudios = { [self] urls, laneId, atFrame in
            // Get the lane index from the lane ID
            let laneIndex = timelineManager.timeline.audioLanes.firstIndex { $0.id == laneId } ?? 0
            handleAudioDropOnTimeline(laneIndex, urls, atFrame, false)
        }

        mediaImportCoordinator.onCreateAudioLane = { [self] in
            let laneNumber = timelineManager.timeline.audioLanes.count + 1
            return timelineManager.addAudioLane(name: "Audio \(laneNumber)")
        }

        mediaImportCoordinator.onExpandTimeline = { [self] in
            timelineViewModel.expandIfNeeded()
        }
    }
}
