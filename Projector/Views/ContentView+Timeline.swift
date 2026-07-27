import SwiftUI
import AVFoundation
import SwiftTimecodeCore

// MARK: - Timeline Operations
extension ContentView {
    // MARK: - Alert State Helpers

    /// Whether the batch timecode sheet is currently showing
    var isShowingBatchTimecodeSheet: Bool {
        alerts.activeAlert?.id == "batchTimecode"
    }

    /// Whether the embedded timecode alert is currently showing
    var isShowingEmbeddedTimecodeAlert: Bool {
        alerts.activeAlert?.id == "embeddedTimecode"
    }

    /// Whether the FPS conflict alert is currently showing
    var isShowingFPSConflictAlert: Bool {
        alerts.activeAlert?.id == "fpsConflict"
    }

    /// Whether the video insert sheet is currently showing
    var isShowingVideoInsertSheet: Bool {
        alerts.activeAlert?.id == "videoInsert"
    }

    /// Whether the spot media sheet is currently showing
    var isShowingSpotMediaSheet: Bool {
        alerts.activeAlert?.id == "spotMedia"
    }

    // MARK: - Drop Handlers

    /// Handle video files dropped on the timeline video track
    func handleVideoDropOnTimeline(_ urls: [URL], _ atFrame: Int, _ isInternalDrag: Bool) {
        debugPrint("handleVideoDropOnTimeline: ENTRY with \(urls.count) URLs: \(urls.map { $0.lastPathComponent })")

        // Guard: Don't process new drops while timecode detection is in progress or a sheet is visible
        guard !isProcessingTimecodeDetection, !isShowingBatchTimecodeSheet, !isShowingEmbeddedTimecodeAlert, !isShowingSpotMediaSheet else {
            debugPrint("handleVideoDropOnTimeline: BLOCKED - isProcessing=\(isProcessingTimecodeDetection), showBatch=\(isShowingBatchTimecodeSheet), showSingle=\(isShowingEmbeddedTimecodeAlert), showSpot=\(isShowingSpotMediaSheet)")
            return
        }

        // Set flag synchronously before starting async work
        isProcessingTimecodeDetection = true
        debugPrint("handleVideoDropOnTimeline: Set isProcessingTimecodeDetection=true")

        Task { @MainActor in
            defer {
                // Clear processing flag when Task completes (unless a sheet is being shown)
                if !isShowingBatchTimecodeSheet, !isShowingEmbeddedTimecodeAlert, !isShowingSpotMediaSheet {
                    isProcessingTimecodeDetection = false
                }
            }

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

            // For multiple files, detect timecode for all files in parallel
            debugPrint("handleVideoDropOnTimeline: BATCH PATH - detecting timecode for \(newURLs.count) files")
            let items = await detectTimecodeForBatch(urls: newURLs)

            // If any file has embedded timecode, show batch sheet
            if items.contains(where: { $0.hasTimecode }) {
                await MainActor.run {
                    pendingBatchTimecode = PendingBatchTimecode(
                        items: items,
                        dropFrame: atFrame,
                        isVideo: true,
                        laneId: nil
                    )
                    showBatchTimecodeSheetViaCoordinator()
                }
            } else {
                // No timecodes found, add all files directly at sequential positions
                await addVideoFilesSequentially(urls: newURLs, startFrame: atFrame)
            }
        }
    }

    /// Handle audio files dropped on a specific audio lane
    func handleAudioDropOnTimeline(_ laneIndex: Int, _ urls: [URL], _ atFrame: Int, _ isInternalDrag: Bool) {
        // Guard: Only block if a sheet is actively visible (don't block on video processing flag)
        // Audio processing is independent of video timecode detection
        guard !isShowingBatchTimecodeSheet else {
            debugPrint("handleAudioDropOnTimeline: Batch sheet visible, ignoring drop")
            return
        }

        debugPrint("handleAudioDropOnTimeline: ENTRY - laneIndex=\(laneIndex), urls=\(urls.map { $0.lastPathComponent }), atFrame=\(atFrame)")

        // Defer state changes to avoid "Publishing changes from within view updates"
        DispatchQueue.main.async {
            Task { @MainActor in
                // Ensure the lane exists - create lanes until we have enough
                while self.timelineManager.timeline.audioLanes.count <= laneIndex {
                    debugPrint("handleAudioDropOnTimeline: Creating lane - current count: \(self.timelineManager.timeline.audioLanes.count), need index: \(laneIndex)")
                    // Registered so cancelling the placement dialog takes it
                    // away again. This is the path a plain audio drop takes -
                    // it creates lanes up to the dropped index - and it was the
                    // one creation site the rollback did not know about.
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

                // For multiple files, detect timecode for all files in parallel
                let items = await self.detectTimecodeForBatch(urls: urls)

                // If any file has embedded timecode, show batch sheet (if no other sheet is showing)
                if items.contains(where: { $0.hasTimecode }) {
                    // Check if another sheet is already showing
                    if self.isShowingEmbeddedTimecodeAlert || self.isShowingBatchTimecodeSheet {
                        // Another sheet is showing - auto-place audio at embedded timecode positions
                        debugPrint("handleAudioDropOnTimeline: Auto-placing at embedded timecode (another sheet is showing)")
                        await self.addAudioFilesAtEmbeddedTimecode(items: items, laneId: lane.id, fallbackFrame: atFrame)
                    } else {
                        self.pendingBatchTimecode = PendingBatchTimecode(
                            items: items,
                            dropFrame: atFrame,
                            isVideo: false,
                            laneId: lane.id
                        )
                        self.showBatchTimecodeSheetViaCoordinator()
                    }
                } else {
                    // No timecodes found, add all files directly at sequential positions
                    await self.addAudioFilesSequentially(urls: urls, laneId: lane.id, startFrame: atFrame)
                }

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
        // Guard: Don't process new drops while timecode detection is in progress or a sheet is visible
        guard !isProcessingTimecodeDetection, !isShowingBatchTimecodeSheet, !isShowingEmbeddedTimecodeAlert else {
            debugPrint("handleMixedBatchDrop: BLOCKED - processing=\(isProcessingTimecodeDetection) batchSheet=\(isShowingBatchTimecodeSheet) tcAlert=\(isShowingEmbeddedTimecodeAlert)")
            return
        }

        // Set flag synchronously before starting async work
        isProcessingTimecodeDetection = true

        Task { @MainActor in
            defer {
                // Clear processing flag when Task completes (unless a sheet is being shown)
                if !isShowingBatchTimecodeSheet, !isShowingEmbeddedTimecodeAlert {
                    isProcessingTimecodeDetection = false
                }
            }

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

            // If any file has embedded timecode, show batch sheet
            if allItems.contains(where: { $0.hasTimecode }) {
                await MainActor.run {
                    pendingBatchTimecode = PendingBatchTimecode(
                        items: allItems,
                        dropFrame: atFrame
                    )
                    showBatchTimecodeSheetViaCoordinator()
                }
            } else {
                // No timecodes found, add all files directly at sequential positions
                await addVideoFilesSequentially(urls: newVideoURLs, startFrame: atFrame)

                // Add audio files to their assigned lanes. Uses the
                // overlap-avoiding placement like the other batch paths: video
                // import creates its own embedded-audio lanes as it goes, so a
                // lane reserved here can already be occupied by the time we
                // place into it.
                debugPrint("handleMixedBatchDrop: placing \(allItems.filter { $0.mediaType == .audio }.count) audio item(s), no-timecode path")
                for item in allItems where item.mediaType == .audio {
                    guard let laneId = item.targetLaneId else {
                        debugPrint("handleMixedBatchDrop: '\(item.url.lastPathComponent)' has no targetLaneId, SKIPPED")
                        continue
                    }
                    let clip = await addAudioToTimelineAvoidingOverlap(
                        url: item.url,
                        preferredLaneId: laneId,
                        atFrame: atFrame
                    )
                    debugPrint("handleMixedBatchDrop: placed '\(item.url.lastPathComponent)' -> \(clip == nil ? "FAILED" : "ok")")
                }
                reservedAudioLaneIds.removeAll()
                batchCreatedLaneIds.removeAll()

                // Add padding after all files
                let paddingFrames = Int(TimelineLayout.defaultPaddingMinutes * 60.0 * timelineManager.timeline.config.frameRate.fps)
                if let lastReel = timelineManager.timeline.videoReels.last {
                    timelineManager.extendTimeline(toEndFrame: lastReel.timelineEndFrame + paddingFrames)
                }
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
        // Check for timecode if requested and not already handling a pending choice
        if checkTimecode, !isShowingEmbeddedTimecodeAlert, !isShowingBatchTimecodeSheet, !isShowingSpotMediaSheet, pendingSpotURL == nil {
            // If user has a remembered choice, use it directly
            if let rememberedChoice = rememberedSpotChoice {
                debugPrint("addVideoToTimeline: Using remembered spot choice: \(rememberedChoice)")
                await handleRememberedSpotChoice(
                    url: url,
                    choice: rememberedChoice,
                    atFrame: atFrame ?? 0
                )
                return
            }

            // Detect both filename and metadata timecode
            let filenameTC = detectTimecodeFromFilename(url.lastPathComponent)
            let metadataTC = await embeddedTimecodeService.detectTimecode(from: url, bookmark: nil)

            // If either timecode source is available, show spot dialog
            if filenameTC != nil || metadataTC != nil {
                debugPrint("addVideoToTimeline: Found timecode - filename=\(filenameTC ?? "nil"), metadata=\(metadataTC?.formattedTimecode ?? "nil")")
                await MainActor.run {
                    pendingSpotURL = url
                    pendingSpotFilenameTC = filenameTC
                    pendingSpotMetadataTC = metadataTC
                    pendingSpotDropFrame = atFrame ?? 0
                    pendingSpotIsVideo = true
                    pendingSpotLaneId = nil
                    showSpotMediaSheetViaCoordinator()
                }
                return
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

            isLoadingMedia = false
            debugPrint("addVideoToTimeline: READY FOR PLAYBACK [T+\(elapsed())]")

            // Generate thumbnail in background (non-blocking)
            let thumbnailCacheRef = thumbnailCache
            Task(priority: .utility) {
                thumbnailCacheRef.prewarm(for: reel)
            }

            // Extract audio in background and update the placeholder clip with extractedAudioURL
            if let (lane, clipId) = audioResult {
                Task(priority: .utility) {
                    await self.extractAudioInBackground(reel: reel, laneId: lane.id, clipId: clipId)
                }
            }
        } catch {
            debugPrint("addVideoToTimeline: FAILED [T+\(elapsed())] - \(error)")
            isLoadingMedia = false
            alerts.show(.error(error.localizedDescription))
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
        debugPrint("addAudioToTimeline: ENTRY - \(url.lastPathComponent), laneId=\(laneId), atFrame=\(atFrame ?? -1), checkTimecode=\(checkTimecode)")
        // Check for embedded timecode if requested and not already handling a pending choice
        if checkTimecode, !isShowingEmbeddedTimecodeAlert, !isShowingBatchTimecodeSheet, pendingTimecodeURL == nil {
            debugPrint("addAudioToTimeline: checking for embedded timecode...")
            if let result = await embeddedTimecodeService.detectTimecode(from: url, bookmark: nil) {
                debugPrint("addAudioToTimeline: Found embedded timecode! \(result.formattedTimecode)")
                // Found embedded timecode - store pending state and show alert
                await MainActor.run {
                    pendingTimecodeResult = result
                    pendingTimecodeURL = url
                    pendingTimecodeDropFrame = atFrame ?? 0
                    pendingTimecodeIsVideo = false
                    pendingTimecodeLaneId = laneId
                    showEmbeddedTimecodeAlertViaCoordinator()
                }
                return nil
            }
            debugPrint("addAudioToTimeline: no embedded timecode found, proceeding with add")
        } else {
            debugPrint("addAudioToTimeline: skipping timecode check (checkTimecode=\(checkTimecode), showAlert=\(isShowingEmbeddedTimecodeAlert), pendingURL=\(pendingTimecodeURL?.lastPathComponent ?? "nil"))")
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

    // MARK: - Embedded Timecode Detection

    /// Message for the embedded timecode detection alert
    var embeddedTimecodeMessage: String {
        guard let result = pendingTimecodeResult else {
            return "This file contains embedded timecode. Where would you like to place it?"
        }
        return "This file contains embedded timecode (\(result.formattedTimecode)) from \(result.source.rawValue). Where would you like to place it?"
    }

    /// Button label showing the detected timecode
    var embeddedTimecodeButtonLabel: String {
        guard let result = pendingTimecodeResult else {
            return "Place at Timecode"
        }
        return "Place at \(result.formattedTimecode)"
    }

    /// Handle user's choice for embedded timecode placement
    /// - Parameters:
    ///   - useEmbeddedTimecode: If true, place at the detected timecode position
    ///   - setTimelineStart: If true, also set the timeline's start timecode to match
    func handleTimecodeChoice(useEmbeddedTimecode: Bool, setTimelineStart: Bool) {
        guard let url = pendingTimecodeURL else {
            clearPendingTimecode()
            return
        }

        // Capture pending state before clearing
        let isVideo = pendingTimecodeIsVideo
        let laneId = pendingTimecodeLaneId
        let result = pendingTimecodeResult
        let dropFrame = pendingTimecodeDropFrame

        // Dismiss the sheet immediately so user doesn't see stale state
        alerts.dismiss()

        Task {
            var targetFrame: Int
            if useEmbeddedTimecode, let result = result {
                // Convert source timecode frames to timeline frames
                let timelineFPS = timelineManager.timeline.config.frameRate.fps
                targetFrame = result.convertedFrames(to: timelineFPS)

                // If user wants to set timeline start, update the config
                if setTimelineStart {
                    await MainActor.run {
                        var config = timelineManager.timeline.config
                        // Create a new start timecode matching the detected timecode
                        let startTC = Timecode(.frames(result.timecodeFrames), at: config.frameRate, by: .clamping)
                        config.startTimecode = startTC
                        // Adjust end timecode to maintain duration
                        let durationFrames = config.durationFrames
                        config.endTimecode = Timecode(.frames(result.timecodeFrames + durationFrames), at: config.frameRate, by: .clamping)
                        timelineManager.updateConfig(config)
                        debugPrint("handleTimecodeChoice: Set timeline start timecode to \(startTC.stringValue())")
                    }
                    // Place clip at frame 0 (timeline start) since timeline now starts at embedded timecode
                    targetFrame = 0
                }
            } else {
                // Use original drop location
                targetFrame = dropFrame ?? 0
            }

            if isVideo {
                // Pass checkTimecode: false to skip re-checking after user choice
                await addVideoToTimeline(url: url, atFrame: targetFrame, checkTimecode: false)

                // Add padding after the clip so users can easily drop more files
                // Add 20 minutes of padding at the timeline frame rate
                let paddingFrames = Int(TimelineLayout.defaultPaddingMinutes * 60.0 * timelineManager.timeline.config.frameRate.fps)
                if let lastReel = timelineManager.timeline.videoReels.last {
                    timelineManager.extendTimeline(toEndFrame: lastReel.timelineEndFrame + paddingFrames)
                }
            } else if let laneId = laneId {
                // Pass checkTimecode: false to skip re-checking after user choice
                _ = await addAudioToTimeline(url: url, laneId: laneId, atFrame: targetFrame, checkTimecode: false)

                // Add padding after the clip
                let paddingFrames = Int(TimelineLayout.defaultPaddingMinutes * 60.0 * timelineManager.timeline.config.frameRate.fps)
                if let lane = timelineManager.timeline.audioLanes.first(where: { $0.id == laneId }),
                   let lastClip = lane.clips.last {
                    timelineManager.extendTimeline(toEndFrame: lastClip.timelineEndFrame + paddingFrames)
                }
            }

            await MainActor.run {
                clearPendingTimecode()
            }
        }
    }

    /// Clear all pending timecode detection state and dismiss the sheet
    func clearPendingTimecode() {
        if isShowingEmbeddedTimecodeAlert {
            alerts.dismiss()
        }
        discardLanesCreatedForCancelledDrop()
        pendingTimecodeResult = nil
        pendingTimecodeURL = nil
        pendingTimecodeDropFrame = nil
        pendingTimecodeIsVideo = true
        pendingTimecodeLaneId = nil
        isProcessingTimecodeDetection = false
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

        for url in urls {
            // Skip duplicates
            if timelineManager.timeline.videoReels.contains(where: { $0.sourceURL == url }) {
                continue
            }

            await addVideoToTimeline(url: url, atFrame: currentFrame, checkTimecode: false)

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
    func addAudioFilesSequentially(urls: [URL], laneId: UUID, startFrame: Int) async {
        var currentFrame = startFrame

        for url in urls {
            if let clip = await addAudioToTimeline(url: url, laneId: laneId, atFrame: currentFrame, checkTimecode: false) {
                currentFrame = clip.timelineEndFrame
            }
        }

        // Add padding after all files
        let paddingFrames = Int(TimelineLayout.defaultPaddingMinutes * 60.0 * timelineManager.timeline.config.frameRate.fps)
        if let lane = timelineManager.timeline.audioLanes.first(where: { $0.id == laneId }),
           let lastClip = lane.clips.last {
            timelineManager.extendTimeline(toEndFrame: lastClip.timelineEndFrame + paddingFrames)
        }
    }

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
        let timelineFPS = timelineManager.timeline.config.frameRate.fps
        var nextSequentialFrame = fallbackFrame

        for item in items {
            let targetFrame: Int

            if item.hasTimecode, let result = item.detectedTimecode {
                // Place at embedded timecode position
                targetFrame = result.convertedFrames(to: timelineFPS)
                debugPrint("addAudioFilesAtEmbeddedTimecode: \(item.url.lastPathComponent) -> frame \(targetFrame) (from timecode)")
            } else {
                // Place at sequential position
                targetFrame = nextSequentialFrame
                debugPrint("addAudioFilesAtEmbeddedTimecode: \(item.url.lastPathComponent) -> frame \(targetFrame) (sequential)")
            }

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
    func handleBatchTimecodeConfirm(setTimelineStart: Bool) {
        guard let batch = pendingBatchTimecode else {
            clearPendingBatchTimecode()
            return
        }

        // Capture batch state before clearing
        let items = batch.items
        let dropFrame = batch.dropFrame
        let videoItems = batch.videoItems
        let audioItems = batch.audioItems

        // Debug: verify audio items received with targetLaneId
        debugPrint("handleBatchTimecodeConfirm: ENTRY - \(items.count) items, \(videoItems.count) video, \(audioItems.count) audio")
        for item in audioItems {
            debugPrint("  Audio item: \(item.url.lastPathComponent), targetLaneId=\(item.targetLaneId?.uuidString ?? "nil"), useTC=\(item.useEmbeddedTimecode)")
        }

        // Keep processing flag set and dismiss sheet
        // Note: isProcessingTimecodeDetection should already be true from drop handler
        alerts.dismiss()
        pendingBatchTimecode = nil

        Task {
            let timelineFPS = timelineManager.timeline.config.frameRate.fps

            // Handle setting timeline start if requested (only for first video file with timecode that's using it)
            var didSetTimelineStart = false
            if setTimelineStart, !videoItems.isEmpty {
                if let firstWithTC = videoItems.first(where: { $0.hasTimecode && $0.useEmbeddedTimecode }),
                   let result = firstWithTC.detectedTimecode {
                    await MainActor.run {
                        var config = timelineManager.timeline.config
                        let startTC = Timecode(.frames(result.timecodeFrames), at: config.frameRate, by: .clamping)
                        config.startTimecode = startTC
                        let durationFrames = config.durationFrames
                        config.endTimecode = Timecode(.frames(result.timecodeFrames + durationFrames), at: config.frameRate, by: .clamping)
                        timelineManager.updateConfig(config)
                        debugPrint("handleBatchTimecodeConfirm: Set timeline start to \(startTC.stringValue())")
                    }
                    didSetTimelineStart = true
                }
            }

            // Calculate first video timecode frames for relative positioning when timeline start is set
            var firstVideoTimecodeFrames: Int?
            if didSetTimelineStart,
               let firstWithTC = videoItems.first(where: { $0.hasTimecode && $0.useEmbeddedTimecode }),
               let firstResult = firstWithTC.detectedTimecode {
                firstVideoTimecodeFrames = firstResult.convertedFrames(to: timelineFPS)
            }

            // Process video items
            var nextVideoFrame = dropFrame
            for item in videoItems {
                let targetFrame: Int

                if item.useEmbeddedTimecode, let result = item.detectedTimecode {
                    let thisFrames = result.convertedFrames(to: timelineFPS)
                    if let firstFrames = firstVideoTimecodeFrames {
                        // Place relative to timeline start (frame 0)
                        targetFrame = thisFrames - firstFrames
                    } else {
                        targetFrame = thisFrames
                    }
                } else {
                    targetFrame = nextVideoFrame
                }

                // Skip duplicates
                if !timelineManager.timeline.videoReels.contains(where: { $0.sourceURL == item.url }) {
                    await addVideoToTimeline(url: item.url, atFrame: targetFrame, checkTimecode: false)

                    // Update sequential frame for next file
                    if let lastReel = timelineManager.timeline.videoReels.last(where: { $0.sourceURL == item.url }) {
                        nextVideoFrame = lastReel.timelineEndFrame
                    }
                }
            }

            // Process audio items - each goes to its own assigned lane
            for item in audioItems {
                guard let laneId = item.targetLaneId else {
                    debugPrint("handleBatchTimecodeConfirm: Audio item \(item.url.lastPathComponent) has no targetLaneId, skipping")
                    continue
                }

                let targetFrame: Int
                if item.useEmbeddedTimecode, let result = item.detectedTimecode {
                    let thisFrames = result.convertedFrames(to: timelineFPS)
                    if let firstFrames = firstVideoTimecodeFrames {
                        // Place relative to timeline start (frame 0) when video set the timeline start
                        targetFrame = thisFrames - firstFrames
                    } else {
                        targetFrame = thisFrames
                    }
                } else {
                    targetFrame = dropFrame
                }

                _ = await addAudioToTimelineAvoidingOverlap(url: item.url, preferredLaneId: laneId, atFrame: targetFrame)
            }

            // Add padding after all files
            let paddingFrames = Int(TimelineLayout.defaultPaddingMinutes * 60.0 * timelineFPS)
            var maxEndFrame = 0

            if let lastReel = timelineManager.timeline.videoReels.last {
                maxEndFrame = max(maxEndFrame, lastReel.timelineEndFrame)
            }
            for lane in timelineManager.timeline.audioLanes {
                if let lastClip = lane.clips.last {
                    maxEndFrame = max(maxEndFrame, lastClip.timelineEndFrame)
                }
            }

            if maxEndFrame > 0 {
                await MainActor.run {
                    timelineManager.extendTimeline(toEndFrame: maxEndFrame + paddingFrames)
                }
            }

            await MainActor.run {
                reservedAudioLaneIds.removeAll()
                batchCreatedLaneIds.removeAll()
                clearPendingBatchTimecode()
            }
        }
    }

    /// Clear all pending batch timecode state and dismiss the sheet
    func clearPendingBatchTimecode() {
        if isShowingBatchTimecodeSheet {
            alerts.dismiss()
        }
        discardLanesCreatedForCancelledDrop()
        reservedAudioLaneIds.removeAll()
        pendingBatchTimecode = nil
        isProcessingTimecodeDetection = false
    }

    /// Undo the lanes a drop created when the user cancels its dialog.
    ///
    /// Lanes have to exist before the dialog opens - placement needs a lane to
    /// target, and a batch needs lane identities to work out its ordering - but
    /// they are only *wanted* if the user confirms. Cancelling used to leave one
    /// empty lane per dropped file behind.
    ///
    /// Only empty lanes are removed, so a lane that has already received a clip
    /// is never destroyed by a later cancel.
    func discardLanesCreatedForCancelledDrop() {
        for laneId in batchCreatedLaneIds {
            guard let lane = timelineManager.timeline.audioLanes.first(where: { $0.id == laneId }),
                  lane.clips.isEmpty else { continue }
            timelineManager.removeAudioLane(id: laneId)
        }
        batchCreatedLaneIds.removeAll()
    }

    // MARK: - AlertCoordinator Helper Methods

    /// Show the embedded timecode alert via AlertCoordinator
    func showEmbeddedTimecodeAlertViaCoordinator() {
        guard let result = pendingTimecodeResult else { return }

        // Determine if we should show "Set as Timeline Start" option
        // Only show if timeline is empty OR the timeline's start timecode is still at 00:00:00:00
        let config = timelineManager.timeline.config
        let isTimelineEmpty = timelineManager.timeline.videoReels.isEmpty && timelineManager.timeline.audioLanes.allSatisfy { $0.clips.isEmpty }
        let isDefaultStart = config.startTimecode.frameCount.wholeFrames == 0
        let showSetTimelineStart = isTimelineEmpty || isDefaultStart

        alerts.show(.embeddedTimecode(
            result: result,
            showSetTimelineStart: showSetTimelineStart,
            onPlaceAtTimecode: { setTimelineStart in
                self.handleTimecodeChoice(useEmbeddedTimecode: true, setTimelineStart: setTimelineStart)
            },
            onPlaceAtDropLocation: {
                self.handleTimecodeChoice(useEmbeddedTimecode: false, setTimelineStart: false)
            },
            onCancel: {
                self.clearPendingTimecode()
            }
        ))
    }

    /// Show the batch timecode sheet via AlertCoordinator
    func showBatchTimecodeSheetViaCoordinator() {
        // Determine if we should show "Set as Timeline Start" option
        let config = timelineManager.timeline.config
        let isTimelineEmpty = timelineManager.timeline.videoReels.isEmpty && timelineManager.timeline.audioLanes.allSatisfy { $0.clips.isEmpty }
        let isDefaultStart = config.startTimecode.frameCount.wholeFrames == 0
        let showSetTimelineStart = isTimelineEmpty || isDefaultStart

        alerts.show(.batchTimecode(
            batch: $pendingBatchTimecode,
            showSetTimelineStart: showSetTimelineStart,
            onConfirm: { setTimelineStart in
                self.handleBatchTimecodeConfirm(setTimelineStart: setTimelineStart)
            },
            onCancel: {
                self.clearPendingBatchTimecode()
            }
        ))
    }

    /// Show the FPS conflict alert via AlertCoordinator
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

    // MARK: - Spot Media Sheet

    /// Show the spot media sheet via AlertCoordinator
    func showSpotMediaSheetViaCoordinator() {
        guard let url = pendingSpotURL else { return }

        // Determine if we should show "Set as Timeline Start" option
        let config = timelineManager.timeline.config
        let isTimelineEmpty = timelineManager.timeline.videoReels.isEmpty && timelineManager.timeline.audioLanes.allSatisfy { $0.clips.isEmpty }
        let isDefaultStart = config.startTimecode.frameCount.wholeFrames == 0
        let showSetTimelineStart = isTimelineEmpty || isDefaultStart

        // Get current playhead timecode
        let playheadFrame = playbackEngine.currentFrame
        let playheadTimecode = playbackEngine.currentTimecode.stringValue()

        alerts.show(.spotMedia(
            url: url,
            filenameTimecode: pendingSpotFilenameTC,
            metadataTimecode: pendingSpotMetadataTC,
            playheadTimecode: playheadTimecode,
            playheadFrame: playheadFrame,
            frameRate: config.frameRate,
            startTimecode: config.startTimecode,
            showSetTimelineStart: showSetTimelineStart,
            onSpot: { result in
                self.handleSpotResult(result)
            },
            onCancel: {
                self.clearPendingSpotMedia()
            }
        ))
    }

    /// Handle the result from the SpotMediaSheet
    func handleSpotResult(_ result: SpotResult) {
        Task { @MainActor in
            // Remember choice if requested
            if result.rememberChoice {
                rememberedSpotChoice = result.option
            }

            // Handle set timeline start if requested
            if result.setTimelineStart && pendingSpotIsVideo {
                // Calculate what the new timeline start should be
                let config = timelineManager.timeline.config
                let newStartTC = Timecode(.frames(result.targetFrame), at: config.frameRate, by: .clamping)
                var updatedConfig = config
                updatedConfig.startTimecode = newStartTC
                timelineManager.updateConfig(updatedConfig)
            }

            // Add the media
            if pendingSpotIsVideo {
                await addVideoToTimeline(url: result.url, atFrame: result.targetFrame, checkTimecode: false)
            } else if let laneId = pendingSpotLaneId {
                _ = await addAudioToTimeline(url: result.url, laneId: laneId, atFrame: result.targetFrame)
            }

            clearPendingSpotMedia()
        }
    }

    /// Handle a remembered spot choice without showing the dialog
    func handleRememberedSpotChoice(url: URL, choice: SpotPlacementOption, atFrame: Int) async {
        let config = timelineManager.timeline.config

        let targetFrame: Int
        switch choice {
        case .filename:
            if let tc = detectTimecodeFromFilename(url.lastPathComponent),
               let parsed = try? Timecode(.string(tc), at: config.frameRate, by: .clamping) {
                let startFrames = config.startTimecode.frameCount.wholeFrames
                targetFrame = max(0, parsed.frameCount.wholeFrames - startFrames)
            } else {
                // Fall back to drop frame if filename parsing fails
                targetFrame = atFrame
            }

        case .metadata:
            if let result = await embeddedTimecodeService.detectTimecode(from: url, bookmark: nil) {
                let startFrames = config.startTimecode.frameCount.wholeFrames
                let convertedFrames = result.convertedFrames(to: config.frameRate.fps)
                targetFrame = max(0, convertedFrames - startFrames)
            } else {
                // Fall back to drop frame if no metadata
                targetFrame = atFrame
            }

        case .manual:
            // Manual entry can't be "remembered" - fall back to playhead
            targetFrame = playbackEngine.currentFrame

        case .playhead:
            targetFrame = playbackEngine.currentFrame
        }

        await addVideoToTimeline(url: url, atFrame: targetFrame, checkTimecode: false)
    }

    /// Clear pending spot media state
    func clearPendingSpotMedia() {
        if isShowingSpotMediaSheet {
            alerts.dismiss()
        }
        discardLanesCreatedForCancelledDrop()
        pendingSpotURL = nil
        pendingSpotFilenameTC = nil
        pendingSpotMetadataTC = nil
        pendingSpotDropFrame = 0
        pendingSpotIsVideo = true
        pendingSpotLaneId = nil
        isProcessingTimecodeDetection = false
    }
}
