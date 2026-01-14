import SwiftUI
import AVFoundation
import SwiftTimecodeCore

// MARK: - Timeline Operations
extension ContentView {
    // MARK: - Drop Handlers

    /// Handle video files dropped on the timeline video track
    func handleVideoDropOnTimeline(_ urls: [URL], _ atFrame: Int, _ isInternalDrag: Bool) {
        Task {
            // Filter out duplicates first
            let newURLs = urls.filter { url in
                if timelineManager.timeline.videoReels.contains(where: { $0.sourceURL == url }) {
                    Task { @MainActor in
                        videoAlreadyInTimelineName = url.deletingPathExtension().lastPathComponent
                        showVideoAlreadyInTimelineAlert = true
                    }
                    return false
                }
                return true
            }

            guard !newURLs.isEmpty else { return }

            // For single file, use existing single-file flow
            if newURLs.count == 1 {
                await addVideoToTimeline(url: newURLs[0], atFrame: atFrame)
                return
            }

            // For multiple files, detect timecode for all files in parallel
            let items = await detectTimecodeForBatch(urls: newURLs)
            debugPrint("handleVideoDropOnTimeline: detectTimecodeForBatch returned \(items.count) items")
            for item in items {
                debugPrint("  - \(item.displayName): hasTC=\(item.hasTimecode), tc=\(item.detectedTimecode?.formattedTimecode ?? "none")")
            }

            // If any file has embedded timecode, show batch sheet
            if items.contains(where: { $0.hasTimecode }) {
                debugPrint("handleVideoDropOnTimeline: Showing batch sheet with \(items.count) items")
                await MainActor.run {
                    pendingBatchTimecode = PendingBatchTimecode(
                        items: items,
                        dropFrame: atFrame,
                        isVideo: true,
                        laneId: nil
                    )
                    debugPrint("handleVideoDropOnTimeline: pendingBatchTimecode set with \(pendingBatchTimecode?.items.count ?? 0) items")
                    showBatchTimecodeSheet = true
                }
            } else {
                // No timecodes found, add all files directly at sequential positions
                await addVideoFilesSequentially(urls: newURLs, startFrame: atFrame)
            }
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
                    _ = self.timelineManager.addAudioLane()
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
                        let paddingFrames = Int(20.0 * 60.0 * self.timelineManager.timeline.config.frameRate.fps)
                        self.timelineManager.extendTimeline(toEndFrame: clip.timelineEndFrame + paddingFrames)
                    }
                    return
                }

                // For multiple files, detect timecode for all files in parallel
                let items = await self.detectTimecodeForBatch(urls: urls)

                // If any file has embedded timecode, show batch sheet
                if items.contains(where: { $0.hasTimecode }) {
                    self.pendingBatchTimecode = PendingBatchTimecode(
                        items: items,
                        dropFrame: atFrame,
                        isVideo: false,
                        laneId: lane.id
                    )
                    self.showBatchTimecodeSheet = true
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

    // MARK: - Media Library Handlers

    /// Handle media item double-clicked to add to video track
    func handleAddToVideoTrack(_ item: MediaItem) {
        if timelineManager.timeline.videoReels.contains(where: { $0.sourceURL == item.url }) {
            videoAlreadyInTimelineName = item.displayName
            showVideoAlreadyInTimelineAlert = true
            return
        }

        videoInsertURL = item.url
        showVideoInsertSheet = true
    }

    /// Handle media item double-clicked to add to audio lane
    /// Creates a new audio lane and adds the audio there
    func handleAddToAudioLane(_ item: MediaItem, _ laneIndex: Int) {
        if timelineManager.timeline.audioLanes.contains(where: { lane in
            lane.clips.contains(where: { $0.sourceURL == item.url })
        }) {
            audioAlreadyInTimelineName = item.displayName
            showAudioAlreadyInTimelineAlert = true
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
        // Check for embedded timecode if requested and not already handling a pending choice
        if checkTimecode, !showEmbeddedTimecodeAlert, pendingTimecodeURL == nil {
            if let result = await embeddedTimecodeService.detectTimecode(from: url, bookmark: nil) {
                debugPrint("addVideoToTimeline: Found embedded timecode! \(result.formattedTimecode)")
                await MainActor.run {
                    pendingTimecodeResult = result
                    pendingTimecodeURL = url
                    pendingTimecodeDropFrame = atFrame ?? 0
                    pendingTimecodeIsVideo = true
                    pendingTimecodeLaneId = nil
                    showEmbeddedTimecodeAlert = true
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
                showFPSConflictAlert = true
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
            loadError = error.localizedDescription
            showErrorAlert = true
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
            loadError = error.localizedDescription
            showErrorAlert = true
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
        if checkTimecode, !showEmbeddedTimecodeAlert, pendingTimecodeURL == nil {
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
                    showEmbeddedTimecodeAlert = true
                }
                return nil
            }
            debugPrint("addAudioToTimeline: no embedded timecode found, proceeding with add")
        } else {
            debugPrint("addAudioToTimeline: skipping timecode check (checkTimecode=\(checkTimecode), showAlert=\(showEmbeddedTimecodeAlert), pendingURL=\(pendingTimecodeURL?.lastPathComponent ?? "nil"))")
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
            loadError = error.localizedDescription
            showErrorAlert = true
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

            // Try to find an existing lane where the clip fits without overlap
            var targetLane: AudioLane?
            for lane in timelineManager.timeline.audioLanes {
                if !lane.hasOverlap(with: clip) {
                    targetLane = lane
                    debugPrint("prepareAudioLaneIfNeeded: Found existing lane '\(lane.name)' with no overlap")
                    break
                }
            }

            // If no existing lane can fit the clip, create a new one
            if targetLane == nil {
                let laneNumber = timelineManager.timeline.audioLanes.count + 1
                targetLane = timelineManager.addAudioLaneAtTop(name: "Audio \(laneNumber)")
                debugPrint("prepareAudioLaneIfNeeded: Created new lane '\(targetLane!.name)'")
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
        showEmbeddedTimecodeAlert = false

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
                let paddingFrames = Int(20.0 * 60.0 * timelineManager.timeline.config.frameRate.fps)
                if let lastReel = timelineManager.timeline.videoReels.last {
                    timelineManager.extendTimeline(toEndFrame: lastReel.timelineEndFrame + paddingFrames)
                }
            } else if let laneId = laneId {
                // Pass checkTimecode: false to skip re-checking after user choice
                _ = await addAudioToTimeline(url: url, laneId: laneId, atFrame: targetFrame, checkTimecode: false)

                // Add padding after the clip
                let paddingFrames = Int(20.0 * 60.0 * timelineManager.timeline.config.frameRate.fps)
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
        showEmbeddedTimecodeAlert = false
        pendingTimecodeResult = nil
        pendingTimecodeURL = nil
        pendingTimecodeDropFrame = nil
        pendingTimecodeIsVideo = true
        pendingTimecodeLaneId = nil
    }

    // MARK: - Batch Timecode Detection

    /// Detect embedded timecode for multiple files in parallel
    /// - Parameter urls: Array of file URLs to check
    /// - Returns: Array of BatchTimecodeItem with detected timecodes
    func detectTimecodeForBatch(urls: [URL]) async -> [BatchTimecodeItem] {
        await withTaskGroup(of: BatchTimecodeItem.self, returning: [BatchTimecodeItem].self) { group in
            for url in urls {
                group.addTask {
                    let result = await self.embeddedTimecodeService.detectTimecode(from: url, bookmark: nil)
                    return BatchTimecodeItem(url: url, detectedTimecode: result)
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
        let paddingFrames = Int(20.0 * 60.0 * timelineManager.timeline.config.frameRate.fps)
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
        let paddingFrames = Int(20.0 * 60.0 * timelineManager.timeline.config.frameRate.fps)
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

        // Capture batch and dismiss sheet immediately
        let items = batch.items
        let dropFrame = batch.dropFrame
        let isVideo = batch.isVideo
        let laneId = batch.laneId

        showBatchTimecodeSheet = false

        Task {
            // Handle setting timeline start if requested (only for first file with timecode that's using it)
            var didSetTimelineStart = false
            if setTimelineStart, isVideo {
                if let firstWithTC = items.first(where: { $0.hasTimecode && $0.useEmbeddedTimecode }),
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

            // Process each file according to user's choice
            var nextSequentialFrame = dropFrame

            for item in items {
                let targetFrame: Int

                if item.useEmbeddedTimecode, let result = item.detectedTimecode {
                    // Place at embedded timecode position
                    let timelineFPS = timelineManager.timeline.config.frameRate.fps
                    if didSetTimelineStart {
                        // Timeline start was set to first file's TC, so place relative to timeline start (frame 0)
                        if let firstWithTC = items.first(where: { $0.hasTimecode && $0.useEmbeddedTimecode }),
                           let firstResult = firstWithTC.detectedTimecode {
                            // Calculate offset from first file's timecode
                            let firstFrames = firstResult.convertedFrames(to: timelineFPS)
                            let thisFrames = result.convertedFrames(to: timelineFPS)
                            targetFrame = thisFrames - firstFrames
                        } else {
                            targetFrame = result.convertedFrames(to: timelineFPS)
                        }
                    } else {
                        targetFrame = result.convertedFrames(to: timelineFPS)
                    }
                } else {
                    // Place at sequential position (drop frame or after previous clip)
                    targetFrame = nextSequentialFrame
                }

                if isVideo {
                    // Skip duplicates
                    if !timelineManager.timeline.videoReels.contains(where: { $0.sourceURL == item.url }) {
                        await addVideoToTimeline(url: item.url, atFrame: targetFrame, checkTimecode: false)

                        // Update sequential frame for next file
                        if let lastReel = timelineManager.timeline.videoReels.last(where: { $0.sourceURL == item.url }) {
                            nextSequentialFrame = lastReel.timelineEndFrame
                        }
                    }
                } else if let laneId = laneId {
                    if let clip = await addAudioToTimeline(url: item.url, laneId: laneId, atFrame: targetFrame, checkTimecode: false) {
                        nextSequentialFrame = clip.timelineEndFrame
                    }
                }
            }

            // Add padding after all files
            let paddingFrames = Int(20.0 * 60.0 * timelineManager.timeline.config.frameRate.fps)
            if isVideo {
                if let lastReel = timelineManager.timeline.videoReels.last {
                    await MainActor.run {
                        timelineManager.extendTimeline(toEndFrame: lastReel.timelineEndFrame + paddingFrames)
                    }
                }
            } else if let laneId = laneId {
                if let lane = timelineManager.timeline.audioLanes.first(where: { $0.id == laneId }),
                   let lastClip = lane.clips.last {
                    await MainActor.run {
                        timelineManager.extendTimeline(toEndFrame: lastClip.timelineEndFrame + paddingFrames)
                    }
                }
            }

            await MainActor.run {
                clearPendingBatchTimecode()
            }
        }
    }

    /// Clear all pending batch timecode state and dismiss the sheet
    func clearPendingBatchTimecode() {
        showBatchTimecodeSheet = false
        pendingBatchTimecode = nil
    }
}
