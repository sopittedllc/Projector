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
        beginImportUndo()

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
                frameImportedContent()
                return
            }

            // Files carrying timecode go to it; the rest are laid end to end
            // from the drop. `addVideoToTimeline` resolves each file's own
            // timecode, so this only needs to handle the ones without.
            debugPrint("handleVideoDropOnTimeline: BATCH PATH - \(newURLs.count) files")
            await addVideoFilesSequentially(urls: newURLs, startFrame: atFrame)
            frameImportedContent()
        }
    }

    /// Handle audio files dropped on a specific audio lane
    func handleAudioDropOnTimeline(_ laneIndex: Int, _ urls: [URL], _ atFrame: Int, _ isInternalDrag: Bool) {
        debugPrint("handleAudioDropOnTimeline: ENTRY - laneIndex=\(laneIndex), urls=\(urls.map { $0.lastPathComponent }), atFrame=\(atFrame)")

        beginImportUndo()

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
                    self.frameImportedContent()
                    return
                }

                // Each file goes to its own timecode, or after the last one.
                let items = await self.detectTimecodeForBatch(urls: urls, mediaType: .audio)
                await self.addAudioFilesAtEmbeddedTimecode(items: items, laneId: lane.id, fallbackFrame: atFrame)
                self.frameImportedContent()

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
    /// This is the handler that invents destinations: reels go along the video
    /// track, and audio is grouped by the stem its name declares so a delivery
    /// cut into reels lands on one lane per stem rather than one lane per file.
    ///
    /// Only files that carry timecode are placed. Anything that does not say
    /// where it belongs is added to the media panel and named in one report -
    /// see ``holdBackFilesWithoutTimecode(videoURLs:audioURLs:)`` for why.
    ///
    /// - Parameters:
    ///   - videoURLs: Array of video file URLs
    ///   - audioURLs: Array of audio file URLs
    ///   - atFrame: Where the drop landed. Reached only by the single-file
    ///     paths; a batch places every file at the timecode it names.
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
        beginImportUndo()

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

            // Only files that say where they belong are placed. The rest go to
            // the media panel and are named in one report.
            //
            // This handler is the one that *invents* destinations - a lane per
            // stem for the audio, a running position for the reels - so it is
            // the one with nothing to go on when a file carries no timecode. A
            // drop that names a lane or a frame is an instruction and is still
            // honoured; see `handleAudioDropOnTimeline`.
            //
            // Placing them anyway is what the report that prompted this looked
            // like: a picture turnover with no `tmcd` on the reels and no `bext`
            // on the stems laid out from the drop, giving a timeline that looks
            // finished and is silently wrong - and, because same-frame files
            // spill onto lanes of their own, one lane per file into the bargain.
            let (placeableVideoURLs, placeableAudioURLs) = await holdBackFilesWithoutTimecode(
                videoURLs: newVideoURLs,
                audioURLs: newAudioURLs
            )

            guard !placeableVideoURLs.isEmpty || !placeableAudioURLs.isEmpty else {
                debugPrint("handleMixedBatchDrop: nothing carried timecode, all held in Media")
                return
            }

            // For single video + no audio, use existing single-file flow
            if placeableVideoURLs.count == 1 && placeableAudioURLs.isEmpty {
                await addVideoToTimeline(url: placeableVideoURLs[0], atFrame: atFrame)
                frameImportedContent()
                return
            }

            // For single audio + no video, use existing single-file flow with new lane
            if placeableAudioURLs.count == 1 && placeableVideoURLs.isEmpty {
                let newLane = timelineManager.addAudioLane(name: laneName(for: placeableAudioURLs[0]))
                batchCreatedLaneIds.insert(newLane.id)
                let clip = await addAudioToTimeline(url: placeableAudioURLs[0], laneId: newLane.id, atFrame: atFrame)
                if let clip = clip {
                    let paddingFrames = Int(TimelineLayout.defaultPaddingMinutes * 60.0 * timelineManager.timeline.config.frameRate.fps)
                    timelineManager.extendTimeline(toEndFrame: clip.timelineEndFrame + paddingFrames)
                }
                frameImportedContent()
                return
            }

            // IMPORTANT: Reserve lanes for video embedded audio FIRST
            // Each video may have an audio track that needs its own lane
            // We create placeholder lanes now so standalone audio files get assigned to subsequent lanes
            var allItems: [BatchTimecodeItem] = []
            for url in placeableVideoURLs {
                let lane = timelineManager.addAudioLane(name: laneName(for: url))
                batchCreatedLaneIds.insert(lane.id)
            }

            // Detect timecode for audio files and create a lane per stem.
            // These lanes come AFTER the video audio lanes.
            //
            // A reel-based delivery is one file per reel per stem: five reels
            // hand over five DX_FX files and five MX files. One lane per file
            // made ten lanes of one clip each, when the material is two stems
            // cut into reels - so files whose names declare the same stem share
            // a lane, and the reels sit end to end along it. Anything with no
            // stem in its name still gets a lane to itself.
            for group in AudioStemGrouping.groups(for: placeableAudioURLs) {
                // The stem names the lane only when it actually collects
                // several files; a lone file keeps the filename it has always
                // been given, since there is no grouping to explain.
                guard let firstURL = group.urls.first else { continue }
                let name = (group.urls.count > 1 ? group.stem?.displayName : nil)
                    ?? laneName(for: firstURL)
                let newLane = timelineManager.addAudioLane(name: name)
                batchCreatedLaneIds.insert(newLane.id)
                reservedAudioLaneIds.insert(newLane.id)

                for url in group.urls {
                    let result = await embeddedTimecodeService.detectTimecode(from: url, bookmark: nil)
                    var item = BatchTimecodeItem(url: url, mediaType: .audio, detectedTimecode: result)
                    item.targetLaneId = newLane.id
                    allItems.append(item)
                    debugPrint("handleMixedBatchDrop: assigned '\(url.lastPathComponent)' -> lane '\(newLane.name)' (\(newLane.id.uuidString.prefix(8))), tc=\(result?.formattedTimecode ?? "none")")
                }
            }

            // Place everything, no questions asked. Every file here carries
            // timecode - the ones that did not were held back above - so each
            // one goes to the timecode it names and `atFrame` is never reached.
            await addVideoFilesSequentially(urls: placeableVideoURLs, startFrame: atFrame)

            // Audio to its assigned lane. Uses the overlap-avoiding placement:
            // video import creates its own embedded-audio lanes as it goes, so a
            // lane reserved here can already be occupied by the time we place.
            debugPrint("handleMixedBatchDrop: placing \(allItems.filter { $0.mediaType == .audio }.count) audio item(s)")
            var overlapping: [URL] = []
            for item in allItems where item.mediaType == .audio {
                guard let laneId = item.targetLaneId else {
                    debugPrint("handleMixedBatchDrop: '\(item.url.lastPathComponent)' has no targetLaneId, SKIPPED")
                    continue
                }
                let target = placementFrame(metadata: item.detectedTimecode, dropFrame: atFrame)
                switch await addAudioToTimelineAvoidingOverlap(
                    url: item.url,
                    preferredLaneId: laneId,
                    atFrame: target
                ) {
                case .placed:
                    debugPrint("handleMixedBatchDrop: placed '\(item.url.lastPathComponent)' at \(target)")
                case .laneOccupied:
                    overlapping.append(item.url)
                case .failed:
                    alerts.show(.error("Couldn't add \"\(item.url.lastPathComponent)\" to the timeline."))
                }
            }
            reservedAudioLaneIds.removeAll()

            // Held back rather than given a lane of their own, so a stem keeps
            // one lane however badly the delivery is stamped.
            await holdBack(urls: overlapping, reason: .timecodeAlreadyOccupied)

            // A stem lane whose every file collided has nothing on it.
            discardEmptyLanesCreatedForDrop()

            // Add padding after all files
            let paddingFrames = Int(TimelineLayout.defaultPaddingMinutes * 60.0 * timelineManager.timeline.config.frameRate.fps)
            if let lastReel = timelineManager.timeline.videoReels.last {
                timelineManager.extendTimeline(toEndFrame: lastReel.timelineEndFrame + paddingFrames)
            }

            frameImportedContent()
        }
    }

    // MARK: - Holding Back Files That Say Nothing

    /// Splits a dropped batch into the files that say where they belong and the
    /// files that do not, adding the latter to the media panel and reporting
    /// them in one alert.
    ///
    /// ## Why a file is held back rather than placed
    ///
    /// A file with no timecode gives the app nothing to place it against, and
    /// the answers available are all guesses: the drop position, or after
    /// whatever landed last. A guess produces a timeline that looks finished and
    /// is quietly wrong - a stem shorter than its reel drags every later reel on
    /// its lane early, with nothing on screen to say so - and, because files
    /// guessed onto the same frames of the same lane spill onto lanes of their
    /// own, a lane per file into the bargain. The media panel is where a file
    /// with no home belongs until someone says where it goes.
    ///
    /// ## What counts as saying where it belongs
    ///
    /// Embedded timecode for anything, plus a timecode in the *name* for video,
    /// because that is exactly what `addVideoFilesSequentially` will place a
    /// video by. Audio deliberately does not count a filename timecode: nothing
    /// on the audio placement path reads one, so counting it here would let a
    /// file through to be placed at the drop position after all.
    ///
    /// - Parameters:
    ///   - videoURLs: Deduplicated video files from the drop.
    ///   - audioURLs: Deduplicated audio files from the drop.
    /// - Returns: The files that can be placed, in the order they were dropped.
    func holdBackFilesWithoutTimecode(
        videoURLs: [URL],
        audioURLs: [URL]
    ) async -> (video: [URL], audio: [URL]) {
        var placeableVideo: [URL] = []
        var placeableAudio: [URL] = []
        // Held as URLs, not names: two reels delivered in different folders can
        // share a filename, and the media import below has to know which file it
        // is importing.
        var heldBack: [URL] = []

        for url in videoURLs {
            let embedded = await embeddedTimecodeService.detectTimecode(from: url, bookmark: nil)
            let fromName = detectTimecodeFromFilename(url.lastPathComponent)
            if embedded != nil || fromName != nil {
                placeableVideo.append(url)
            } else {
                heldBack.append(url)
            }
        }

        for url in audioURLs {
            if await embeddedTimecodeService.detectTimecode(from: url, bookmark: nil) != nil {
                placeableAudio.append(url)
            } else {
                heldBack.append(url)
            }
        }

        await holdBack(urls: heldBack, reason: .noTimecode)
        return (placeableVideo, placeableAudio)
    }

    /// Put files in the media panel instead of on the timeline, and say so.
    ///
    /// Called from every point an import decides it cannot place something, so
    /// there is one answer to "where did my file go" and one alert whatever the
    /// reason. Does nothing when there is nothing to report.
    ///
    /// - Parameters:
    ///   - urls: The files to hold back.
    ///   - reason: Why, which is what the alert groups them under.
    func holdBack(urls: [URL], reason: ImportHoldBackReason) async {
        guard !urls.isEmpty else { return }

        // Into the media panel, which is the whole point of holding them back:
        // the files are imported and findable, they are simply not on the
        // timeline. Placement imports the files it places itself, so this is the
        // only import the held-back ones get.
        for url in urls {
            do {
                _ = try await mediaLibrary.importFile(from: url)
            } catch {
                debugPrint("holdBack: '\(url.lastPathComponent)' could not be added to Media - \(error.localizedDescription)")
            }
        }

        debugPrint("holdBack: held \(urls.count) file(s), reason=\(reason)")
        alerts.show(.filesNotPlaced(files: urls.map {
            HeldBackFile(name: $0.lastPathComponent, reason: reason)
        }))
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

        beginImportUndo()

        Task {
            // Create a new audio lane for this audio file
            let laneNumber = timelineManager.timeline.audioLanes.count + 1
            let newLane = timelineManager.addAudioLane(name: "Audio \(laneNumber)")

            _ = await addAudioToTimeline(url: item.url, laneId: newLane.id, atFrame: 0)

            // Auto-expand timeline so user can see the new lane
            timelineViewModel.expandIfNeeded()
            frameImportedContent()
        }
    }

    // MARK: - Video Timeline Operations

    /// Add a video file to the timeline with optional timecode check
    /// - Parameters:
    ///   - url: Video file URL
    ///   - atFrame: Target frame position (nil = auto-place at end)
    ///   - checkTimecode: Whether to check for embedded timecode and prompt user
    func addVideoToTimeline(url: URL, atFrame: Int?, checkTimecode: Bool = true) async {
        // Read the video's timecode now, resolve it to a frame later. A frame
        // number only means something against a frame rate, and this import may
        // be about to set the timeline's - so resolving here would answer in the
        // outgoing rate and land the reel in the wrong place.
        //
        // `checkTimecode: false` means a caller has already resolved the frame
        // and is passing it in, so leave its answer alone.
        var placement = PendingVideoPlacement(dropFrame: atFrame)
        if checkTimecode {
            placement.filenameTimecode = detectTimecodeFromFilename(url.lastPathComponent)
            placement.metadata = await embeddedTimecodeService.detectTimecode(from: url, bookmark: nil)
        }

        isLoadingMedia = true

        do {
            // Detect video frame rate and duration first
            let asset = AVAsset(url: url)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let videoTrack = videoTracks.first else {
                throw NSError(domain: "Projector", code: 1, userInfo: [NSLocalizedDescriptionKey: "No video track found"])
            }

            // Probed before placement but reported after it. A reel whose codec is
            // missing still has valid timecode, duration and frame rate, so it is
            // placed normally and the audio can be laid against it; interrupting here
            // would cost the user that while changing nothing about the outcome.
            let codecSupport = try? await VideoCodecSupport.inspect(asset)

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
                pendingVideoPlacement = placement
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
                config.setFrameRate(videoFPS)
                timelineManager.updateConfig(config)
            }

            // Resolve placement only now, against the rate the timeline has
            // settled on.
            var placementFrame = resolvedPlacementFrame(placement, for: url)
            placementFrame = findNonOverlappingPosition(
                startFrame: placementFrame,
                durationFrames: videoDurationFrames,
                existingReels: timelineManager.timeline.videoReels
            )

            await addVideoToTimelineUnchecked(url: url, at: placementFrame)

            if let codecSupport, !codecSupport.isDecodable {
                presentCodecUnavailable(codecSupport)
            }

        } catch {
            isLoadingMedia = false
            alerts.show(.error(error.localizedDescription))
            // A file that never imported still has to leave the batch.
            splitHardPannedReelsIfBatchComplete(candidate: nil)
        }
    }

    /// Reports a failure, unless it is simply a codec with no decoder.
    ///
    /// A missing decoder is already reported by name, with the fix attached, and the
    /// video area keeps saying so for as long as the reel is loaded. Adding the generic
    /// "The video file cannot be played." on top of that told the user strictly less,
    /// twice - and arrived first, so the vaguer message was the one they read.
    ///
    /// Every other error still surfaces: this narrows one case rather than silencing
    /// the catch.
    ///
    /// - Parameter error: The error to report.
    func showUnlessMissingDecoder(_ error: Error) {
        if let engineError = error as? PlaybackEngineError,
           case .notPlayable = engineError {
            return
        }
        alerts.show(.error(error.localizedDescription))
    }

    /// Tells the user a reel's codec cannot be decoded, and offers the fix when there
    /// is one.
    ///
    /// Apple's Pro Video Formats package is only offered for codecs it actually
    /// supplies. Anything else gets a plain statement of the problem rather than an
    /// install that would not help.
    ///
    /// - Parameter support: What the codec probe found.
    func presentCodecUnavailable(_ support: CodecSupport) {
        guard support.shouldOfferProVideoFormatsInstall else {
            alerts.show(.error(
                "This Mac has no decoder for \(support.displayName), so this reel's "
                + "picture cannot be shown. Its timecode and duration are still correct."
            ))
            return
        }

        alerts.show(.codecUnavailable(codecName: support.displayName) {
            alerts.show(.proVideoFormatsInstall(codecName: support.displayName))
        })
    }

    /// Find a position for a new video that doesn't cover an existing reel.
    ///
    /// The rule lives in ``ReelPlacement`` so it can be unit-tested; this is the
    /// adapter from the timeline's reels to it.
    ///
    /// - Parameters:
    ///   - startFrame: Where the reel's timecode puts it.
    ///   - durationFrames: The reel's length.
    ///   - existingReels: What is already on the video track.
    /// - Returns: A start frame at or after `startFrame` where the reel fits.
    func findNonOverlappingPosition(startFrame: Int, durationFrames: Int, existingReels: [VideoReel]) -> Int {
        let occupied = existingReels.map { $0.timelineStartFrame ..< $0.timelineEndFrame }
        let resolved = ReelPlacement.firstFreeStart(
            preferredStart: startFrame,
            durationFrames: durationFrames,
            occupied: occupied
        )
        if resolved != startFrame {
            debugPrint("findNonOverlappingPosition: frame \(startFrame) was taken; using \(resolved)")
        }
        return resolved
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

            // Check for audio tracks and create lanes + placeholder clips for ALL tracks
            // This ensures audio regions appear in UI right away, before extraction completes
            let audioResults = await prepareAudioLanesForAllTracks(for: reel)
            debugPrint("addVideoToTimeline: Audio lanes + clips prepared (\(audioResults.count) tracks) [T+\(elapsed())]")

            // The placeholder clips exist by now, so the lanes can be identified
            // and routed from the video's name.
            applyNamedOutputToVideoAudio(for: url)

            isLoadingMedia = false
            debugPrint("addVideoToTimeline: READY FOR PLAYBACK [T+\(elapsed())]")

            // Generate thumbnail in background (non-blocking)
            let thumbnailCacheRef = thumbnailCache
            Task(priority: .utility) {
                thumbnailCacheRef.prewarm(for: reel)
            }

            // Handle background work for audio tracks
            guard !audioResults.isEmpty else {
                // Still reports, so a batch waiting on this file is not left
                // one short and held open forever.
                splitHardPannedReelsIfBatchComplete(candidate: nil)
                return
            }

            // For tracks 1+, extract in background and update extractedAudioURL
            // Track 0 plays directly from the video container (no extraction needed)
            for result in audioResults where result.trackIndex > 0 {
                Task(priority: .utility) {
                    do {
                        let extractedURL = try await AudioTrackExtractor.extractTrack(
                            from: reel.sourceURL,
                            trackIndex: result.trackIndex,
                            clipId: result.clipId
                        )
                        await MainActor.run {
                            self.timelineManager.updateExtractedAudioURL(
                                clipId: result.clipId,
                                url: extractedURL
                            )
                            self.playbackEngine.invalidateAudioClip(id: result.clipId)
                        }
                        debugPrint("addVideoToTimeline: Extracted track \(result.trackIndex) for \(reel.displayName)")
                    } catch {
                        debugPrint("addVideoToTimeline: Failed to extract track \(result.trackIndex): \(error)")
                    }
                }
            }

            // Only track 0 is analyzed for hard panning (it's the primary audio track)
            if let firstResult = audioResults.first(where: { $0.trackIndex == 0 }) {
                Task(priority: .utility) {
                    // Track 0 plays directly from the reel - check for hard panning
                    let analysis = await Self.hardPanningAnalysis(of: reel.sourceURL)
                    await self.reportSplitCandidate(
                        reel: reel,
                        laneId: firstResult.lane.id,
                        clipId: firstResult.clipId,
                        analysis: analysis
                    )
                }
            } else {
                // No track 0 somehow, still report to batch
                splitHardPannedReelsIfBatchComplete(candidate: nil)
            }
        } catch {
            debugPrint("addVideoToTimeline: FAILED [T+\(elapsed())] - \(error)")
            isLoadingMedia = false
            showUnlessMissingDecoder(error)
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
        config.setFrameRate(fps)
        timelineManager.updateConfig(config)

        // Clear pending state
        pendingVideoURL = nil
        pendingVideoFPS = nil
        let placement = pendingVideoPlacement
        pendingVideoPlacement = nil

        // Resolve placement only now: the reel's timecode addresses the timeline
        // that exists after the rate change, not the one that existed when the
        // conflict was raised.
        Task {
            let frame = placement.map { resolvedPlacementFrame($0, for: url) } ?? 0
            await addVideoToTimelineUnchecked(url: url, at: frame)
        }
    }

    /// Convert a measured video frame rate to the closest timecode rate.
    ///
    /// Delegates to ``TimecodeFrameRate/nearest(to:tolerance:)`` so this and
    /// the import path cannot disagree. This copy searched a hardcoded five
    /// rates, which silently had no answer for 48, 50 or 60 fps media.
    ///
    /// - Parameter fps: Measured frame rate.
    /// - Returns: The nearest timecode rate, defaulting to 24 fps when the
    ///   measurement is not close to any of them.
    func closestTimecodeFrameRate(to fps: Double) -> TimecodeFrameRate {
        TimecodeFrameRate.nearest(to: fps) ?? .fps24
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

    /// Result from preparing audio lanes for a video reel.
    struct AudioTrackResult {
        let lane: AudioLane
        let clipId: UUID
        let trackIndex: Int
    }

    /// Check if video has audio tracks and create lanes + placeholder clips for each.
    ///
    /// Creates one lane per audio track, each with its own clip. Track 0 plays directly
    /// from the video container; tracks 1+ require background extraction to separate
    /// CAF files before playback.
    ///
    /// - Parameter reel: The video reel to check for audio tracks.
    /// - Returns: Array of results, one per audio track. Empty if no audio tracks.
    private func prepareAudioLanesForAllTracks(for reel: VideoReel) async -> [AudioTrackResult] {
        let asset = AVAsset(url: reel.sourceURL)
        do {
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard !audioTracks.isEmpty else {
                debugPrint("prepareAudioLanesForAllTracks: No audio tracks found")
                return []
            }

            var results: [AudioTrackResult] = []

            for (trackIndex, audioTrack) in audioTracks.enumerated() {
                // Get channel count and sample rate from audio format
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

                // Determine lane name: first track gets the video name, others get Track N suffix
                let trackName: String
                if audioTracks.count == 1 {
                    trackName = laneName(for: reel.sourceURL)
                } else {
                    let baseName = reel.sourceURL.deletingPathExtension().lastPathComponent
                    trackName = "\(baseName) - Track \(trackIndex + 1)"
                }

                // Create a placeholder clip IMMEDIATELY (without extractedAudioURL for tracks 1+)
                // Track 0 plays directly from the video; tracks 1+ need extraction
                let clip = AudioClip(
                    mediaItemId: reel.mediaItemId,
                    sourceURL: reel.sourceURL,
                    sourceBookmark: reel.sourceBookmark,
                    timelineStartFrame: reel.timelineStartFrame,
                    durationFrames: reel.durationFrames,
                    sourceStartFrame: reel.sourceStartFrame,
                    sourceType: .videoTrack,
                    sourceTrackIndex: trackIndex,
                    channelCount: channelCount,
                    sampleRate: sampleRate,
                    extractedAudioURL: nil,  // Will be set after extraction for tracks 1+
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
                        debugPrint("prepareAudioLanesForAllTracks: Found existing lane '\(lane.name)' with no overlap for track \(trackIndex)")
                        break
                    }
                }

                // If no existing lane can fit the clip, create a new one
                if targetLane == nil {
                    targetLane = timelineManager.addAudioLaneAtTop(name: trackName)
                    debugPrint("prepareAudioLanesForAllTracks: Created new lane '\(targetLane!.name)' for track \(trackIndex)")
                } else if let adopted = targetLane,
                          adopted.clips.isEmpty,
                          isGenericLaneName(adopted.name) {
                    // Adopting an empty, never-named lane: give it the track's name
                    timelineManager.renameAudioLane(id: adopted.id, name: trackName)
                    targetLane = timelineManager.timeline.audioLanes.first { $0.id == adopted.id }
                    debugPrint("prepareAudioLanesForAllTracks: renamed adopted lane '\(adopted.name)' -> '\(trackName)'")
                }

                guard let lane = targetLane else {
                    debugPrint("prepareAudioLanesForAllTracks: Failed to get target lane for track \(trackIndex)")
                    continue
                }

                timelineManager.timeline.addClip(clip, toLane: lane.id)
                results.append(AudioTrackResult(lane: lane, clipId: clip.id, trackIndex: trackIndex))
            }

            debugPrint("prepareAudioLanesForAllTracks: Created \(results.count) clips from \(audioTracks.count) audio track(s)")
            return results
        } catch {
            debugPrint("prepareAudioLanesForAllTracks: Failed to check audio tracks - \(error)")
            return []
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

        performChannelSplits(for: batch)
    }

    /// Name the output each split lane is already feeding.
    ///
    /// A lane with no mapping is not silent - the engine falls back to the
    /// channel offset and count the lane carries, which is the first stereo pair
    /// by default. The menu reads that as "NONE" while the sound comes out of an
    /// output the user was never told about, so a lane always ends up naming
    /// something.
    ///
    /// ## The convention names the lanes; it does not move the audio
    ///
    /// Left is DX/SFX and right is MX, by channel and never by content - the
    /// content cannot be identified reliably, and a reel delivered the other way
    /// round is two clicks to swap. That naming is the whole of the convention.
    ///
    /// Sending each side to the *output* configured for its role reads like the
    /// obvious next step and is not. On a 32-channel interface with DX/SFX
    /// mapped to channels 28-29 and MX to 31-32, it moved both stems there the
    /// instant a hard-panned reel imported, while the desk was monitored from
    /// channels 1-2. The engine metered correctly and the interface was
    /// confirmed running; there was simply nothing on the speakers. Measured on
    /// this rig: `ch28=0.1611 ch29=0.1611 ch31=0.0063 ch32=0.0063`, and silence
    /// where anyone was listening.
    ///
    /// So both sides keep the output the video's audio was already using, which
    /// is the state a working session actually has: two lanes named DX/SFX and
    /// MX, both on Stereo Out, both audible. Moving either one is a deliberate
    /// act in its own output menu - and that now takes effect immediately, which
    /// it did not before (see `PlaybackEngine.applyOutputMappingIfNeeded`:
    /// crosspoints written to a stopped engine were discarded on start).
    ///
    /// - Parameter lanes: Lanes produced by the split.
    @MainActor
    private func nameOutputOfSplitLanes(_ lanes: [AudioLane]) {
        let outputs = audioManager.mappedOutputs
        guard !outputs.isEmpty else { return }

        for lane in lanes where !lane.isOutputDisabled {
            // Keep an inherited assignment, and otherwise name the output the
            // engine is already feeding - the one covering the lane's channel
            // span.
            guard lane.outputMappingId == nil else { continue }
            let current = outputs.first {
                $0.channelStart == lane.outputChannelOffset
                    && $0.channelCount == lane.outputChannelCount
            } ?? outputs[0]
            timelineManager.setLaneOutputMapping(id: lane.id, mapping: current)
        }
    }

    /// Split every hard-panned reel found in an import.
    ///
    /// A split is now purely a change to the timeline. Each side becomes a clip
    /// that reads the reel's own audio and takes its half in the mixer, so there
    /// is nothing to extract, nothing to wait for, and nothing written to disk -
    /// the lanes appear complete the moment this returns.
    ///
    /// Ordered rather than concurrent: each split looks for the shared lane for
    /// its side, so two at once would both find none and create a competing pair.
    ///
    /// - Parameter candidates: Reels to split.
    @MainActor
    private func performChannelSplits(for candidates: [SplitCandidate]) {
        let names: [SplitChannel: String] = [
            .left: SplitChannel.left.conventionalRoleName,
            .right: SplitChannel.right.conventionalRoleName
        ]

        for candidate in candidates {
            guard let reel = timelineManager.timeline.videoReels
                .first(where: { $0.id == candidate.id }) else { continue }

            // The stereo clip may still be decoding for a waveform that the
            // handover below is about to replace.
            waveformCache.cancelGeneration(for: candidate.clipId)

            guard let split = timelineManager.splitVideoAudioClipByChannel(
                clipId: candidate.clipId,
                inLane: candidate.laneId,
                reelId: reel.id,
                names: names
            ) else {
                debugPrint("performChannelSplits: clip \(candidate.clipId) no longer splittable")
                continue
            }

            nameOutputOfSplitLanes(split)

            for lane in split {
                guard let channel = lane.splitChannel,
                      let clipId = lane.clips.first(where: {
                          $0.sourceURL == reel.sourceURL && $0.sourceChannel == channel
                      })?.id else { continue }

                // Hand each side the trace already drawn for it. The stereo
                // clip's atlas holds both channels separately - that is what
                // draws the two stacked traces on an unsplit lane - so the split
                // lanes show the right waveform straight away instead of
                // decoding to recompute numbers we already had.
                if !waveformCache.adoptChannel(
                    from: candidate.clipId,
                    channel: channel,
                    as: clipId
                ) {
                    // Nothing to inherit, because the stereo trace had not
                    // finished. The clip draws its own, isolating its channel
                    // from the reel.
                    waveformCache.removeCachedWaveform(for: clipId)
                }

                // The player was built for the whole stereo track; it has to be
                // rebuilt to take only this side.
                playbackEngine.invalidateAudioClip(id: clipId)
            }

            // Dropped only now: it was the source of the traces handed over.
            waveformCache.removeCachedWaveform(for: candidate.clipId)
        }

        syncTimelineToPlaybackEngine()
        debugPrint("performChannelSplits: split \(candidates.count) reels")
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

        // Frame rates are settled for the whole batch before anything is
        // placed, because the per-file conflict dialog cannot work here.
        //
        // That dialog is driven by one slot of pending state
        // (`pendingVideoURL`/`pendingVideoFPS`), and this loop does not wait for
        // it: a second mismatching file overwrites the first file's URL while
        // the first file's dialog is still on screen, and a third queues behind
        // a dialog whose state has since been cleared. Measured on a drop of
        // three reels at 24, 25 and 30 fps: **one** reel imported, the dialog
        // named 25 fps while pointing at the 30 fps file, and the third file
        // vanished with nothing said about it.
        //
        // So the rates are read first and only the ones that match the project
        // are imported. The rest are named in a single report at the end -
        // nothing is silently lost, and no destructive offer is made in the
        // middle of a batch.
        let rates = await frameRates(of: urls)
        let projectFPS = batchProjectFrameRate(urls: urls, rates: rates)
        let importable = urls.filter { rates[$0].map { $0 == projectFPS } ?? true }
        let mismatched = urls.filter { rates[$0].map { $0 != projectFPS } ?? false }

        // Declared up front so the whole drop is one batch. Counting as each
        // file starts would let a short reel finish analysing before the next
        // one began, and close the batch early. Counts the files that will
        // actually be imported, so the ones held back do not leave the batch
        // waiting on reels that are never coming.
        splitOffers.expect(importable.count)

        for url in importable {
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

        // Last, so it does not sit in front of the reels the user is waiting to
        // see, and so it reports against the rate the batch settled on.
        if !mismatched.isEmpty {
            alerts.show(.batchFrameRateMismatch(
                names: mismatched.map { $0.lastPathComponent },
                projectFPS: projectFPS.stringValueVerbose
            ))
        }
    }

    // MARK: - Undo for Imports

    /// Remember the timeline as it stands, so the import about to run is undoable.
    ///
    /// Called at the top of every drop handler. ``frameImportedContent()`` - which
    /// every import path already ends with - turns the snapshot into an undo step,
    /// so a new import route gets undo by using the same ending rather than by
    /// remembering to register anything.
    func beginImportUndo() {
        importUndoSnapshot = timelineManager.timeline
    }

    /// Turn the snapshot taken by ``beginImportUndo()`` into one undo step.
    ///
    /// Snapshot-based, like every other timeline undo here: the timeline is a
    /// value, so restoring a copy puts back reels, lanes, clips, routing, the start
    /// timecode and the duration in one move. Reversing the individual placements
    /// instead would make a batch drop take one press per file.
    ///
    /// **Registered only if something actually changed.** A drop of files already
    /// on the timeline places nothing, and an undo step that restores an identical
    /// timeline is worse than none: Cmd-Z would look broken while silently
    /// consuming a press.
    ///
    /// **The media panel is left alone.** An import both places media and adds it
    /// to the project's library; this reverses the placement only. Removing library
    /// entries would mean deciding what to do about files already copied into the
    /// project folder, and the panel has its own undoable removal for that.
    private func registerImportUndoIfNeeded() {
        guard let before = importUndoSnapshot else { return }
        importUndoSnapshot = nil

        guard timelineManager.timeline != before else { return }

        undoManager?.registerUndo(withTarget: timelineManager) { manager in
            manager.timeline = before
        }
        undoManager?.setActionName("Import Media")
    }

    // MARK: - QuickTime Demo

    /// Open the review-QuickTime sheet.
    ///
    /// The view model is built here and handed the timeline as it stands, so the
    /// sheet prints what is on screen rather than following later edits made
    /// behind it. Presented through the alert coordinator, which already owns
    /// sheet presentation - `ContentView`'s body is at the type-checker's limit
    /// and cannot take another modifier.
    func presentQuickTimeDemo() {
        let viewModel = QuickTimeDemoViewModel(
            timeline: timelineManager.timeline,
            timecodeService: embeddedTimecodeService,
            formatTimecode: { [timelineManager] frame in
                timelineManager.formatTimecode(forFrame: frame)
            }
        )

        alerts.show(.quickTimeDemo(content: AnyView(
            QuickTimeDemoSheet(
                viewModel: viewModel,
                isPresented: Binding(
                    get: { self.alerts.activeAlert?.id == "quickTimeDemo" },
                    set: { isPresented in
                        if !isPresented, self.alerts.activeAlert?.id == "quickTimeDemo" {
                            self.alerts.dismiss()
                        }
                    }
                )
            )
        )))
    }

    /// Make the timeline begin where its content does, then frame that content.
    ///
    /// Every import path ends here. Two steps that belong together: moving the
    /// start changes what frame the content sits on, so framing has to happen
    /// after it or it frames a span that is about to shift.
    func frameImportedContent() {
        registerImportUndoIfNeeded()
        snapTimelineStartToContent()
        timelineViewModel.requestZoomToFitContent()
    }

    /// Move the timeline's start to the earliest reel or clip on it.
    ///
    /// `TimelineConfig.default` starts at 00:59:50:00 to leave pre-roll before
    /// the hour mark, and placement never moved it - so a reel delivered at
    /// 00:59:52:00 sat two seconds into a timeline whose first two seconds were
    /// dead, and at high zoom that dead space is what you scroll through to
    /// reach the picture. The head of the timeline should be the head of the
    /// programme.
    ///
    /// Idempotent, which is what makes it safe to call after every import:
    /// content can never be placed before frame 0 (`placementFrame` clamps
    /// there), so once the earliest thing is at 0 this does nothing. A later
    /// import landing further along the timeline therefore leaves the start
    /// alone rather than dragging the project around under the user.
    ///
    /// Uses the same shift as "Set Timeline Start to Region", so content keeps
    /// its absolute timecode and the duration is preserved.
    private func snapTimelineStartToContent() {
        guard let earliest = timelineManager.timeline.earliestContentFrame, earliest > 0 else { return }
        timelineManager.setTimelineStart(toFrame: earliest)
    }

    /// Each file's timecode frame rate, for the ones that can be read.
    ///
    /// A file that cannot be inspected is absent from the result rather than
    /// guessed at, so the caller lets it through to the ordinary import path and
    /// its real error is reported there instead of being recast as a frame rate
    /// problem.
    ///
    /// - Parameter urls: Video files to inspect.
    /// - Returns: The rate for each file that reported one.
    private func frameRates(of urls: [URL]) async -> [URL: TimecodeFrameRate] {
        var rates: [URL: TimecodeFrameRate] = [:]

        for url in urls {
            let asset = AVAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let nominal = try? await track.load(.nominalFrameRate) else { continue }
            rates[url] = closestTimecodeFrameRate(to: Double(nominal))
        }

        return rates
    }

    /// The rate a batch will be imported at.
    ///
    /// An empty timeline adopts the first file that reports a rate - the same
    /// rule ``addVideoToTimeline(url:atFrame:checkTimecode:)`` applies to a
    /// single import, decided here so the rest of the batch is measured against
    /// it before any of it is placed. A timeline that already holds reels keeps
    /// its own rate.
    ///
    /// - Parameters:
    ///   - urls: The batch, in drop order.
    ///   - rates: Rates read by ``frameRates(of:)``.
    /// - Returns: The frame rate every imported file in this batch will match.
    private func batchProjectFrameRate(
        urls: [URL],
        rates: [URL: TimecodeFrameRate]
    ) -> TimecodeFrameRate {
        let projectFPS = timelineManager.timeline.config.frameRate
        guard timelineManager.timeline.videoReels.isEmpty else { return projectFPS }
        return urls.compactMap { rates[$0] }.first ?? projectFPS
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

    /// The result of trying to place one audio file during a batch import.
    enum AudioPlacementOutcome {

        /// The clip is on its lane.
        case placed(AudioClip)

        /// The lane the file's stem owns is already occupied at those frames,
        /// so the file was not placed. The caller reports it.
        case laneOccupied

        /// Placement failed for a reason that is ours, not the delivery's.
        case failed
    }

    /// Place an audio clip on the lane its stem owns, or report that it does
    /// not fit.
    ///
    /// ## A batch never invents a second lane for one stem
    ///
    /// The model allows overlapping clips (`AudioLane.addClip` appends
    /// unconditionally), so a batch of files sharing a start timecode - stems
    /// and mix passes routinely all start at 01:00:00:00 - would stack every
    /// clip at the same frames of one lane, showing the first clip's waveform
    /// with the rest hidden exactly underneath. That read as "only the first
    /// file was imported", so overlapping files used to spill onto a lane each.
    ///
    /// Spilling traded one wrong answer for another: a five-reel delivery
    /// arrived as five `MX` lanes holding one clip apiece. Both answers are the
    /// app deciding something it cannot know. Since a batch now puts exactly one
    /// lane under each stem, a collision here means two files of the *same* stem
    /// claim overlapping time - which no delivery can mean - so the file is
    /// held back and named instead. See ``ImportHoldBackReport``.
    ///
    /// - Parameters:
    ///   - url: The audio file.
    ///   - preferredLaneId: The lane this file's stem owns.
    ///   - atFrame: Where the file's timecode puts it.
    /// - Returns: What happened, for the caller to report.
    func addAudioToTimelineAvoidingOverlap(
        url: URL,
        preferredLaneId: UUID,
        atFrame: Int
    ) async -> AudioPlacementOutcome {
        let fps = timelineManager.timeline.config.frameRate.fps
        var durationFrames = 1
        if let duration = try? await AVURLAsset(url: url).load(.duration) {
            durationFrames = max(1, Int(duration.seconds * fps))
        }

        guard let preferred = timelineManager.timeline.audioLanes.first(where: { $0.id == preferredLaneId }) else {
            // The reserved lane is gone. This should not happen now that the
            // batch marks its stem lanes in `reservedAudioLaneIds` so video
            // embedded audio cannot adopt them, but losing the file silently is
            // the one outcome worth ruling out structurally: `addAudioClip`
            // returns nil when the lane is missing, and nothing downstream
            // could tell that from an empty drop.
            debugPrint("addAudioToTimelineAvoidingOverlap: preferred lane \(preferredLaneId.uuidString.prefix(8)) no longer exists for '\(url.lastPathComponent)'")
            return .failed
        }

        if laneIsOccupied(preferred, startFrame: atFrame, durationFrames: durationFrames) {
            debugPrint("addAudioToTimelineAvoidingOverlap: '\(url.lastPathComponent)' overlaps lane '\(preferred.name)' at frame \(atFrame); holding it back")
            return .laneOccupied
        }

        guard let clip = await addAudioToTimeline(
            url: url,
            laneId: preferredLaneId,
            atFrame: atFrame,
            checkTimecode: false
        ) else {
            debugPrint("addAudioToTimelineAvoidingOverlap: placement of '\(url.lastPathComponent)' returned nil")
            return .failed
        }

        return .placed(clip)
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
        var overlapping: [URL] = []

        for item in items {
            // Relative to the timeline's start, like every other placement.
            let targetFrame = placementFrame(
                metadata: item.detectedTimecode,
                dropFrame: nextSequentialFrame
            )
            debugPrint("addAudioFilesAtEmbeddedTimecode: \(item.url.lastPathComponent) -> frame \(targetFrame) (\(item.hasTimecode ? "timecode" : "sequential"))")

            switch await addAudioToTimelineAvoidingOverlap(url: item.url, preferredLaneId: laneId, atFrame: targetFrame) {
            case .placed(let clip):
                nextSequentialFrame = clip.timelineEndFrame
            case .laneOccupied:
                overlapping.append(item.url)
            case .failed:
                alerts.show(.error("Couldn't add \"\(item.url.lastPathComponent)\" to the timeline."))
            }
        }

        // Same rule as a mixed batch: the lane the user aimed at keeps its
        // identity, and a file that will not fit on it is reported rather than
        // given a lane nobody asked for.
        await holdBack(urls: overlapping, reason: .timecodeAlreadyOccupied)

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

    /// Where a video lands, resolved against the timeline's current frame rate.
    ///
    /// Separate from gathering the timecode because the two happen at different
    /// moments: the timecode is read from the file at import, but the frame it
    /// resolves to is only meaningful once the timeline's rate is final - which,
    /// for the first reel or after an FPS conflict, is *after* the file has been
    /// inspected.
    ///
    /// - Parameters:
    ///   - placement: What the file said about where it belongs.
    ///   - url: The file, for the log line.
    /// - Returns: A frame relative to the timeline start.
    func resolvedPlacementFrame(_ placement: PendingVideoPlacement, for url: URL) -> Int {
        guard placement.metadata != nil || placement.filenameTimecode != nil else {
            return placement.dropFrame
                ?? (timelineManager.timeline.videoReels.map { $0.timelineEndFrame }.max() ?? 0)
        }

        let frame = placementFrame(
            metadata: placement.metadata,
            filenameTimecode: placement.filenameTimecode,
            dropFrame: placement.dropFrame ?? 0
        )
        debugPrint("addVideoToTimeline: '\(url.lastPathComponent)' -> frame \(frame) at \(timelineManager.timeline.config.frameRate.stringValueVerbose) (filename=\(placement.filenameTimecode ?? "nil"), metadata=\(placement.metadata?.formattedTimecode ?? "nil"))")
        return frame
    }

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
                self.pendingVideoPlacement = nil
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
                self.beginImportUndo()
                Task { @MainActor in
                    await self.addVideoToTimelineUnchecked(url: confirmedURL, at: insertFrame)
                    self.videoInsertURL = nil
                    self.frameImportedContent()
                }
            }
        ))
    }

}

// MARK: - Pending Placement

/// What a video said about where it belongs, before that answer has a frame rate.
///
/// Held rather than resolved so placement can be worked out against the rate the
/// timeline ends up at. An import can change that rate - the first reel adopts
/// its own, and an FPS conflict changes it behind a dialog - and a frame number
/// worked out at the outgoing rate addresses a timeline that no longer exists.
struct PendingVideoPlacement {
    /// Where the user let go, used when the file carries no timecode.
    var dropFrame: Int?

    /// Timecode read from the file's metadata, if any.
    var metadata: EmbeddedTimecodeResult?

    /// Timecode parsed out of the file's name, as a fallback.
    var filenameTimecode: String?
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
