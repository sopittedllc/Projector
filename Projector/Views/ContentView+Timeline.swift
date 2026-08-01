import SwiftUI
import AVFoundation
import SwiftTimecodeCore

// MARK: - Timeline Operations
extension ContentView {
    // MARK: - Drop Handlers

    /// Handle video files dropped on the timeline video track
    func handleVideoDropOnTimeline(_ urls: [URL], _ atFrame: Int, _ isInternalDrag: Bool) {
        debugPrint("handleVideoDropOnTimeline: ENTRY with \(urls.count) URLs: \(urls.map { $0.lastPathComponent })")

        // One import at a time: a second drop landing mid-import would place
        // against a timeline the first has not finished changing.
        guard !isProcessingTimecodeDetection else {
            debugPrint("handleVideoDropOnTimeline: BLOCKED - an import is already running")
            return
        }

        // Set flag synchronously before starting async work
        isProcessingTimecodeDetection = true

        Task { @MainActor in
            defer { isProcessingTimecodeDetection = false }

            // Filter out duplicates first
            let newURLs = urls.filter { url in
                if timelineManager.timeline.videoReels.contains(where: { $0.sourceURL == url }) {
                    let name = url.deletingPathExtension().lastPathComponent
                    alerts.show(.videoAlreadyInTimeline(name))
                    return false
                }
                return true
            }

            guard !newURLs.isEmpty else {
                debugPrint("handleVideoDropOnTimeline: No new URLs after filtering, returning")
                return
            }

            debugPrint("handleVideoDropOnTimeline: After filtering, \(newURLs.count) new URLs")

            // For single file, use existing single-file flow
            if newURLs.count == 1 {
                debugPrint("handleVideoDropOnTimeline: SINGLE FILE PATH - calling addVideoToTimeline")
                await addVideoToTimeline(url: newURLs[0], atFrame: atFrame)
                return
            }

            // Files carrying timecode go to it; the rest are laid end to end
            // from the drop. `addVideoToTimeline` resolves each file's own
            // timecode, so this only needs to handle the ones without.
            debugPrint("handleVideoDropOnTimeline: BATCH PATH - \(newURLs.count) files")
            await addVideoFilesSequentially(urls: newURLs, startFrame: atFrame)
        }
    }

    /// Handle audio files dropped on a specific audio lane
    func handleAudioDropOnTimeline(_ laneIndex: Int, _ urls: [URL], _ atFrame: Int, _ isInternalDrag: Bool) {
        debugPrint("handleAudioDropOnTimeline: ENTRY - laneIndex=\(laneIndex), urls=\(urls.map { $0.lastPathComponent }), atFrame=\(atFrame)")

        // Defer state changes to avoid "Publishing changes from within view updates"
        DispatchQueue.main.async {
            Task { @MainActor in
                // Ensure the lane exists - create lanes until we have enough
                while self.timelineManager.timeline.audioLanes.count <= laneIndex {
                    debugPrint("handleAudioDropOnTimeline: Creating lane - current count: \(self.timelineManager.timeline.audioLanes.count), need index: \(laneIndex)")
                    // Registered so the drop's cleanup knows which lanes it made.
                    let created = self.timelineManager.addAudioLane()
                    self.batchCreatedLaneIds.insert(created.id)
                }

                // Verify lane was created
                guard laneIndex < self.timelineManager.timeline.audioLanes.count else {
                    debugPrint("handleAudioDropOnTimeline: ERROR - lane index \(laneIndex) still out of bounds after creation")
                    return
                }

                let lane = self.timelineManager.timeline.audioLanes[laneIndex]
                debugPrint("handleAudioDropOnTimeline: using lane '\(lane.name)' with id=\(lane.id.uuidString)")

                // For single file, use existing single-file flow
                if urls.count == 1 {
                    let clip = await self.addAudioToTimeline(url: urls[0], laneId: lane.id, atFrame: atFrame)
                    if let clip = clip {
                        let paddingFrames = Int(TimelineLayout.defaultPaddingMinutes * 60.0 * self.timelineManager.timeline.config.frameRate.fps)
                        self.timelineManager.extendTimeline(toEndFrame: clip.timelineEndFrame + paddingFrames)
                    }
                    return
                }

                // Each file goes to its own timecode, or after the last one.
                let items = await self.detectTimecodeForBatch(urls: urls, mediaType: .audio)
                await self.addAudioFilesAtEmbeddedTimecode(items: items, laneId: lane.id, fallbackFrame: atFrame)

                // Cleared, not discarded. The lanes this path creates are the
                // ones between the last existing lane and the one dropped on -
                // the user aimed at that row, so an empty lane above it is
                // wanted. Clearing stops a later drop's cleanup from adopting
                // them as its own and removing them.
                self.batchCreatedLaneIds.removeAll()

                // Final verification
                debugPrint("handleAudioDropOnTimeline: FINAL STATE - \(self.timelineManager.timeline.audioLanes.count) lanes total")
                for (idx, verifyLane) in self.timelineManager.timeline.audioLanes.enumerated() {
                    debugPrint("handleAudioDropOnTimeline: FINAL - lane[\(idx)] '\(verifyLane.name)' has \(verifyLane.clips.count) clips")
                }
                debugPrint("handleAudioDropOnTimeline: DONE")
            }
        }
    }

    // MARK: - Playback Area Drop Handler

    /// Handle files dropped on the playback area (video player)
    ///
    /// This accepts both internal drags from the media panel and external files.
    /// Files are processed through the unified batch handler at frame 0.
    ///
    /// - Parameter urls: Array of file URLs to import
    func handlePlaybackAreaDrop(urls: [URL]) {
        // Separate video and audio URLs
        var videoURLs: [URL] = []
        var audioURLs: [URL] = []

        for url in urls {
            guard let mediaType = ProjectMediaLibrary.mediaType(for: url) else { continue }
            switch mediaType {
            case .video:
                videoURLs.append(url)
            case .audio:
                audioURLs.append(url)
            }
        }

        // Use the unified batch handler at frame 0
        handleMixedBatchDrop(videoURLs: videoURLs, audioURLs: audioURLs, atFrame: 0)
    }

    // MARK: - Unified Batch Drop Handler

    /// Handle mixed video and audio files dropped together
    ///
    /// Creates a unified batch sheet showing all files with their detected timecodes.
    /// Each audio file gets its own lane.
    ///
    /// - Parameters:
    ///   - videoURLs: Array of video file URLs
    ///   - audioURLs: Array of audio file URLs
    ///   - atFrame: Target frame position for files not using embedded timecode
    func handleMixedBatchDrop(videoURLs: [URL], audioURLs: [URL], atFrame: Int) {
        debugPrint("handleMixedBatchDrop: ENTRY - \(videoURLs.count) video \(videoURLs.map { $0.lastPathComponent }), \(audioURLs.count) audio \(audioURLs.map { $0.lastPathComponent }), atFrame=\(atFrame)")
        // One import at a time: a second drop landing mid-import would place
        // against a timeline the first has not finished changing.
        guard !isProcessingTimecodeDetection else {
            debugPrint("handleMixedBatchDrop: BLOCKED - an import is already running")
            return
        }

        // Set flag synchronously before starting async work
        isProcessingTimecodeDetection = true

        Task { @MainActor in
            defer { isProcessingTimecodeDetection = false }

            // Filter out duplicate videos
            let newVideoURLs = videoURLs.filter { url in
                if timelineManager.timeline.videoReels.contains(where: { $0.sourceURL == url }) {
                    let name = url.deletingPathExtension().lastPathComponent
                    alerts.show(.videoAlreadyInTimeline(name))
                    return false
                }
                return true
            }

            // Filter out duplicate audio (audio already in any lane)
            let newAudioURLs = audioURLs.filter { url in
                !timelineManager.timeline.audioLanes.contains { lane in
                    lane.clips.contains { $0.sourceURL == url }
                }
            }

            debugPrint("handleMixedBatchDrop: after dedupe - \(newVideoURLs.count) video, \(newAudioURLs.count) audio \(newAudioURLs.map { $0.lastPathComponent })")

            guard !newVideoURLs.isEmpty || !newAudioURLs.isEmpty else {
                debugPrint("handleMixedBatchDrop: nothing new after dedupe, returning")
                return
            }

            // For single video + no audio, use existing single-file flow
            if newVideoURLs.count == 1 && newAudioURLs.isEmpty {
                await addVideoToTimeline(url: newVideoURLs[0], atFrame: atFrame)
                return
            }

            // For single audio + no video, use existing single-file flow with new lane
            if newAudioURLs.count == 1 && newVideoURLs.isEmpty {
                let newLane = timelineManager.addAudioLane(name: laneName(for: newAudioURLs[0]))
                batchCreatedLaneIds.insert(newLane.id)
                let clip = await addAudioToTimeline(url: newAudioURLs[0], laneId: newLane.id, atFrame: atFrame)
                if let clip = clip {
                    let paddingFrames = Int(TimelineLayout.defaultPaddingMinutes * 60.0 * timelineManager.timeline.config.frameRate.fps)
                    timelineManager.extendTimeline(toEndFrame: clip.timelineEndFrame + paddingFrames)
                }
                return
            }

            // For multiple files, detect timecode for all files in parallel

            // Detect timecode for video files
            var allItems: [BatchTimecodeItem] = []
            if !newVideoURLs.isEmpty {
                let videoItems = await detectTimecodeForBatch(urls: newVideoURLs, mediaType: .video)
                allItems.append(contentsOf: videoItems)
            }

            // IMPORTANT: Reserve lanes for video embedded audio FIRST
            // Each video may have an audio track that needs its own lane
            // We create placeholder lanes now so standalone audio files get assigned to subsequent lanes
            for url in newVideoURLs {
                let lane = timelineManager.addAudioLane(name: laneName(for: url))
                batchCreatedLaneIds.insert(lane.id)
            }

            // Detect timecode for audio files and create a lane for each
            // These lanes come AFTER the video audio lanes
            for url in newAudioURLs {
                let result = await embeddedTimecodeService.detectTimecode(from: url, bookmark: nil)
                let newLane = timelineManager.addAudioLane(name: laneName(for: url))
                batchCreatedLaneIds.insert(newLane.id)
                var item = BatchTimecodeItem(url: url, mediaType: .audio, detectedTimecode: result)
                item.targetLaneId = newLane.id
                allItems.append(item)
                reservedAudioLaneIds.insert(newLane.id)
                batchCreatedLaneIds.insert(newLane.id)
                debugPrint("handleMixedBatchDrop: assigned '\(url.lastPathComponent)' -> lane '\(newLane.name)' (\(newLane.id.uuidString.prefix(8))), tc=\(result?.formattedTimecode ?? "none")")
            }

            // Place everything, no questions asked. Each file goes to its own
            // timecode where it has one, otherwise to the drop.
            await addVideoFilesSequentially(urls: newVideoURLs, startFrame: atFrame)

            // Audio to its assigned lane. Uses the overlap-avoiding placement:
            // video import creates its own embedded-audio lanes as it goes, so a
            // lane reserved here can already be occupied by the time we place.
            debugPrint("handleMixedBatchDrop: placing \(allItems.filter { $0.mediaType == .audio }.count) audio item(s)")
            for item in allItems where item.mediaType == .audio {
                guard let laneId = item.targetLaneId else {
                    debugPrint("handleMixedBatchDrop: '\(item.url.lastPathComponent)' has no targetLaneId, SKIPPED")
                    continue
                }
                let target = placementFrame(metadata: item.detectedTimecode, dropFrame: atFrame)
                let clip = await addAudioToTimelineAvoidingOverlap(
                    url: item.url,
                    preferredLaneId: laneId,
                    atFrame: target
                )
                debugPrint("handleMixedBatchDrop: placed '\(item.url.lastPathComponent)' at \(target) -> \(clip == nil ? "FAILED" : "ok")")
            }
            reservedAudioLaneIds.removeAll()
            // Placement spills to a fresh lane whenever the reserved one is
            // taken, stranding the lane held for the file.
            discardEmptyLanesCreatedForDrop()

            // Add padding after all files
            let paddingFrames = Int(TimelineLayout.defaultPaddingMinutes * 60.0 * timelineManager.timeline.config.frameRate.fps)
            if let lastReel = timelineManager.timeline.videoReels.last {
                timelineManager.extendTimeline(toEndFrame: lastReel.timelineEndFrame + paddingFrames)
            }
        }
    }

    // MARK: - Media Library Handlers

    /// Handle media item double-clicked to add to video track
    func handleAddToVideoTrack(_ item: MediaItem) {
        if timelineManager.timeline.videoReels.contains(where: { $0.sourceURL == item.url }) {
            alerts.show(.videoAlreadyInTimeline(item.displayName))
            return
        }

        videoInsertURL = item.url
        showVideoInsertSheetViaCoordinator()
    }

    /// Handle media item double-clicked to add to audio lane
    /// Creates a new audio lane and adds the audio there
    func handleAddToAudioLane(_ item: MediaItem, _ laneIndex: Int) {
        if timelineManager.timeline.audioLanes.contains(where: { lane in
            lane.clips.contains(where: { $0.sourceURL == item.url })
        }) {
            alerts.show(.audioAlreadyInTimeline(item.displayName))
            return
        }

        Task {
            // Create a new audio lane for this audio file
            let laneNumber = timelineManager.timeline.audioLanes.count + 1
            let newLane = timelineManager.addAudioLane(name: "Audio \(laneNumber)")

            _ = await addAudioToTimeline(url: item.url, laneId: newLane.id, atFrame: 0)

            // Auto-expand timeline so user can see the new lane
            timelineViewModel.expandIfNeeded()
        }
    }

    // MARK: - Video Timeline Operations

    /// Add a video file to the timeline with optional timecode check
    /// - Parameters:
    ///   - url: Video file URL
    ///   - atFrame: Target frame position (nil = auto-place at end)
    ///   - checkTimecode: Whether to check for embedded timecode and prompt user
    func addVideoToTimeline(url: URL, atFrame: Int?, checkTimecode: Bool = true) async {
        var atFrame = atFrame

        // Place at the video's own timecode when it has one. `checkTimecode:
        // false` means a caller has already resolved the frame and is passing it
        // in, so leave its answer alone.
        if checkTimecode {
            let filenameTC = detectTimecodeFromFilename(url.lastPathComponent)
            let metadataTC = await embeddedTimecodeService.detectTimecode(from: url, bookmark: nil)

            if filenameTC != nil || metadataTC != nil {
                atFrame = placementFrame(
                    metadata: metadataTC,
                    filenameTimecode: filenameTC,
                    dropFrame: atFrame ?? 0
                )
                debugPrint("addVideoToTimeline: '\(url.lastPathComponent)' -> frame \(atFrame ?? 0) (filename=\(filenameTC ?? "nil"), metadata=\(metadataTC?.formattedTimecode ?? "nil"))")
            }
        }

        isLoadingMedia = true

        do {
            // Detect video frame rate and duration first
            let asset = AVAsset(url: url)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let videoTrack = videoTracks.first else {
                throw NSError(domain: "Projector", code: 1, userInfo: [NSLocalizedDescriptionKey: "No video track found"])
            }

            let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
            let videoFPS = closestTimecodeFrameRate(to: Double(nominalFrameRate))
            let duration = try await asset.load(.duration)
            let videoDurationFrames = Int(duration.seconds * videoFPS.fps)

            // Check for FPS conflict
            let hasExistingReels = !timelineManager.timeline.videoReels.isEmpty
            let projectFPS = timelineManager.timeline.config.frameRate

            if hasExistingReels && videoFPS != projectFPS {
                // FPS conflict - show dialog
                isLoadingMedia = false
                pendingVideoURL = url
                pendingVideoFPS = videoFPS
                pendingVideoInsertFrame = atFrame
                showFPSConflictAlertViaCoordinator(videoFPS: videoFPS, projectFPS: projectFPS)
                // Deferred behind a dialog, so it leaves the batch rather than
                // holding it open. If the user goes ahead it reports as its own
                // batch once the import resumes.
                splitHardPannedReelsIfBatchComplete(candidate: nil)
                return
            }

            // If first video, set project FPS to match
            if !hasExistingReels {
                var config = timelineManager.timeline.config
                config.frameRate = videoFPS
                config.startTimecode = Timecode(.frames(config.startTimecode.frameCount.wholeFrames), at: videoFPS, by: .clamping)
                config.endTimecode = Timecode(.frames(config.endTimecode.frameCount.wholeFrames), at: videoFPS, by: .clamping)
                timelineManager.updateConfig(config)
            }

            // Calculate placement frame, avoiding overlaps with existing reels
            var placementFrame = atFrame ?? (timelineManager.timeline.videoReels.map { $0.timelineEndFrame }.max() ?? 0)
            placementFrame = findNonOverlappingPosition(
                startFrame: placementFrame,
                durationFrames: videoDurationFrames,
                existingReels: timelineManager.timeline.videoReels
            )

            await addVideoToTimelineUnchecked(url: url, at: placementFrame)

        } catch {
            isLoadingMedia = false
            alerts.show(.error(error.localizedDescription))
            // A file that never imported still has to leave the batch.
            splitHardPannedReelsIfBatchComplete(candidate: nil)
        }
    }

    /// Find a position for a new video that doesn't overlap with existing reels
    /// If the proposed position overlaps, places it immediately after the overlapping reel
    func findNonOverlappingPosition(startFrame: Int, durationFrames: Int, existingReels: [VideoReel]) -> Int {
        var proposedStart = startFrame
        let proposedEnd = proposedStart + durationFrames

        // Sort reels by start frame
        let sortedReels = existingReels.sorted { $0.timelineStartFrame < $1.timelineStartFrame }

        // Check for overlaps and adjust position
        for reel in sortedReels {
            let reelStart = reel.timelineStartFrame
            let reelEnd = reel.timelineEndFrame

            // Check if proposed position overlaps with this reel
            if proposedStart < reelEnd && proposedEnd > reelStart {
                // Overlap detected - move to immediately after this reel
                proposedStart = reelEnd
                debugPrint("findNonOverlappingPosition: Overlap with '\(reel.displayName)', moving to frame \(proposedStart)")
            }
        }

        return proposedStart
    }

    /// Add video without FPS checking (internal use after conflict resolution)
    func addVideoToTimelineUnchecked(url: URL, at timelineFrame: Int) async {
        let t0 = CFAbsoluteTimeGetCurrent()
        func elapsed() -> String { String(format: "%.3fs", CFAbsoluteTimeGetCurrent() - t0) }

        debugPrint("addVideoToTimeline: ENTRY [T+\(elapsed())] - \(url.lastPathComponent)")

        do {
            // Import to media library first (if not already there)
            let mediaItem = try await mediaLibrary.importFile(from: url)
            debugPrint("addVideoToTimeline: Media library import done [T+\(elapsed())]")

            // Add the video reel with reference to the media item
            let reel = try await timelineManager.addVideoReel(from: url, at: timelineFrame, mediaItemId: mediaItem.id)
            debugPrint("addVideoToTimeline: Reel added [T+\(elapsed())]")

            // CRITICAL: Sync timeline and load reel IMMEDIATELY for instant playback
            // Don't block on thumbnail generation or audio extraction
            syncTimelineToPlaybackEngine()
            debugPrint("addVideoToTimeline: Timeline synced [T+\(elapsed())]")

            // If this is the first reel, load it right away
            if timelineManager.timeline.videoReels.count == 1 {
                try await playbackEngine.loadReel(reel)
                debugPrint("addVideoToTimeline: Reel loaded in playback engine [T+\(elapsed())]")
            }

            // Check for audio tracks and create lane + placeholder clip IMMEDIATELY
            // This ensures the audio region appears in UI right away, before extraction completes
            let audioResult = await prepareAudioLaneIfNeeded(for: reel)
            debugPrint("addVideoToTimeline: Audio lane + clip prepared [T+\(elapsed())]")

            // The placeholder clip exists by now, so the lane the video's audio
            // landed on can be identified and routed from the video's name.
            applyNamedOutputToVideoAudio(for: url)

            isLoadingMedia = false
            debugPrint("addVideoToTimeline: READY FOR PLAYBACK [T+\(elapsed())]")

            // Generate thumbnail in background (non-blocking)
            let thumbnailCacheRef = thumbnailCache
            Task(priority: .utility) {
                thumbnailCacheRef.prewarm(for: reel)
            }

            // Extract audio in background and update the placeholder clip with extractedAudioURL
            guard let audioResult else {
                // Still reports, so a batch waiting on this file is not left
                // one short and held open forever.
                splitHardPannedReelsIfBatchComplete(candidate: nil)
                return
            }

            if case let (lane, clipId) = audioResult {
                Task(priority: .utility) {
                    // The reel's stereo audio is extracted independently. The
                    // split question does not depend on it: `updateExtractedAudioURL`
                    // does nothing if the clip has already moved, and a split
                    // attaches its own per-channel files rather than reusing this
                    // one. Waiting for it meant the question could not be asked
                    // until every reel in the drop had been exported in full.
                    let extraction = Task(priority: .utility) {
                        await self.extractAudioInBackground(
                            reel: reel,
                            laneId: lane.id,
                            clipId: clipId
                        )
                    }

                    let analysis = await Self.hardPanningAnalysis(of: reel.sourceURL)
                    await self.reportSplitCandidate(
                        reel: reel,
                        laneId: lane.id,
                        clipId: clipId,
                        analysis: analysis
                    )

                    await extraction.value
                }
            }
        } catch {
            debugPrint("addVideoToTimeline: FAILED [T+\(elapsed())] - \(error)")
            isLoadingMedia = false
            alerts.show(.error(error.localizedDescription))
            splitHardPannedReelsIfBatchComplete(candidate: nil)
        }
    }

    /// Handle user choosing to change project FPS (removes existing reels)
    func handleFPSConflictChangeProject() {
        guard let url = pendingVideoURL, let fps = pendingVideoFPS else { return }

        // Remove all existing video reels
        for reel in timelineManager.timeline.videoReels {
            timelineManager.removeVideoReel(id: reel.id)
            thumbnailCache.remove(reelId: reel.id)
        }

        // Update project FPS
        var config = timelineManager.timeline.config
        config.frameRate = fps
        config.startTimecode = Timecode(.frames(config.startTimecode.frameCount.wholeFrames), at: fps, by: .clamping)
        config.endTimecode = Timecode(.frames(config.endTimecode.frameCount.wholeFrames), at: fps, by: .clamping)
        timelineManager.updateConfig(config)

        // Clear pending state
        pendingVideoURL = nil
        pendingVideoFPS = nil
        let insertFrame = pendingVideoInsertFrame
        pendingVideoInsertFrame = nil

        // Now add the video
        Task {
            let placementFrame = insertFrame ?? 0
            await addVideoToTimelineUnchecked(url: url, at: placementFrame)
        }
    }

    /// Convert video frame rate to closest TimecodeFrameRate
    func closestTimecodeFrameRate(to fps: Double) -> TimecodeFrameRate {
        // Common frame rates and their nominal values
        let rates: [(TimecodeFrameRate, Double)] = [
            (.fps23_976, 23.976),
            (.fps24, 24.0),
            (.fps25, 25.0),
            (.fps29_97, 29.97),
            (.fps30, 30.0),
        ]

        var closest = TimecodeFrameRate.fps24
        var minDiff = Double.infinity

        for (rate, nominal) in rates {
            let diff = abs(fps - nominal)
            if diff < minDiff {
                minDiff = diff
                closest = rate
            }
        }

        return closest
    }

    // MARK: - Audio Timeline Operations

    /// Add an audio file to the timeline with optional timecode check
    /// - Parameters:
    ///   - url: Audio file URL
    ///   - laneId: Target audio lane ID
    ///   - atFrame: Target frame position (nil = auto-place at end)
    ///   - checkTimecode: Whether to check for embedded timecode and prompt user
    /// - Returns: The created AudioClip, or nil if timecode alert shown or error occurred
    func addAudioToTimeline(url: URL, laneId: UUID, atFrame: Int?, checkTimecode: Bool = true) async -> AudioClip? {
        var atFrame = atFrame
        debugPrint("addAudioToTimeline: ENTRY - \(url.lastPathComponent), laneId=\(laneId), atFrame=\(atFrame ?? -1), checkTimecode=\(checkTimecode)")

        // Place at the file's own timecode when it has one - BWF stems carry it,
        // and a stem's timestamp is the whole point of the delivery.
        if checkTimecode, let result = await embeddedTimecodeService.detectTimecode(from: url, bookmark: nil) {
            atFrame = placementFrame(metadata: result, dropFrame: atFrame ?? 0)
            debugPrint("addAudioToTimeline: '\(url.lastPathComponent)' timecode \(result.formattedTimecode) -> frame \(atFrame ?? 0)")
        }

        do {
            // Import to media library first (if not already there)
            debugPrint("addAudioToTimeline: importing to media library...")
            _ = try await mediaLibrary.importFile(from: url)

            // Calculate where to place the new clip (at end of existing clips in lane)
            let lane = timelineManager.timeline.audioLanes.first { $0.id == laneId }
            let placementFrame = atFrame ?? (lane?.clips.map { $0.timelineEndFrame }.max() ?? 0)
            debugPrint("addAudioToTimeline: lane found=\(lane != nil), placementFrame=\(placementFrame)")

            // Add the audio clip
            guard let clip = try await timelineManager.addAudioClip(from: url, toLane: laneId, at: placementFrame) else {
                debugPrint("addAudioToTimeline: addAudioClip returned nil (lane not found?)")
                return nil
            }
            debugPrint("addAudioToTimeline: clip created id=\(clip.id.uuidString)")

            // Every audio import funnels through here, so routing from the file
            // name lives here too - one place rather than one per drop handler.
            applyNamedOutput(for: url, laneId: laneId)

            // Sync timeline to playback engine
            syncTimelineToPlaybackEngine()

            // Verify clip is actually in the timeline
            let verifyLane = timelineManager.timeline.audioLanes.first { $0.id == laneId }
            let clipInLane = verifyLane?.clips.contains(where: { $0.id == clip.id }) ?? false
            debugPrint("addAudioToTimeline: SUCCESS - clip.id=\(clip.id.uuidString)")
            debugPrint("addAudioToTimeline: VERIFY - lane '\(verifyLane?.name ?? "NIL")' contains clip: \(clipInLane)")
            debugPrint("addAudioToTimeline: VERIFY - total lanes: \(timelineManager.timeline.audioLanes.count)")
            for (idx, lane) in timelineManager.timeline.audioLanes.enumerated() {
                debugPrint("addAudioToTimeline: VERIFY - lane[\(idx)] '\(lane.name)' has \(lane.clips.count) clips")
            }
            return clip
        } catch {
            debugPrint("addAudioToTimeline: ERROR - \(error.localizedDescription)")
            alerts.show(.error(error.localizedDescription))
            return nil
        }
    }

    // MARK: - Thumbnail Generation

    /// Prime thumbnail cache for a video reel.
    func generateThumbnail(for reel: VideoReel) async {
        thumbnailCache.prewarm(for: reel)
    }

    // MARK: - Playback Sync

    /// Sync the timeline manager's timeline to the playback engine
    func syncTimelineToPlaybackEngine() {
        playbackEngine.timeline = timelineManager.timeline
    }

    // MARK: - Audio Extraction Helpers

    /// Check if video has audio tracks and create lane + placeholder clip immediately
    /// Returns (lane, clipId) if audio tracks exist, nil otherwise
    /// Reuses existing lanes if the new clip fits without overlap
    private func prepareAudioLaneIfNeeded(for reel: VideoReel) async -> (lane: AudioLane, clipId: UUID)? {
        let asset = AVAsset(url: reel.sourceURL)
        do {
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard !audioTracks.isEmpty else {
                debugPrint("prepareAudioLaneIfNeeded: No audio tracks found")
                return nil
            }

            // Get channel count and sample rate from audio format
            let audioTrack = audioTracks[0]
            let formatDescriptions = try await audioTrack.load(.formatDescriptions)
            var channelCount = 2
            var sampleRate: Double = 48000

            if let formatDesc = formatDescriptions.first {
                let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
                if let format = asbd?.pointee {
                    channelCount = Int(format.mChannelsPerFrame)
                    sampleRate = format.mSampleRate
                }
            }

            // Create a placeholder clip IMMEDIATELY (without extractedAudioURL)
            // This ensures the audio region appears in UI right away, before extraction completes
            let clip = AudioClip(
                mediaItemId: reel.mediaItemId,
                sourceURL: reel.sourceURL,
                sourceBookmark: reel.sourceBookmark,
                timelineStartFrame: reel.timelineStartFrame,
                durationFrames: reel.durationFrames,
                sourceStartFrame: reel.sourceStartFrame,
                sourceType: .videoTrack,
                sourceTrackIndex: 0,
                channelCount: channelCount,
                sampleRate: sampleRate,
                extractedAudioURL: nil,  // Will be set after extraction
                sourceFrameRate: reel.sourceFrameRate
            )

            // Try to find an existing lane where the clip fits without overlap.
            //
            // Skips lanes reserved by an in-flight batch drop. A mixed drop
            // reserves one empty lane per audio file before importing the
            // videos; an empty lane never "overlaps", so without this filter the
            // video's embedded audio would adopt a lane earmarked for one of
            // those files, and that file would then have nowhere to land.
            let reserved = reservedAudioLaneIds
            var targetLane: AudioLane?
            for lane in timelineManager.timeline.audioLanes where !reserved.contains(lane.id) {
                if !lane.hasOverlap(with: clip) {
                    targetLane = lane
                    debugPrint("prepareAudioLaneIfNeeded: Found existing lane '\(lane.name)' with no overlap")
                    break
                }
            }

            // If no existing lane can fit the clip, create a new one
            if targetLane == nil {
                targetLane = timelineManager.addAudioLaneAtTop(name: laneName(for: reel.sourceURL))
                debugPrint("prepareAudioLaneIfNeeded: Created new lane '\(targetLane!.name)'")
            } else if let adopted = targetLane,
                      adopted.clips.isEmpty,
                      isGenericLaneName(adopted.name) {
                // Adopting an empty, never-named lane: give it the media's name
                // like a freshly created one would get. A lane the user has
                // named, or one that already holds clips, keeps its name.
                let named = laneName(for: reel.sourceURL)
                timelineManager.renameAudioLane(id: adopted.id, name: named)
                targetLane = timelineManager.timeline.audioLanes.first { $0.id == adopted.id }
                debugPrint("prepareAudioLaneIfNeeded: renamed adopted lane '\(adopted.name)' -> '\(named)'")
            }

            guard let lane = targetLane else {
                debugPrint("prepareAudioLaneIfNeeded: Failed to get target lane")
                return nil
            }

            timelineManager.timeline.addClip(clip, toLane: lane.id)

            debugPrint("prepareAudioLaneIfNeeded: Added clip to lane '\(lane.name)' with \(audioTracks.count) audio track(s)")
            return (lane, clip.id)
        } catch {
            debugPrint("prepareAudioLaneIfNeeded: Failed to check audio tracks - \(error)")
            return nil
        }
    }

    /// Extract audio from video reel in background and update existing clip
    private func extractAudioInBackground(reel: VideoReel, laneId: UUID, clipId: UUID) async {
        let t0 = CFAbsoluteTimeGetCurrent()
        func elapsed() -> String { String(format: "%.3fs", CFAbsoluteTimeGetCurrent() - t0) }

        debugPrint("extractAudioInBackground: ENTRY [T+\(elapsed())] - \(reel.displayName)")

        let asset = AVAsset(url: reel.sourceURL)
        do {
            // Do the slow extraction
            let extractedURL = try await extractAudioTrackToTemp(from: asset, trackIndex: 0, sourceURL: reel.sourceURL)
            debugPrint("extractAudioInBackground: Export complete [T+\(elapsed())] -> \(extractedURL.lastPathComponent)")

            // Update the existing clip with the extracted audio URL
            await MainActor.run {
                timelineManager.updateExtractedAudioURL(clipId: clipId, inLane: laneId, extractedURL: extractedURL)
            }
            debugPrint("extractAudioInBackground: COMPLETE [T+\(elapsed())]")
        } catch {
            debugPrint("extractAudioInBackground: FAILED [T+\(elapsed())] - \(error)")
            // A placeholder audio clip is already on the timeline at this point,
            // so failing silently leaves a clip that never fills in and gives the
            // user no way to find out why. Remove it and say what happened.
            await MainActor.run {
                timelineManager.removeAudioClip(clipId: clipId, fromLane: laneId)
                alerts.show(.error(
                    "Couldn't extract audio from \"\(reel.displayName)\". "
                    + "The video was added without its audio track.\n\n\(error.localizedDescription)"
                ))
            }
        }
    }

    // MARK: - Hard-Panned Audio

    /// Analyze a source file for hard panning, off the main actor.
    ///
    /// - Returns: The analysis, or `nil` when the file has no stereo audio or
    ///   could not be read. A file that cannot be analyzed is simply not
    ///   offered a split; it already plays as ordinary stereo.
    private nonisolated static func hardPanningAnalysis(of url: URL) async -> PanningAnalysis? {
        do {
            return try await AudioPanningAnalyzer.analyze(url: url)
        } catch {
            debugPrint("hardPanningAnalysis: analysis failed - \(error)")
            return nil
        }
    }

    /// Report one reel's analysis to the batch, and ask once the batch is done.
    ///
    /// Runs after import rather than during it. Analysis reads a slice of the
    /// audio track, and blocking the import on that would trade a responsive
    /// drop for a question the user may well answer "no" to.
    ///
    /// Nothing happens without confirmation - see `AudioPanningAnalyzer` for why
    /// the detection is a suggestion rather than a rule.
    ///
    /// - Parameters:
    ///   - reel: The imported reel.
    ///   - laneId: Lane holding the reel's audio.
    ///   - clipId: That reel's clip on the lane, which a split would move.
    ///   - analysis: Result from `hardPanningAnalysis(of:)`, computed alongside
    ///     the reel's audio extraction rather than after it.
    private func reportSplitCandidate(
        reel: VideoReel,
        laneId: UUID,
        clipId: UUID,
        analysis: PanningAnalysis?
    ) async {
        var candidate: SplitCandidate?
        if let analysis, analysis.isHardPanned {
            debugPrint("reportSplitCandidate: hard panning detected in \(reel.displayName) "
                       + "(correlation \(analysis.correlation))")
            candidate = SplitCandidate(
                id: reel.id,
                displayName: reel.displayName,
                laneId: laneId,
                clipId: clipId,
                correlation: analysis.correlation
            )
        }

        await MainActor.run {
            splitHardPannedReelsIfBatchComplete(candidate: candidate)
        }
    }

    /// Hand a result to the batch, and split the lot once the last one lands.
    ///
    /// Applied rather than offered. A hard-panned reel plays with everything on
    /// one side or the other, which is broken however it got that way, and the
    /// question only ever had one sensible answer - so asking it was a step
    /// between the user and a timeline that already worked.
    ///
    /// The detection is not certain: a heavily decorrelated wide stereo mix can
    /// measure like a split track, and no threshold makes that go away. What
    /// makes acting on it safe is that the whole batch is registered as a single
    /// undo, so a reel split against the user's wishes costs one Cmd-Z rather
    /// than a rebuilt timeline.
    ///
    /// - Parameter candidate: The reel if it is hard panned, `nil` otherwise.
    @MainActor
    func splitHardPannedReelsIfBatchComplete(candidate: SplitCandidate?) {
        guard let batch = splitOffers.finish(candidate: candidate) else { return }

        // Snapshot before anything moves, so undo restores the lanes exactly as
        // the import left them.
        let previousTimeline = timelineManager.timeline
        undoManager?.registerUndo(withTarget: timelineManager) { manager in
            manager.timeline = previousTimeline
        }
        undoManager?.setActionName(
            batch.count == 1 ? "Split Hard-Panned Audio" : "Split \(batch.count) Hard-Panned Reels"
        )

        Task {
            await performChannelSplits(for: batch)
        }
    }

    /// Record, on each split lane, the output it is already playing through.
    ///
    /// A lane with no mapping is not silent - the engine falls back to the
    /// channel offset and count the lane carries, which is the first stereo pair
    /// by default. The menu reads that as "NONE" while the sound comes out of an
    /// output the user was never told about.
    ///
    /// Ordinary lanes avoid this because `AudioLaneView` assigns a default when
    /// it appears. Split lanes are drawn as part of the Video File track by
    /// `AudioLaneControls`, which has no such step, so they kept the mismatch
    /// until something unrelated refreshed the output list.
    ///
    /// Named here rather than left to a default sweep so both sides state the
    /// output they are on from the moment they exist, and so the split keeps its
    /// promise that the audio does not move.
    ///
    /// - Parameter lanes: Lanes produced by the split.
    @MainActor
    private func nameOutputOfSplitLanes(_ lanes: [AudioLane]) {
        let outputs = audioManager.mappedOutputs
        guard !outputs.isEmpty else { return }

        for lane in lanes where lane.outputMappingId == nil && !lane.isOutputDisabled {
            // The output the engine is already feeding: the one covering the
            // lane's channel span. Falls back to the first, which is the span a
            // lane starts with anyway.
            let current = outputs.first {
                $0.channelStart == lane.outputChannelOffset
                    && $0.channelCount == lane.outputChannelCount
            } ?? outputs[0]
            timelineManager.setLaneOutputMapping(id: lane.id, mapping: current)
        }
    }

    /// Split every chosen reel, showing the result only once it is finished.
    ///
    /// Two phases, deliberately. Every reel's channels are extracted first,
    /// touching nothing the user can see, and only then is the timeline changed -
    /// in one transaction that creates the lanes, attaches the audio, hands over
    /// the waveforms and names the outputs together.
    ///
    /// Doing it a reel at a time meant watching the work happen: lanes appearing
    /// one pair at a time, the original lane shrinking as each reel left it, and
    /// waveforms filling in between. Every one of those states is real, but none
    /// of them is anything the user asked to see.
    ///
    /// Extraction runs concurrently across reels, which only became safe once it
    /// stopped touching the timeline. The transaction that follows stays ordered:
    /// each split looks for the shared lane for its side, so two at once would
    /// both find none and create a competing pair.
    ///
    /// - Parameter candidates: Reels the user chose to split.
    private func performChannelSplits(for candidates: [SplitCandidate]) async {
        let names: [SplitChannel: String] = [
            .left: SplitChannel.left.conventionalRoleName,
            .right: SplitChannel.right.conventionalRoleName
        ]

        // Resolve the reels once, up front. A reel deleted while the dialog was
        // open simply drops out.
        let jobs: [(candidate: SplitCandidate, reel: VideoReel)] = await MainActor.run {
            candidates.compactMap { candidate in
                guard let reel = timelineManager.timeline.videoReels
                    .first(where: { $0.id == candidate.id }) else { return nil }
                // The stereo clip may still be decoding for a waveform that is
                // about to be replaced by the handover.
                waveformCache.cancelGeneration(for: candidate.clipId)
                return (candidate, reel)
            }
        }
        guard !jobs.isEmpty else { return }

        // Phase 1: extract, changing nothing on screen.
        var extracted: [UUID: [SplitChannel: URL]] = [:]
        var failures: [(name: String, error: Error)] = []

        await withTaskGroup(of: (UUID, String, Result<[SplitChannel: URL], Error>).self) { group in
            for job in jobs {
                let reelId = job.reel.id
                let sourceURL = job.reel.sourceURL
                let displayName = job.reel.displayName
                group.addTask {
                    var destinations: [SplitChannel: URL] = [:]
                    for channel in SplitChannel.allCases {
                        destinations[channel] = AudioChannelExtractor.temporaryURL(
                            for: sourceURL,
                            channel: channel
                        )
                    }
                    do {
                        let written = try await AudioChannelExtractor.extractChannels(
                            from: sourceURL,
                            to: destinations
                        )
                        return (reelId, displayName, .success(written))
                    } catch {
                        return (reelId, displayName, .failure(error))
                    }
                }
            }

            for await (reelId, displayName, result) in group {
                switch result {
                case .success(let written): extracted[reelId] = written
                case .failure(let error): failures.append((displayName, error))
                }
            }
        }

        // Phase 2: one transaction. Everything the user sees changes at once.
        await MainActor.run {
            for job in jobs {
                // A reel whose extraction failed is left unsplit rather than
                // half-split: better the lane it already had than two lanes with
                // no audio behind them.
                guard let written = extracted[job.reel.id] else { continue }

                guard let split = timelineManager.splitVideoAudioClipByChannel(
                    clipId: job.candidate.clipId,
                    inLane: job.candidate.laneId,
                    reelId: job.reel.id,
                    names: names
                ) else {
                    debugPrint("performChannelSplits: clip \(job.candidate.clipId) no longer splittable")
                    continue
                }

                nameOutputOfSplitLanes(split)

                for lane in split {
                    guard let channel = lane.splitChannel,
                          let clipId = lane.clips.first(where: {
                              $0.sourceURL == job.reel.sourceURL && $0.sourceChannel == channel
                          })?.id else { continue }

                    if let url = written[channel] {
                        timelineManager.updateSplitClipSource(
                            clipId: clipId,
                            inLane: lane.id,
                            extractedURL: url
                        )
                    }

                    // Hand each side the trace already drawn for it. The stereo
                    // clip's atlas holds both channels separately - that is what
                    // was on screen while the question was being asked - so the
                    // split lanes show the right waveform straight away instead
                    // of decoding to recompute numbers we already had.
                    if !waveformCache.adoptChannel(
                        from: job.candidate.clipId,
                        channel: channel,
                        as: clipId
                    ) {
                        // Nothing to inherit, because the stereo trace had not
                        // finished. The clip generates its own from the mono file
                        // that is already attached, which is the cheap source.
                        waveformCache.removeCachedWaveform(for: clipId)
                    }

                    // The loaded audio was the stereo video and must be reread
                    // from this channel's own file, or the lane plays both sides.
                    playbackEngine.invalidateAudioClip(id: clipId)
                }

                // Dropped only now: it was the source of the traces handed over.
                waveformCache.removeCachedWaveform(for: job.candidate.clipId)
            }

            syncTimelineToPlaybackEngine()

            if let first = failures.first {
                let more = failures.count > 1 ? " (and \(failures.count - 1) more)" : ""
                alerts.show(.error(
                    "Couldn't split the channels of \"\(first.name)\"\(more).\n\n"
                    + first.error.localizedDescription
                ))
            }
        }

        debugPrint("performChannelSplits: split \(extracted.count) of \(jobs.count) reels")
    }

    /// Extract an audio track from an asset to a temporary file
    /// Uses passthrough (no re-encoding) for speed
    /// Must be called while security-scoped access is active
    private func extractAudioTrackToTemp(from asset: AVAsset, trackIndex: Int, sourceURL: URL) async throws -> URL {
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard trackIndex < audioTracks.count else {
            throw NSError(domain: "ContentView", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid audio track index"])
        }

        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw NSError(domain: "ContentView", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to create composition track"])
        }

        let track = audioTracks[trackIndex]
        let duration = try await asset.load(.duration)
        try compositionTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: duration),
            of: track,
            at: .zero
        )

        // Use passthrough preset - copies audio stream without re-encoding (MUCH faster)
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw NSError(domain: "ContentView", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to create export session"])
        }

        // Deterministic filename based on source URL and track
        // Use .mov container for passthrough compatibility
        let keyHash = "\(sourceURL.absoluteString)-track\(trackIndex)".hashValue
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("projector-audio-\(abs(keyHash)).mov")

        if FileManager.default.fileExists(atPath: tempURL.path) {
            try FileManager.default.removeItem(at: tempURL)
        }

        if #available(macOS 15.0, *) {
            try await export.export(to: tempURL, as: .mov)
        } else {
            export.outputURL = tempURL
            export.outputFileType = .mov

            // Wrapper to make AVAssetExportSession usable in Sendable closure
            final class ExportBox: @unchecked Sendable {
                let session: AVAssetExportSession
                init(_ session: AVAssetExportSession) { self.session = session }
            }
            let exportBox = ExportBox(export)

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                exportBox.session.exportAsynchronously {
                    switch exportBox.session.status {
                    case .completed:
                        continuation.resume(returning: ())
                    case .failed:
                        continuation.resume(throwing: exportBox.session.error ?? NSError(domain: "ContentView", code: -4, userInfo: nil))
                    default:
                        continuation.resume(throwing: NSError(domain: "ContentView", code: -5, userInfo: nil))
                    }
                }
            }
        }

        return tempURL
    }

    // MARK: - Batch Timecode Detection

    /// Detect embedded timecode for multiple files in parallel
    /// - Parameters:
    ///   - urls: Array of file URLs to check
    ///   - mediaType: The media type for these files (video or audio)
    /// - Returns: Array of BatchTimecodeItem with detected timecodes
    func detectTimecodeForBatch(urls: [URL], mediaType: BatchMediaType = .video) async -> [BatchTimecodeItem] {
        await withTaskGroup(of: BatchTimecodeItem.self, returning: [BatchTimecodeItem].self) { group in
            for url in urls {
                group.addTask {
                    let result = await self.embeddedTimecodeService.detectTimecode(from: url, bookmark: nil)
                    return BatchTimecodeItem(url: url, mediaType: mediaType, detectedTimecode: result)
                }
            }

            var items: [BatchTimecodeItem] = []
            for await item in group {
                items.append(item)
            }

            // Maintain original order by sorting by URL
            let urlOrder = Dictionary(uniqueKeysWithValues: urls.enumerated().map { ($1, $0) })
            return items.sorted { urlOrder[$0.url, default: 0] < urlOrder[$1.url, default: 0] }
        }
    }

    /// Add multiple video files sequentially (no timecode placement)
    /// - Parameters:
    ///   - urls: Array of video file URLs
    ///   - startFrame: Frame to start placing videos at
    func addVideoFilesSequentially(urls: [URL], startFrame: Int) async {
        var currentFrame = startFrame

        // Declared up front so the whole drop is one batch. Counting as each
        // file starts would let a short reel finish analysing before the next
        // one began, and close the batch early.
        splitOffers.expect(urls.count)

        for url in urls {
            // Skip duplicates
            if timelineManager.timeline.videoReels.contains(where: { $0.sourceURL == url }) {
                // Never imported, so it reports out of the batch here instead.
                splitHardPannedReelsIfBatchComplete(candidate: nil)
                continue
            }

            // Its own timecode if it has one, otherwise after the last file.
            // Resolved here rather than inside `addVideoToTimeline` so the
            // running position is only used by the files that need it.
            let filenameTC = detectTimecodeFromFilename(url.lastPathComponent)
            let metadataTC = await embeddedTimecodeService.detectTimecode(from: url, bookmark: nil)
            let target = placementFrame(
                metadata: metadataTC,
                filenameTimecode: filenameTC,
                dropFrame: currentFrame
            )

            await addVideoToTimeline(url: url, atFrame: target, checkTimecode: false)

            // Get the reel that was just added to find its end frame
            if let lastReel = timelineManager.timeline.videoReels.last(where: { $0.sourceURL == url }) {
                currentFrame = lastReel.timelineEndFrame
            }
        }

        // Add padding after all files
        let paddingFrames = Int(TimelineLayout.defaultPaddingMinutes * 60.0 * timelineManager.timeline.config.frameRate.fps)
        if let lastReel = timelineManager.timeline.videoReels.last {
            timelineManager.extendTimeline(toEndFrame: lastReel.timelineEndFrame + paddingFrames)
        }
    }

    /// Add multiple audio files sequentially to a lane (no timecode placement)
    /// - Parameters:
    ///   - urls: Array of audio file URLs
    ///   - laneId: Target audio lane ID
    ///   - startFrame: Frame to start placing audio clips at
    // MARK: - Lane Naming

    /// A lane name derived from the media that will occupy it.
    ///
    /// A lane created to hold a specific file is named after that file rather
    /// than "Audio 3" - when stems are dropped together, the generic numbering
    /// gives no way to tell which lane is dialogue and which is FX without
    /// clicking each clip. Falls back to the numbered name when there's no
    /// file to name it after (an empty lane added by hand).
    ///
    /// - Parameter url: Source media for the lane.
    /// - Returns: The file's name without its extension, trimmed.
    /// Size the player window to a reel's media.
    ///
    /// Prefers the library's cached `videoSize` - it was measured when the file
    /// was imported and costs nothing to read. Falls back to loading the track
    /// directly, because a reel can exist without a matching library item (added
    /// straight to the timeline rather than through the media panel), and in
    /// that case there is no cached size to use.
    func sizePlayerToReel(_ reel: VideoReel) async {
        if let cached = mediaLibrary.existingItem(for: reel.sourceURL)?.videoSize, cached.width > 0 {
            PlayerWindowController.shared.sizeToMedia(cached)
            return
        }

        let asset = AVURLAsset(url: reel.sourceURL)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let naturalSize = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else { return }

        // Same display-size derivation the library uses: rotated footage encodes
        // its dimensions the other way round.
        let display = CGRect(origin: .zero, size: naturalSize).applying(transform).standardized
        let size = CGSize(width: abs(display.width), height: abs(display.height))
        guard size.width > 0, size.height > 0 else { return }
        PlayerWindowController.shared.sizeToMedia(size)
    }

    func laneName(for url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? nextGenericLaneName() : base
    }

    /// The next "Audio N" name, for lanes with no associated file.
    func nextGenericLaneName() -> String {
        "Audio \(timelineManager.timeline.audioLanes.count + 1)"
    }

    /// Whether a lane still carries an auto-generated "Audio N" name, meaning
    /// the user hasn't named it and it's safe to rename after its content.
    func isGenericLaneName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("Audio ") else { return false }
        let suffix = trimmed.dropFirst("Audio ".count)
        return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
    }

    /// Whether a clip spanning `startFrame ..< startFrame + durationFrames`
    /// would intersect any existing clip in the lane.
    private func laneIsOccupied(_ lane: AudioLane, startFrame: Int, durationFrames: Int) -> Bool {
        let endFrame = startFrame + durationFrames
        return lane.clips.contains { clip in
            clip.timelineStartFrame < endFrame && startFrame < clip.timelineEndFrame
        }
    }

    /// Place an audio clip on the preferred lane, or on a new lane when the
    /// destination frames are already occupied.
    ///
    /// The model allows overlapping clips (`AudioLane.addClip` appends
    /// unconditionally), so placing a batch of files that share a start
    /// timecode - stems and mix passes routinely all start at 01:00:00:00 -
    /// used to stack every clip at the same frames of the same lane. The lane
    /// showed one clip's waveform with the rest hidden exactly underneath,
    /// which read as "only the first file was imported". Spilling each
    /// overlapping file onto its own lane keeps all of them visible and
    /// aligned, which is the layout simultaneous material wants anyway.
    func addAudioToTimelineAvoidingOverlap(url: URL, preferredLaneId: UUID, atFrame: Int) async -> AudioClip? {
        let fps = timelineManager.timeline.config.frameRate.fps
        var durationFrames = 1
        if let duration = try? await AVURLAsset(url: url).load(.duration) {
            durationFrames = max(1, Int(duration.seconds * fps))
        }

        var targetLaneId = preferredLaneId

        if let preferred = timelineManager.timeline.audioLanes.first(where: { $0.id == preferredLaneId }) {
            if laneIsOccupied(preferred, startFrame: atFrame, durationFrames: durationFrames) {
                let newLane = timelineManager.addAudioLane(name: laneName(for: url))
                debugPrint("addAudioToTimelineAvoidingOverlap: '\(url.lastPathComponent)' overlaps at frame \(atFrame); spilling to new lane '\(newLane.name)'")
                targetLaneId = newLane.id
            }
        } else {
            // The reserved lane is gone. Mixed drops reserve a lane per audio
            // file up front, but importing the videos in the same batch creates
            // its OWN embedded-audio lanes and prunes empty ones - so by the
            // time we place, the reserved ID can name a lane that no longer
            // exists. `addAudioClip` guards on lane existence and returns nil,
            // which silently dropped the file with no error anywhere. Make a
            // fresh lane instead of losing the audio.
            let newLane = timelineManager.addAudioLane(name: laneName(for: url))
            debugPrint("addAudioToTimelineAvoidingOverlap: preferred lane \(preferredLaneId.uuidString.prefix(8)) no longer exists for '\(url.lastPathComponent)'; created '\(newLane.name)'")
            targetLaneId = newLane.id
        }

        if let clip = await addAudioToTimeline(url: url, laneId: targetLaneId, atFrame: atFrame, checkTimecode: false) {
            return clip
        }

        // Backstop: placement returned nil, so the file is currently lost with
        // no error surfaced anywhere. `addAudioClip` returns nil whenever the
        // target lane no longer exists, and lanes reserved for a batch can be
        // claimed out from under us - `prepareAudioLaneIfNeeded` adopts ANY
        // lane the video's embedded audio doesn't overlap, which includes the
        // empty ones reserved here. Retry once on a guaranteed-fresh lane
        // rather than dropping the file silently.
        let fallbackLane = timelineManager.addAudioLane(name: laneName(for: url))
        debugPrint("addAudioToTimelineAvoidingOverlap: first placement of '\(url.lastPathComponent)' failed; retrying on fresh lane '\(fallbackLane.name)'")

        let retried = await addAudioToTimeline(url: url, laneId: fallbackLane.id, atFrame: atFrame, checkTimecode: false)
        if retried == nil {
            debugPrint("addAudioToTimelineAvoidingOverlap: RETRY ALSO FAILED for '\(url.lastPathComponent)'")
            alerts.show(.error("Couldn't add \"\(url.lastPathComponent)\" to the timeline."))
        }
        return retried
    }

    /// Add audio files at their embedded timecode positions (auto-confirm mode)
    ///
    /// Used when another sheet is showing and we can't display the batch timecode sheet.
    /// Files with embedded timecode are placed at their timecode positions;
    /// files without timecode are placed sequentially after the last file.
    ///
    /// - Parameters:
    ///   - items: Batch timecode items with detected timecode info
    ///   - laneId: Target audio lane ID
    ///   - fallbackFrame: Frame to start placing clips without timecode
    func addAudioFilesAtEmbeddedTimecode(items: [BatchTimecodeItem], laneId: UUID, fallbackFrame: Int) async {
        var nextSequentialFrame = fallbackFrame

        for item in items {
            // Relative to the timeline's start, like every other placement.
            let targetFrame = placementFrame(
                metadata: item.detectedTimecode,
                dropFrame: nextSequentialFrame
            )
            debugPrint("addAudioFilesAtEmbeddedTimecode: \(item.url.lastPathComponent) -> frame \(targetFrame) (\(item.hasTimecode ? "timecode" : "sequential"))")

            if let clip = await addAudioToTimelineAvoidingOverlap(url: item.url, preferredLaneId: laneId, atFrame: targetFrame) {
                nextSequentialFrame = clip.timelineEndFrame
            }
        }

        // Add padding after all files
        let paddingFrames = Int(TimelineLayout.defaultPaddingMinutes * 60.0 * timelineManager.timeline.config.frameRate.fps)
        if let lane = timelineManager.timeline.audioLanes.first(where: { $0.id == laneId }),
           let lastClip = lane.clips.last {
            timelineManager.extendTimeline(toEndFrame: lastClip.timelineEndFrame + paddingFrames)
        }
    }

    /// Handle user confirmation of batch timecode placement choices
    /// - Parameter setTimelineStart: Whether to set timeline start to first file's timecode
    func discardEmptyLanesCreatedForDrop() {
        for laneId in batchCreatedLaneIds {
            guard let lane = timelineManager.timeline.audioLanes.first(where: { $0.id == laneId }),
                  lane.clips.isEmpty else { continue }
            timelineManager.removeAudioLane(id: laneId)
        }
        batchCreatedLaneIds.removeAll()
    }

    // MARK: - Automatic Placement

    /// Where a dropped file lands.
    ///
    /// Import asks nothing: a file that carries its own timecode goes to that
    /// timecode, and anything else goes where it was dropped. Both answers are
    /// changeable afterwards - "Set Timecode Position" and "Set Timeline Start to
    /// Region" on the region's menu - which is why the dialog that used to ask up
    /// front was removed.
    ///
    /// Timecode is resolved **relative to the timeline's start**, so a reel
    /// delivered at 01:00:00:00 lands at frame 0 on a timeline that starts there
    /// rather than an hour along it.
    ///
    /// - Parameters:
    ///   - metadata: Embedded timecode, if the file has any. Preferred: it is the
    ///     recorder's own answer.
    ///   - filenameTimecode: Timecode parsed out of the name, as a fallback.
    ///   - dropFrame: Where the user let go, used when the file says nothing.
    /// - Returns: A frame relative to the timeline start, never negative.
    func placementFrame(
        metadata: EmbeddedTimecodeResult?,
        filenameTimecode: String? = nil,
        dropFrame: Int
    ) -> Int {
        let config = timelineManager.timeline.config
        let startFrames = config.startTimecode.frameCount.wholeFrames

        if let metadata {
            return max(0, metadata.convertedFrames(to: config.frameRate.fps) - startFrames)
        }
        if let filenameTimecode,
           let parsed = try? Timecode(.string(filenameTimecode), at: config.frameRate, by: .clamping) {
            return max(0, parsed.frameCount.wholeFrames - startFrames)
        }
        return dropFrame
    }

    // MARK: - Output Routing from File Names

    /// The mapped output a file's name asks for, if any.
    ///
    /// A name only counts when the role it names has actually been mapped in
    /// Settings - suggesting a DX/SFX output that does not exist would put a
    /// question in the dialog with no answer behind it.
    ///
    /// - Parameter url: The file being imported.
    /// - Returns: The output to suggest, or `nil` for no suggestion.
    func outputNamedByFile(_ url: URL) -> MappedAudioOutput? {
        guard let role = OutputRole.named(in: url.lastPathComponent) else { return nil }
        return audioManager.mappedOutputs.first { role.matches($0) }
    }

    /// Route a lane from the name of the file that established it.
    ///
    /// Applied at placement rather than offered in the import dialog. The name
    /// already says where the stem goes, so a dialog asking permission to honour
    /// it was a question with one sensible answer - and routing that depended on
    /// a sheet appearing meant a drop with no timecode was never routed at all.
    /// The lane's own output menu is the override.
    ///
    /// Only when the clip is the first on its lane: a lane already holding audio
    /// has a routing that belongs to the lane, and a later drop should not
    /// re-point it.
    ///
    /// - Parameters:
    ///   - url: The file that was placed.
    ///   - laneId: The lane it landed on.
    func applyNamedOutput(for url: URL, laneId: UUID) {
        guard let output = outputNamedByFile(url),
              let lane = timelineManager.timeline.audioLanes.first(where: { $0.id == laneId }),
              lane.clips.count == 1 else { return }

        timelineManager.setLaneOutputMapping(id: lane.id, mapping: output)
        debugPrint("applyNamedOutput: '\(url.lastPathComponent)' lane '\(lane.name)' -> output '\(output.name)'")
    }

    /// Route the lane holding a video's own audio track, from the video's name.
    ///
    /// Found by the clip rather than `Timeline.videoAudioLane`, which returns the
    /// *first* such lane and so cannot tell two videos' audio apart in a batch.
    /// The extracted clip keeps the video's URL as its source, which identifies
    /// the lane exactly.
    ///
    /// - Parameter url: The video file whose audio lane should be routed.
    func applyNamedOutputToVideoAudio(for url: URL) {
        guard let output = outputNamedByFile(url) else { return }
        guard let lane = timelineManager.timeline.audioLanes.first(where: { lane in
            lane.clips.contains { $0.sourceURL == url && $0.sourceType == .videoTrack }
        }) else {
            debugPrint("applyNamedOutputToVideoAudio: no lane holds audio from '\(url.lastPathComponent)'")
            return
        }
        timelineManager.setLaneOutputMapping(id: lane.id, mapping: output)
        debugPrint("applyNamedOutputToVideoAudio: '\(url.lastPathComponent)' lane '\(lane.name)' -> output '\(output.name)'")
    }

    /// Show the batch timecode sheet via AlertCoordinator
    func showFPSConflictAlertViaCoordinator(videoFPS: TimecodeFrameRate, projectFPS: TimecodeFrameRate) {
        let message = "This video is \(videoFPS.stringValueVerbose) but your project is \(projectFPS.stringValueVerbose). Would you like to change the project frame rate? This will remove existing videos."

        alerts.show(.fpsConflict(
            message: message,
            onChangeProjectFPS: {
                self.handleFPSConflictChangeProject()
            },
            onCancel: {
                self.pendingVideoURL = nil
                self.pendingVideoFPS = nil
                self.pendingVideoInsertFrame = nil
            }
        ))
    }

    /// Show the video insert sheet via AlertCoordinator
    func showVideoInsertSheetViaCoordinator() {
        guard videoInsertURL != nil else { return }

        let config = timelineManager.timeline.config
        alerts.show(.videoInsert(
            url: $videoInsertURL,
            frameRate: config.frameRate,
            startTimecode: config.startTimecode,
            onConfirm: { confirmedURL, insertFrame in
                Task { @MainActor in
                    await self.addVideoToTimelineUnchecked(url: confirmedURL, at: insertFrame)
                    self.videoInsertURL = nil
                }
            }
        ))
    }

}

// MARK: - Filename Timecode Detection

/// Detects timecode from filename patterns commonly used by composers.
///
/// Supported patterns:
/// - `R1_01_00_00_00` (underscore-separated HH_MM_SS_FF)
/// - `R1_01-00-00-00` (dash-separated HH-MM-SS-FF)
/// - `R1_010000_00` (compact HHMMSS_FF)
/// - `01:00:00:00` (colon-separated in filename)
///
/// - Parameter filename: The filename (without path) to parse
/// - Returns: Detected timecode string, or nil if not found
func detectTimecodeFromFilename(_ filename: String) -> String? {
    // Remove extension
    let name = (filename as NSString).deletingPathExtension

    // Pattern 1: Underscore separated (R1_01_00_00_00)
    // Matches: two digits separated by underscores at end of filename
    let underscorePattern = #"(\d{2})[_](\d{2})[_](\d{2})[_](\d{2})\s*$"#
    if let match = name.range(of: underscorePattern, options: .regularExpression) {
        let component = String(name[match])
        let digits = component.filter { $0.isNumber }
        if digits.count == 8 {
            let h = digits.prefix(2)
            let m = digits.dropFirst(2).prefix(2)
            let s = digits.dropFirst(4).prefix(2)
            let f = digits.dropFirst(6).prefix(2)
            return "\(h):\(m):\(s):\(f)"
        }
    }

    // Pattern 2: Dash separated (R1_01-00-00-00)
    let dashPattern = #"(\d{2})[-](\d{2})[-](\d{2})[-](\d{2})\s*$"#
    if let match = name.range(of: dashPattern, options: .regularExpression) {
        let component = String(name[match])
        let digits = component.filter { $0.isNumber }
        if digits.count == 8 {
            let h = digits.prefix(2)
            let m = digits.dropFirst(2).prefix(2)
            let s = digits.dropFirst(4).prefix(2)
            let f = digits.dropFirst(6).prefix(2)
            return "\(h):\(m):\(s):\(f)"
        }
    }

    // Pattern 3: Colon separated in filename (rare but possible)
    let colonPattern = #"(\d{2}):(\d{2}):(\d{2}):(\d{2})"#
    if let match = name.range(of: colonPattern, options: .regularExpression) {
        return String(name[match])
    }

    // Pattern 4: Compact with frame separator (010000_00 or 010000-00)
    let compactPattern = #"(\d{6})[_-](\d{2})\s*$"#
    if let match = name.range(of: compactPattern, options: .regularExpression) {
        let component = String(name[match])
        let digits = component.filter { $0.isNumber }
        if digits.count == 8 {
            let h = digits.prefix(2)
            let m = digits.dropFirst(2).prefix(2)
            let s = digits.dropFirst(4).prefix(2)
            let f = digits.dropFirst(6).prefix(2)
            return "\(h):\(m):\(s):\(f)"
        }
    }

    return nil
}
