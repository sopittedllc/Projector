import Foundation
import SwiftTimecodeCore
import Combine
import AVFoundation

/// Manages timeline state and CRUD operations for video reels and audio clips.
///
/// This manager is the central authority for timeline data, handling all modifications
/// to video reels, audio clips, and timeline configuration. It provides change tracking
/// for document save state and callbacks for syncing with other components.
///
/// ## Overview
///
/// Use `TimelineManager` to:
/// - Add, remove, and reorder video reels
/// - Add, remove, and reorder audio clips
/// - Configure timeline bounds and frame rate
/// - Track unsaved changes for document management
///
/// ## Architecture
///
/// ```
/// ┌─────────────────────────────────────────────────────────────────────────┐
/// │                         SwiftUI Views                                    │
/// │  ContentView, MultiTrackTimelineView                                    │
/// │  - Use @ObservedObject var timelineManager: TimelineManager             │
/// └─────────────────────────────────────────────────────────────────────────┘
///                               │
///                               ▼
/// ┌─────────────────────────────────────────────────────────────────────────┐
/// │                    TimelineManager (this file)                           │
/// │  - @MainActor for UI thread safety                                       │
/// │  - @Published timeline, currentFrame, hasChanges                         │
/// │  - CRUD operations for reels and clips                                   │
/// │  - Change tracking and callbacks                                         │
/// └─────────────────────────────────────────────────────────────────────────┘
///                               │
///                               ▼
/// ┌─────────────────────────────────────────────────────────────────────────┐
/// │                      Timeline Model                                      │
/// │  - Timeline, VideoReel, AudioLane, AudioClip                            │
/// │  - TimelineConfig with frame rate and bounds                            │
/// └─────────────────────────────────────────────────────────────────────────┘
/// ```
///
/// ## Thread Safety
///
/// This class is confined to the main thread via `@MainActor`. All timeline
/// modifications happen on the main thread for SwiftUI compatibility.
///
/// ## Change Tracking
///
/// The manager tracks whether the timeline has unsaved changes via `hasChanges`.
/// Call `markClean()` after saving to reset this flag.
///
/// ## Example
///
/// ```swift
/// // Add a video reel
/// let reel = try await timelineManager.addVideoReel(from: videoURL, at: 0)
///
/// // Add an audio lane
/// let lane = timelineManager.addAudioLane(name: "Audio 1")
///
/// // Add an audio clip to the lane
/// let clip = try await timelineManager.addAudioClip(from: audioURL, toLane: lane.id, at: 0)
///
/// // Check for unsaved changes
/// if timelineManager.hasChanges {
///     // Prompt user to save
/// }
/// ```
@MainActor
final class TimelineManager: ObservableObject {
    // MARK: - Published Properties

    /// The master timeline
    @Published var timeline: Timeline {
        didSet { markDirty() }
    }

    /// Current playhead position in timeline frames
    @Published var currentFrame: Int = 0

    /// Whether timeline has unsaved changes
    @Published private(set) var hasChanges: Bool = false

    // MARK: - Callbacks

    /// Called when the timeline is modified
    var onTimelineChanged: (() -> Void)?

    // MARK: - Initialization

    init(timeline: Timeline = .empty) {
        self.timeline = timeline
    }

    // MARK: - Change Tracking

    private func markDirty() {
        hasChanges = true
        onTimelineChanged?()
    }

    func markClean() {
        hasChanges = false
    }

    // MARK: - Timeline Configuration

    /// Update the timeline configuration
    func updateConfig(_ config: TimelineConfig) {
        timeline.config = config
    }

    /// Set the frame rate for the timeline
    func setFrameRate(_ frameRate: TimecodeFrameRate) {
        var config = timeline.config
        config.frameRate = frameRate
        timeline.config = config
    }

    /// Set the timeline bounds
    func setTimelineBounds(start: Timecode, end: Timecode) {
        var config = timeline.config
        config.startTimecode = start
        config.endTimecode = end
        timeline.config = config
    }

    private func extendTimelineIfNeeded(toEndFrame endFrame: Int) {
        let clampedEndFrame = max(0, endFrame)
        var config = timeline.config
        let desiredEndFrames = config.startTimecode.frameCount.wholeFrames + clampedEndFrame
        if desiredEndFrames > config.endTimecode.frameCount.wholeFrames {
            config.endTimecode = Timecode(.frames(desiredEndFrames), at: config.frameRate, by: .clamping)
            timeline.config = config
        }
    }

    /// Extend the timeline to at least the specified end frame.
    ///
    /// Use this to add padding after clips so users have room to drop more media.
    ///
    /// - Parameter endFrame: The minimum end frame (relative to timeline start)
    func extendTimeline(toEndFrame endFrame: Int) {
        extendTimelineIfNeeded(toEndFrame: endFrame)
    }

    // MARK: - Video Reel Operations

    /// Active security-scoped URLs that should not be released until reel removal
    private var activeSecurityScopedURLs: [UUID: URL] = [:]

    /// Add a video reel from a file URL
    func addVideoReel(from url: URL, at timelineFrame: Int, mediaItemId: UUID? = nil) async throws -> VideoReel {
        let t0 = CFAbsoluteTimeGetCurrent()
        func elapsed() -> String { String(format: "%.3fs", CFAbsoluteTimeGetCurrent() - t0) }

        debugPrint("addVideoReel: ENTRY [T+\(elapsed())] - \(url.lastPathComponent)")

        // For drop URLs, we have implicit sandbox access that expires after the drop operation.
        // We must create a bookmark AND immediately resolve it to get a persistent security-scoped URL.

        // Create security-scoped bookmark from the drop URL (while we have implicit access)
        let bookmark = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        debugPrint("addVideoReel: Bookmark created [T+\(elapsed())]")

        // Immediately resolve the bookmark to get a security-scoped URL
        var isStale = false
        let resolvedURL = try URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        debugPrint("addVideoReel: Resolved URL [T+\(elapsed())] stale=\(isStale)")

        // Start security-scoped access on the RESOLVED URL (not the drop URL)
        // This access persists until we explicitly stop it
        let accessStarted = resolvedURL.startAccessingSecurityScopedResource()
        debugPrint("addVideoReel: Security access started=\(accessStarted) [T+\(elapsed())]")
        guard accessStarted else {
            debugPrint("addVideoReel: FAILED to start security access")
            throw TimelineError.fileAccessDenied
        }

        // Get video metadata using the resolved URL
        let asset = AVURLAsset(url: resolvedURL)
        let duration = try await asset.load(.duration)
        debugPrint("addVideoReel: Duration loaded [T+\(elapsed())]")

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        debugPrint("addVideoReel: Video tracks loaded [T+\(elapsed())]")

        // Determine frame rate from video
        var frameRate = timeline.config.frameRate
        if let videoTrack = videoTracks.first {
            let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
            if let detectedRate = TimecodeFrameRate.allCases.first(where: {
                abs($0.fps - Double(nominalFrameRate)) < 0.5
            }) {
                frameRate = detectedRate
            }
        }
        debugPrint("addVideoReel: Frame rate determined [T+\(elapsed())]")

        let durationFrames = Int(duration.seconds * frameRate.fps)

        let reel = VideoReel(
            mediaItemId: mediaItemId,
            sourceURL: resolvedURL,  // Use the resolved security-scoped URL
            sourceBookmark: bookmark,
            timelineStartFrame: timelineFrame,
            durationFrames: durationFrames,
            sourceStartFrame: 0,
            sourceFrameRate: frameRate
        )

        // Track the RESOLVED URL for cleanup when reel is removed
        activeSecurityScopedURLs[reel.id] = resolvedURL

        timeline.addVideoReel(reel)
        extendTimelineIfNeeded(toEndFrame: reel.timelineEndFrame)
        debugPrint("addVideoReel: COMPLETE [T+\(elapsed())]")
        return reel
    }

    /// Remove a video reel by ID
    func removeVideoReel(id: UUID) {
        // Release security-scoped access when reel is removed
        if let url = activeSecurityScopedURLs.removeValue(forKey: id) {
            url.stopAccessingSecurityScopedResource()
        }
        timeline.removeVideoReel(id: id)
    }

    /// Move a video reel to a new timeline position
    func moveVideoReel(id: UUID, to newFrame: Int) {
        moveVideoReel(id: id, to: newFrame, moveLinkedAudio: true)
    }

    private func moveVideoReel(id: UUID, to newFrame: Int, moveLinkedAudio: Bool) {
        guard var reel = timeline.videoReels.first(where: { $0.id == id }) else { return }
        let oldFrame = reel.timelineStartFrame
        guard oldFrame != newFrame else { return }

        reel.timelineStartFrame = newFrame
        timeline.updateVideoReel(reel)

        if moveLinkedAudio {
            moveLinkedAudioClips(for: reel, oldFrame: oldFrame, newFrame: newFrame, excludingClipId: nil)
        }
    }

    /// Trim a video reel (adjust in/out points)
    func trimVideoReel(id: UUID, newStartFrame: Int, newDurationFrames: Int, newSourceStartFrame: Int) {
        if var reel = timeline.videoReels.first(where: { $0.id == id }) {
            reel.timelineStartFrame = newStartFrame
            reel.durationFrames = newDurationFrames
            reel.sourceStartFrame = newSourceStartFrame
            timeline.updateVideoReel(reel)
        }
    }

    /// Update the source URL for a video reel (used when relocating missing files)
    func updateVideoReelURL(id: UUID, newURL: URL) {
        if var reel = timeline.videoReels.first(where: { $0.id == id }) {
            reel.sourceURL = newURL
            reel.sourceBookmark = try? newURL.bookmarkData(options: .withSecurityScope)
            timeline.updateVideoReel(reel)
        }
    }

    // MARK: - Audio Lane Operations

    /// Add a new audio lane
    func addAudioLane(name: String? = nil) -> AudioLane {
        let laneNumber = timeline.audioLanes.count + 1
        let lane = AudioLane(
            name: name ?? "Audio \(laneNumber)",
            colorIndex: laneNumber % 8
        )
        timeline.addAudioLane(lane)
        return lane
    }

    /// Add a new audio lane at the top (index 0)
    func addAudioLaneAtTop(name: String? = nil) -> AudioLane {
        let laneNumber = timeline.audioLanes.count + 1
        let lane = AudioLane(
            name: name ?? "Audio \(laneNumber)",
            colorIndex: laneNumber % 8
        )
        timeline.addAudioLaneAtTop(lane)
        return lane
    }

    /// Remove an audio lane by ID
    func removeAudioLane(id: UUID) {
        timeline.removeAudioLane(id: id)
    }

    /// Rename an audio lane
    func renameAudioLane(id: UUID, name: String) {
        if var lane = timeline.audioLanes.first(where: { $0.id == id }) {
            lane.name = name
            timeline.updateAudioLane(lane)
        }
    }

    /// Set lane mute state
    func setLaneMuted(id: UUID, muted: Bool) {
        if var lane = timeline.audioLanes.first(where: { $0.id == id }) {
            lane.isMuted = muted
            timeline.updateAudioLane(lane)
        }
    }

    /// Set lane solo state
    func setLaneSolo(id: UUID, solo: Bool) {
        if var lane = timeline.audioLanes.first(where: { $0.id == id }) {
            lane.isSolo = solo
            timeline.updateAudioLane(lane)
        }
    }

    /// Set lane volume
    func setLaneVolume(id: UUID, volume: Float) {
        if var lane = timeline.audioLanes.first(where: { $0.id == id }) {
            lane.volume = max(0, min(1, volume))
            timeline.updateAudioLane(lane)
        }
    }

    /// Set lane output channel offset
    func setLaneOutputOffset(id: UUID, offset: Int) {
        if var lane = timeline.audioLanes.first(where: { $0.id == id }) {
            lane.outputChannelOffset = offset
            timeline.updateAudioLane(lane)
        }
    }

    /// Set lane output device UID (nil = use global default)
    func setLaneOutputDevice(id: UUID, deviceUID: String?) {
        if var lane = timeline.audioLanes.first(where: { $0.id == id }) {
            lane.outputDeviceUID = deviceUID
            timeline.updateAudioLane(lane)
        }
    }

    /// Set lane output mapping (nil = default)
    func setLaneOutputMapping(id: UUID, mapping: MappedAudioOutput?) {
        if var lane = timeline.audioLanes.first(where: { $0.id == id }) {
            lane.outputMappingId = mapping?.id
            if let mapping = mapping {
                lane.outputChannelOffset = max(0, mapping.channelStart - 1)
                lane.outputChannelCount = max(1, mapping.channelCount)
            } else {
                lane.outputChannelOffset = 0
                lane.outputChannelCount = 2
            }
            timeline.updateAudioLane(lane)
        }
    }

    // MARK: - Audio Lane Index-Based Convenience Methods

    /// Toggle lane mute state by index
    func toggleLaneMute(at index: Int) {
        guard index >= 0, index < timeline.audioLanes.count else { return }
        var lane = timeline.audioLanes[index]
        lane.isMuted.toggle()
        timeline.updateAudioLane(lane)
    }

    /// Toggle lane solo state by index
    func toggleLaneSolo(at index: Int) {
        guard index >= 0, index < timeline.audioLanes.count else { return }
        var lane = timeline.audioLanes[index]
        lane.isSolo.toggle()
        timeline.updateAudioLane(lane)
    }

    /// Set lane volume by index
    func setLaneVolume(at index: Int, volume: Float) {
        guard index >= 0, index < timeline.audioLanes.count else { return }
        var lane = timeline.audioLanes[index]
        lane.volume = max(0, min(1, volume))
        timeline.updateAudioLane(lane)
    }

    // MARK: - Audio Clip Operations

    /// Add an audio clip from a file to a lane
    func addAudioClip(from url: URL, toLane laneId: UUID, at timelineFrame: Int) async throws -> AudioClip? {
        guard timeline.audioLanes.contains(where: { $0.id == laneId }) else {
            return nil
        }

        // Start security-scoped access before creating bookmark
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        // Create security-scoped bookmark (while access is active)
        let bookmark = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        // Get audio metadata
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        guard let audioTrack = audioTracks.first else {
            throw TimelineError.noAudioTrack
        }

        // Get channel count from audio format
        let formatDescriptions = try await audioTrack.load(.formatDescriptions)
        var channelCount = 2 // Default stereo
        var sampleRate: Double = 48000

        if let formatDesc = formatDescriptions.first {
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
            if let format = asbd?.pointee {
                channelCount = Int(format.mChannelsPerFrame)
                sampleRate = format.mSampleRate
            }
        }

        let durationFrames = Int(duration.seconds * timeline.config.frameRate.fps)

        let clip = AudioClip(
            sourceURL: url,
            sourceBookmark: bookmark,
            timelineStartFrame: timelineFrame,
            durationFrames: durationFrames,
            sourceStartFrame: 0,
            sourceType: .audioFile,
            channelCount: channelCount,
            sampleRate: sampleRate
        )

        // Explicitly notify observers before mutation to ensure SwiftUI sees the change
        objectWillChange.send()
        timeline.addClip(clip, toLane: laneId)
        extendTimelineIfNeeded(toEndFrame: clip.timelineEndFrame)
        debugPrint("TimelineManager.addAudioClip: Added clip to lane, timeline now has \(timeline.audioLanes.map { "\($0.name):\($0.clips.count)" })")
        return clip
    }

    /// Add an audio clip without creating security-scoped bookmarks (UI testing only).
    func addAudioClipForTesting(from url: URL, toLane laneId: UUID, at timelineFrame: Int) async throws -> AudioClip? {
        guard timeline.audioLanes.contains(where: { $0.id == laneId }) else {
            return nil
        }

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        guard let audioTrack = audioTracks.first else {
            throw TimelineError.noAudioTrack
        }

        let formatDescriptions = try await audioTrack.load(.formatDescriptions)
        var channelCount = 2
        var sampleRate: Double = 48000

        if let formatDesc = formatDescriptions.first,
           let format = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee {
            channelCount = Int(format.mChannelsPerFrame)
            sampleRate = format.mSampleRate
        }

        let durationFrames = Int(duration.seconds * timeline.config.frameRate.fps)

        let clip = AudioClip(
            sourceURL: url,
            sourceBookmark: nil,
            timelineStartFrame: timelineFrame,
            durationFrames: durationFrames,
            sourceStartFrame: 0,
            sourceType: .audioFile,
            channelCount: channelCount,
            sampleRate: sampleRate
        )

        timeline.addClip(clip, toLane: laneId)
        extendTimelineIfNeeded(toEndFrame: clip.timelineEndFrame)
        return clip
    }

    /// Extract audio from a video reel and add it to a lane
    /// - Parameters:
    ///   - reelId: The video reel to extract audio from
    ///   - trackIndex: The audio track index to extract
    ///   - laneId: The lane to add the audio clip to
    ///   - preExtractedURL: Optional pre-extracted audio file URL (for immediate playback)
    func extractAudioFromReel(
        _ reelId: UUID,
        trackIndex: Int,
        toLane laneId: UUID,
        preExtractedURL: URL? = nil
    ) async throws -> AudioClip? {
        guard let reel = timeline.videoReels.first(where: { $0.id == reelId }),
              timeline.audioLanes.contains(where: { $0.id == laneId }) else {
            return nil
        }

        // Use the source URL directly - security access is managed by addVideoReel
        // and stays active until reel is removed
        let asset = AVURLAsset(url: reel.sourceURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        guard trackIndex < audioTracks.count else {
            throw TimelineError.invalidTrackIndex
        }

        let audioTrack = audioTracks[trackIndex]

        // Get channel count from audio format
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
            extractedAudioURL: preExtractedURL,
            sourceFrameRate: reel.sourceFrameRate
        )

        timeline.addClip(clip, toLane: laneId)
        extendTimelineIfNeeded(toEndFrame: clip.timelineEndFrame)
        return clip
    }

    /// Remove an audio clip from a lane
    func removeAudioClip(clipId: UUID, fromLane laneId: UUID) {
        timeline.removeClip(clipId: clipId, fromLane: laneId)
    }

    /// Move an audio clip to a new position
    func moveAudioClip(clipId: UUID, inLane laneId: UUID, to newFrame: Int) {
        moveAudioClip(clipId: clipId, inLane: laneId, to: newFrame, moveLinkedReel: true)
    }

    private func moveAudioClip(clipId: UUID, inLane laneId: UUID, to newFrame: Int, moveLinkedReel shouldMoveLinkedReel: Bool) {
        guard let laneIndex = timeline.audioLanes.firstIndex(where: { $0.id == laneId }),
              var clip = timeline.audioLanes[laneIndex].clips.first(where: { $0.id == clipId }) else { return }

        let oldFrame = clip.timelineStartFrame
        guard oldFrame != newFrame else { return }

        clip.timelineStartFrame = newFrame
        timeline.audioLanes[laneIndex].updateClip(clip)

        guard shouldMoveLinkedReel, clip.sourceType == .videoTrack else { return }
        moveLinkedReel(for: clip, oldFrame: oldFrame, newFrame: newFrame)
    }

    /// Move an audio clip to a different lane
    func moveAudioClipToLane(clipId: UUID, fromLane: UUID, toLane: UUID, at timelineFrame: Int? = nil) {
        if let fromIndex = timeline.audioLanes.firstIndex(where: { $0.id == fromLane }),
           var clip = timeline.audioLanes[fromIndex].clips.first(where: { $0.id == clipId }) {
            // Remove from old lane
            timeline.audioLanes[fromIndex].removeClip(id: clipId)

            // Update position if specified
            if let frame = timelineFrame {
                clip.timelineStartFrame = frame
            }

            // Add to new lane
            if let toIndex = timeline.audioLanes.firstIndex(where: { $0.id == toLane }) {
                timeline.audioLanes[toIndex].addClip(clip)
            }
        }
    }

    private func moveLinkedReel(for clip: AudioClip, oldFrame: Int, newFrame: Int) {
        guard let reel = timeline.videoReels.first(where: {
            $0.sourceURL == clip.sourceURL &&
            $0.sourceStartFrame == clip.sourceStartFrame &&
            $0.durationFrames == clip.durationFrames &&
            $0.timelineStartFrame == oldFrame
        }) else { return }

        moveVideoReel(id: reel.id, to: newFrame, moveLinkedAudio: false)
        moveLinkedAudioClips(for: reel, oldFrame: oldFrame, newFrame: newFrame, excludingClipId: clip.id)
    }

    private func moveLinkedAudioClips(
        for reel: VideoReel,
        oldFrame: Int,
        newFrame: Int,
        excludingClipId: UUID?
    ) {
        for laneIndex in timeline.audioLanes.indices {
            let clips = timeline.audioLanes[laneIndex].clips
            for clip in clips where isLinked(clip, to: reel, at: oldFrame) {
                guard clip.id != excludingClipId else { continue }
                var updated = clip
                updated.timelineStartFrame = newFrame
                timeline.audioLanes[laneIndex].updateClip(updated)
            }
        }
    }

    private func isLinked(_ clip: AudioClip, to reel: VideoReel, at startFrame: Int) -> Bool {
        clip.sourceType == .videoTrack &&
        clip.sourceURL == reel.sourceURL &&
        clip.sourceStartFrame == reel.sourceStartFrame &&
        clip.durationFrames == reel.durationFrames &&
        clip.timelineStartFrame == startFrame
    }

    /// Update the source URL for an audio clip (used when relocating missing files)
    func updateAudioClipURL(clipId: UUID, inLane laneId: UUID, newURL: URL) {
        if let laneIndex = timeline.audioLanes.firstIndex(where: { $0.id == laneId }),
           var clip = timeline.audioLanes[laneIndex].clips.first(where: { $0.id == clipId }) {
            clip.sourceURL = newURL
            clip.sourceBookmark = try? newURL.bookmarkData(options: .withSecurityScope)
            timeline.audioLanes[laneIndex].updateClip(clip)
        }
    }

    /// Set clip mute state
    func setClipMuted(clipId: UUID, inLane laneId: UUID, muted: Bool) {
        if let laneIndex = timeline.audioLanes.firstIndex(where: { $0.id == laneId }),
           var clip = timeline.audioLanes[laneIndex].clips.first(where: { $0.id == clipId }) {
            clip.isMuted = muted
            timeline.audioLanes[laneIndex].updateClip(clip)
        }
    }

    /// Set clip volume
    func setClipVolume(clipId: UUID, inLane laneId: UUID, volume: Float) {
        if let laneIndex = timeline.audioLanes.firstIndex(where: { $0.id == laneId }),
           var clip = timeline.audioLanes[laneIndex].clips.first(where: { $0.id == clipId }) {
            clip.volume = max(0, min(1, volume))
            timeline.audioLanes[laneIndex].updateClip(clip)
        }
    }

    /// Update extracted audio URL for an audio clip (used when background extraction completes)
    func updateExtractedAudioURL(clipId: UUID, inLane laneId: UUID, extractedURL: URL) {
        if let laneIndex = timeline.audioLanes.firstIndex(where: { $0.id == laneId }),
           var clip = timeline.audioLanes[laneIndex].clips.first(where: { $0.id == clipId }) {
            clip.extractedAudioURL = extractedURL
            timeline.audioLanes[laneIndex].updateClip(clip)
        }
    }

    /// Trim an audio clip
    func trimAudioClip(clipId: UUID, inLane laneId: UUID, newStartFrame: Int, newDurationFrames: Int, newSourceStartFrame: Int) {
        if let laneIndex = timeline.audioLanes.firstIndex(where: { $0.id == laneId }),
           var clip = timeline.audioLanes[laneIndex].clips.first(where: { $0.id == clipId }) {
            clip.timelineStartFrame = newStartFrame
            clip.durationFrames = newDurationFrames
            clip.sourceStartFrame = newSourceStartFrame
            timeline.audioLanes[laneIndex].updateClip(clip)
        }
    }

    // MARK: - Playhead Operations

    /// Seek to a specific timeline frame
    func seekToFrame(_ frame: Int) {
        currentFrame = max(0, min(frame, timeline.config.durationFrames - 1))
    }

    /// Seek to a specific timecode
    func seekToTimecode(_ timecode: Timecode) {
        let frame = timeline.config.frame(for: timecode)
        seekToFrame(frame)
    }

    /// Get the current timecode
    var currentTimecode: Timecode {
        timeline.config.timecode(at: currentFrame)
    }

    // MARK: - Cue Operations

    /// All cues from all cue sheets, sorted by start frame
    var allCues: [Cue] {
        timeline.allCues
    }

    /// Add a new cue at the specified position.
    ///
    /// - Parameters:
    ///   - startFrame: Start frame for the cue
    ///   - endFrame: End frame for the cue
    ///   - title: Optional title (defaults to empty string)
    /// - Returns: The created cue
    @discardableResult
    func addCue(startFrame: Int, endFrame: Int, title: String = "") -> Cue {
        let number = (timeline.primaryCueSheet?.cues.count ?? 0) + 1
        let cue = Cue(
            number: number,
            title: title,
            startFrame: startFrame,
            endFrame: endFrame
        )
        timeline.addCue(cue)
        return cue
    }

    /// Update an existing cue.
    ///
    /// - Parameter cue: The cue with updated values
    func updateCue(_ cue: Cue) {
        timeline.updateCue(cue)
    }

    /// Remove a cue by ID.
    ///
    /// - Parameter id: The ID of the cue to remove
    func removeCue(id: UUID) {
        timeline.removeCue(id: id)
    }

    /// Renumber all cues sequentially based on their position.
    func renumberCues() {
        guard var sheet = timeline.primaryCueSheet else { return }
        sheet.renumberCues()
        timeline.updateOrAddCueSheet(sheet)
    }

    /// Import detected cues into the primary cue sheet.
    ///
    /// - Parameter detected: Array of detected cues from silence detection
    func importDetectedCues(_ detected: [DetectedCue]) {
        for detectedCue in detected {
            let cue = Cue.from(detectedCue)
            timeline.addCue(cue)
        }
    }

    /// Get the cue at a specific frame, if any.
    ///
    /// - Parameter frame: The timeline frame to check
    /// - Returns: The cue containing this frame, or nil
    func cue(at frame: Int) -> Cue? {
        allCues.first { $0.startFrame <= frame && frame <= $0.endFrame }
    }

    // MARK: - Queries

    /// Get the video reel at the current playhead position
    var currentVideoReel: VideoReel? {
        timeline.videoReel(at: currentFrame)
    }

    /// Get all active audio clips at the current playhead position
    var currentAudioClips: [(lane: AudioLane, clip: AudioClip)] {
        timeline.activeAudioClips(at: currentFrame)
    }

    /// Check if the playhead is in a video gap
    var isInVideoGap: Bool {
        timeline.isVideoGap(at: currentFrame)
    }
}

// MARK: - Errors

enum TimelineError: LocalizedError {
    case noAudioTrack
    case invalidTrackIndex
    case fileAccessDenied

    var errorDescription: String? {
        switch self {
        case .noAudioTrack:
            return "The file does not contain an audio track."
        case .invalidTrackIndex:
            return "The specified audio track index does not exist."
        case .fileAccessDenied:
            return "Cannot access the file. Permission denied."
        }
    }
}
