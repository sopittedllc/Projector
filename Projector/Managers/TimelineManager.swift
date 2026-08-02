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

    /// Additional observers used by logic-layer consumers.
    ///
    /// `onTimelineChanged` is retained for the presentation layer, while this
    /// collection prevents one subsystem from overwriting another subsystem's
    /// callback.
    private var timelineChangeObservers: [UUID: () -> Void] = [:]

    // MARK: - Constants

    /// Default padding in minutes added when auto-extending the timeline.
    ///
    /// This provides workspace at the end of content.
    static let defaultPaddingMinutes: Double = 20.0

    // MARK: - Initialization

    init(timeline: Timeline = .empty) {
        self.timeline = timeline
    }

    // MARK: - Change Tracking

    private func markDirty() {
        hasChanges = true
        onTimelineChanged?()
        for observer in timelineChangeObservers.values {
            observer()
        }
    }

    /// Registers an additional timeline-change observer.
    ///
    /// - Parameter observer: Closure invoked after the timeline changes.
    /// - Returns: A token used to remove the observer.
    func addTimelineChangeObserver(_ observer: @escaping () -> Void) -> UUID {
        let id = UUID()
        timelineChangeObservers[id] = observer
        return id
    }

    /// Removes a previously registered timeline-change observer.
    ///
    /// - Parameter id: Token returned by ``addTimelineChangeObserver(_:)``.
    func removeTimelineChangeObserver(id: UUID) {
        timelineChangeObservers.removeValue(forKey: id)
    }

    func markClean() {
        hasChanges = false
    }

    // MARK: - Timecode Formatting

    /// Format a timeline frame number as a timecode string
    ///
    /// Adds the timeline start offset to convert from relative frame to absolute timecode.
    ///
    /// - Parameter frame: The frame number relative to timeline start (0-based)
    /// - Returns: Formatted timecode string (e.g., "01:00:00:00")
    func formatTimecode(forFrame frame: Int) -> String {
        let startFrames = timeline.config.startTimecode.frameCount.wholeFrames
        let absoluteFrame = startFrames + frame
        let rate = timeline.config.frameRate

        // Use SwiftTimecodeCore to format
        let tc = Timecode(.frames(absoluteFrame), at: rate, by: .clamping)
        return tc.stringValue()
    }

    // MARK: - Timeline Configuration

    /// Update the timeline configuration.
    ///
    /// If the start timecode changes, all content (video reels and audio clips)
    /// is shifted to maintain their absolute timecode positions.
    ///
    /// - Parameter config: The new timeline configuration
    func updateConfig(_ config: TimelineConfig) {
        let oldStartFrames = timeline.config.startTimecode.frameCount.wholeFrames
        let newStartFrames = config.startTimecode.frameCount.wholeFrames
        let delta = oldStartFrames - newStartFrames

        timeline.config = config

        // If start timecode changed, shift all content to maintain absolute timecode positions
        if delta != 0 {
            shiftAllContent(by: delta)
        }
    }

    /// Move the timeline's start to a frame currently on the timeline.
    ///
    /// Used by "Set Timeline Start to Region": the region's own timecode becomes
    /// the timeline's start, which is how a reel delivered at 01:00:00:00 is made
    /// to begin where the picture does.
    ///
    /// Content keeps its absolute timecode, so everything shifts back by the same
    /// amount and the region lands on frame 0 - `updateConfig` performs that
    /// shift. The end timecode moves with the start, so the timeline's duration
    /// is unchanged rather than being silently shortened by the difference.
    ///
    /// - Parameter frame: A frame relative to the current start. Frame 0 is a
    ///   no-op, since the timeline already starts there.
    func setTimelineStart(toFrame frame: Int) {
        guard frame != 0 else { return }

        var config = timeline.config
        // Read before mutating: `durationFrames` is derived from both ends, so
        // reading it after moving the start would give the wrong span.
        let durationFrames = config.durationFrames
        let newStartFrames = config.startTimecode.frameCount.wholeFrames + frame

        config.startTimecode = Timecode(.frames(newStartFrames), at: config.frameRate, by: .clamping)
        config.endTimecode = Timecode(
            .frames(newStartFrames + durationFrames),
            at: config.frameRate,
            by: .clamping
        )
        updateConfig(config)
    }

    /// Set the frame rate for the timeline
    func setFrameRate(_ frameRate: TimecodeFrameRate) {
        var config = timeline.config
        config.frameRate = frameRate
        timeline.config = config
    }

    /// Set the timeline bounds.
    ///
    /// When the start timecode changes, all content (video reels and audio clips)
    /// is shifted to maintain their absolute timecode positions.
    ///
    /// - Parameters:
    ///   - start: The new start timecode
    ///   - end: The new end timecode
    func setTimelineBounds(start: Timecode, end: Timecode) {
        let oldStartFrames = timeline.config.startTimecode.frameCount.wholeFrames
        let newStartFrames = start.frameCount.wholeFrames
        let delta = oldStartFrames - newStartFrames

        var config = timeline.config
        config.startTimecode = start
        config.endTimecode = end
        timeline.config = config

        // If start timecode changed, shift all content to maintain absolute timecode positions
        if delta != 0 {
            shiftAllContent(by: delta)
        }
    }

    /// Shift all video reels and audio clips by the specified frame delta.
    ///
    /// Used when timeline start changes to maintain absolute timecode positions.
    ///
    /// - Parameter delta: Number of frames to shift (positive = later, negative = earlier)
    private func shiftAllContent(by delta: Int) {
        // Shift video reels
        for i in timeline.videoReels.indices {
            timeline.videoReels[i].timelineStartFrame += delta
        }

        // Shift audio clips in all lanes
        for laneIndex in timeline.audioLanes.indices {
            for clipIndex in timeline.audioLanes[laneIndex].clips.indices {
                timeline.audioLanes[laneIndex].clips[clipIndex].timelineStartFrame += delta
            }
        }
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

    /// Shrink the timeline to fit content plus padding.
    ///
    /// Called after content deletion. Finds the rightmost content and sets
    /// the timeline end to that position plus standard padding. Never shrinks
    /// below the default 2-hour minimum.
    func shrinkTimelineToContent() {
        let config = timeline.config

        // Find rightmost content frame
        let videoEnd = timeline.videoReels.map { $0.timelineEndFrame }.max() ?? 0
        let audioEnd = timeline.audioLanes.flatMap { $0.clips }.map { $0.timelineEndFrame }.max() ?? 0
        let rightmostContent = max(videoEnd, audioEnd)

        // Calculate minimum duration (at least default 2 hours, or content + padding)
        let paddingFrames = Int(Self.defaultPaddingMinutes * 60.0 * config.frameRate.fps)
        let minimumDuration = 2 * 60 * 60 * Int(config.frameRate.fps)  // 2 hours in frames
        let targetEnd = max(minimumDuration, rightmostContent + paddingFrames)

        // Only shrink if current duration is larger
        if targetEnd < config.durationFrames {
            var newConfig = config
            newConfig.endTimecode = Timecode(
                .frames(config.startTimecode.frameCount.wholeFrames + targetEnd),
                at: config.frameRate,
                by: .clamping
            )
            timeline.config = newConfig
        }
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
        shrinkTimelineToContent()
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

        // Auto-extend timeline if reel now exceeds duration
        let reelEndFrame = newFrame + reel.durationFrames
        if reelEndFrame > timeline.config.durationFrames {
            let paddingFrames = Int(Self.defaultPaddingMinutes * 60.0 * timeline.config.frameRate.fps)
            extendTimelineIfNeeded(toEndFrame: reelEndFrame + paddingFrames)
        }

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

    /// Rename a video reel.
    ///
    /// Passing an empty name clears the override so `displayName` falls back to
    /// the source filename, which is what an emptied rename field should mean.
    func renameVideoReel(id: UUID, name: String) {
        if var reel = timeline.videoReels.first(where: { $0.id == id }) {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            reel.name = trimmed.isEmpty ? nil : trimmed
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

    /// Move one reel's video audio onto a lane per channel.
    ///
    /// Used when a hard-panned video is split. The reel's clip is replaced by two
    /// mono clips, one per side, each appended to the shared lane for that side -
    /// created on first use and reused by every later split. Six split reels
    /// therefore produce two lanes holding six clips each, not twelve lanes, so
    /// an output is chosen once per side rather than once per reel.
    ///
    /// Only the reel's own clip moves. Reels dropped together are laid end to end
    /// and share a lane, and an earlier version replaced that whole lane - which
    /// silently destroyed the audio of every other reel on it.
    ///
    /// Each lane spans a full stereo output (`outputChannelCount` 2) even though
    /// its clips are mono. That pairing is what un-pans the split: the mixer sees
    /// one input channel and two output channels, and duplicates the input
    /// across both, so a side that was hard left comes back centred. Setting the
    /// lane to one output channel instead would map it to a single speaker and
    /// reproduce the very panning the split is meant to undo.
    ///
    /// - Parameters:
    ///   - clipId: The reel's clip on `laneId`.
    ///   - laneId: The video-audio lane currently holding that clip.
    ///   - reelId: The reel being split.
    ///   - names: Display name for each side, used when a lane is first created.
    /// - Returns: The lanes now holding the reel's audio, left then right, or
    ///   `nil` if the clip could not be found.
    @discardableResult
    func splitVideoAudioClipByChannel(
        clipId: UUID,
        inLane laneId: UUID,
        reelId: UUID,
        names: [SplitChannel: String]
    ) -> [AudioLane]? {
        guard let laneIndex = timeline.audioLanes.firstIndex(where: { $0.id == laneId }),
              let sourceClip = timeline.audioLanes[laneIndex].clips.first(where: { $0.id == clipId }) else {
            return nil
        }

        let original = timeline.audioLanes[laneIndex]
        var destinations: [AudioLane] = []

        for channel in SplitChannel.allCases {
            let clip = AudioClip(
                mediaItemId: sourceClip.mediaItemId,
                sourceURL: sourceClip.sourceURL,
                sourceBookmark: sourceClip.sourceBookmark,
                timelineStartFrame: sourceClip.timelineStartFrame,
                durationFrames: sourceClip.durationFrames,
                sourceStartFrame: sourceClip.sourceStartFrame,
                sourceType: sourceClip.sourceType,
                sourceTrackIndex: sourceClip.sourceTrackIndex,
                volume: sourceClip.volume,
                isMuted: sourceClip.isMuted,
                name: names[channel],
                channelCount: 1,
                sampleRate: sourceClip.sampleRate,
                // Cleared deliberately: the existing extraction is the whole
                // stereo track, and using it here would play both sides on both
                // lanes. The per-channel file replaces it once written.
                extractedAudioURL: nil,
                sourceFrameRate: sourceClip.sourceFrameRate,
                sourceChannel: channel
            )

            // Reuse the side's existing lane if a reel has already been split,
            // so every split reel's left channel lands on one lane and every
            // right channel on another.
            if let existing = timeline.audioLanes.first(where: { $0.splitChannel == channel }) {
                timeline.addClip(clip, toLane: existing.id)
                if let updated = timeline.audioLanes.first(where: { $0.id == existing.id }) {
                    destinations.append(updated)
                }
                continue
            }

            let lane = AudioLane(
                name: names[channel] ?? channel.conventionalRoleName,
                clips: [clip],
                isMuted: original.isMuted,
                isSolo: original.isSolo,
                volume: original.volume,
                outputChannelOffset: original.outputChannelOffset,
                outputChannelCount: 2,
                outputDeviceUID: original.outputDeviceUID,
                // Both sides inherit where the video's audio was already going.
                //
                // Splitting is a change to how the audio is *organized*, not to
                // where it comes out. Pre-assigning the pair to the DX/SFX and MX
                // roles reads as helpful, but on a large interface those roles sit
                // high in the channel list - so the video's sound left the monitor
                // path the instant it was split, which is indistinguishable from
                // playback having broken. Inheriting keeps it audible; the lane's
                // own output menu is how it gets moved.
                outputMappingId: original.outputMappingId,
                isOutputDisabled: original.isOutputDisabled,
                colorIndex: (original.colorIndex + channel.channelIndex) % 8,
                // Left unset: the lane is shared by every split reel, so no one
                // reel owns it. `splitChannel` is what marks it as video audio.
                ownerVideoReelId: nil,
                splitChannel: channel
            )
            // Placed below the lane being split rather than above it, so the
            // original keeps its index while the pair is inserted and any other
            // reel's audio still sitting on it stays put.
            timeline.insertAudioLane(lane, at: laneIndex + 1 + destinations.count)
            destinations.append(lane)
        }

        // Only this reel's clip leaves the original lane. Any other reel's audio
        // stays exactly where it was; the lane goes only once it is empty.
        guard let currentIndex = timeline.audioLanes.firstIndex(where: { $0.id == laneId }) else {
            return destinations
        }
        timeline.audioLanes[currentIndex].clips.removeAll { $0.id == clipId }
        if timeline.audioLanes[currentIndex].clips.isEmpty {
            timeline.removeAudioLane(id: laneId)
        }

        return destinations
    }


    /// Remove a reel's split audio, leaving other reels' audio in place.
    ///
    /// Called when the video goes: its split channels have no meaning without
    /// it. Split lanes are shared, so this takes the reel's clips rather than
    /// the lanes - dropping a whole lane would delete every other split reel's
    /// audio with it. A lane emptied by the removal goes too, since an empty
    /// split lane is just clutter.
    ///
    /// Lanes owned outright are still removed whole. Those come from projects
    /// saved before splits were shared, where a lane really did belong to one
    /// reel.
    ///
    /// - Parameters:
    ///   - reelId: The reel being removed.
    ///   - sourceURL: That reel's media, used to find its clips on shared lanes.
    func removeLanesOwned(byReel reelId: UUID, sourceURL: URL? = nil) {
        for lane in timeline.audioLanes where lane.ownerVideoReelId == reelId {
            timeline.removeAudioLane(id: lane.id)
        }

        guard let sourceURL else { return }
        for lane in timeline.audioLanes where lane.splitChannel != nil {
            guard let index = timeline.audioLanes.firstIndex(where: { $0.id == lane.id }) else { continue }
            timeline.audioLanes[index].clips.removeAll { $0.sourceURL == sourceURL }
            if timeline.audioLanes[index].clips.isEmpty {
                timeline.removeAudioLane(id: lane.id)
            }
        }
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
    ///
    /// `MappedAudioOutput.channelStart`, `AudioLane.outputChannelOffset` and the
    /// engine's `outputOffset` are all 0-based indices into the device's output
    /// buffer, so the mapping's channel carries across unchanged. Only the UI
    /// converts, printing `channelStart + 1` for the 1-based numbers on the
    /// hardware. Subtracting here sent every output that does not start on
    /// channel 1 a channel low - MX on "Out 3-4" reached hardware 2-3.
    func setLaneOutputMapping(id: UUID, mapping: MappedAudioOutput?) {
        if var lane = timeline.audioLanes.first(where: { $0.id == id }) {
            lane.outputMappingId = mapping?.id
            // Choosing a destination undoes None.
            lane.isOutputDisabled = false
            if let mapping = mapping {
                lane.outputChannelOffset = max(0, mapping.channelStart)
                lane.outputChannelCount = max(1, mapping.channelCount)
            } else {
                lane.outputChannelOffset = 0
                lane.outputChannelCount = 2
            }
            timeline.updateAudioLane(lane)
        }
    }

    /// Route a lane to nothing, silencing it.
    ///
    /// The lane keeps its clips, its volume and its mute state - only its
    /// destination is removed. Choosing any output through
    /// ``setLaneOutputMapping(id:mapping:)`` restores it.
    ///
    /// - Parameter id: The lane to silence.
    func disableLaneOutput(id: UUID) {
        if var lane = timeline.audioLanes.first(where: { $0.id == id }) {
            lane.isOutputDisabled = true
            lane.outputMappingId = nil
            timeline.updateAudioLane(lane)
        }
    }

    /// Reorder an audio lane to a new position.
    ///
    /// - Parameters:
    ///   - fromIndex: Source position of the lane
    ///   - toIndex: Target position for the lane
    func moveAudioLane(from fromIndex: Int, to toIndex: Int) {
        timeline.moveLane(from: fromIndex, to: toIndex)
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
        shrinkTimelineToContent()
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

        // Auto-extend timeline if clip now exceeds duration
        let clipEndFrame = newFrame + clip.durationFrames
        if clipEndFrame > timeline.config.durationFrames {
            let paddingFrames = Int(Self.defaultPaddingMinutes * 60.0 * timeline.config.frameRate.fps)
            extendTimelineIfNeeded(toEndFrame: clipEndFrame + paddingFrames)
        }

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
// TimelineError is now defined in TimelineServiceProtocol.swift

// MARK: - Audio Routing Authority
//
// One place decides how lanes follow the outputs defined in Settings. The
// dropdowns render whatever these rules produce; they never resolve routing
// themselves:
//
//  1. NAMES ARE NOT COPIED. A lane stores the mapping's identity, and the menu
//     reads the current name from Settings - so renaming "MX" to "Music" in
//     Settings retitles every lane using it, with nothing to keep in sync.
//
//  2. A LANE KEEPS ITS MAPPING WHILE THAT MAPPING EXISTS.
//
//  3. IF A MAPPING DISAPPEARS, MATCH THE CHANNELS. Switching interfaces
//     replaces every mapping with new identities, but a lane sent to channels
//     3-4 still means channels 3-4. Re-binding by channel range keeps a project
//     routed correctly across a device change.
//
//  4. OTHERWISE CLEAR IT. An unresolvable mapping shows as "NONE" rather than
//     silently routing audio somewhere the user did not choose.
//
//  5. NONE IS LEFT ALONE. A lane the user routed to None is not an unassigned
//     lane waiting to be filled in - it is silent on purpose, and no rule above
//     applies to it.

extension TimelineManager {
    /// Re-bind lanes after the set of configured outputs changes.
    ///
    /// - Parameter outputs: The outputs currently defined for the active device.
    func reconcileOutputMappings(with outputs: [MappedAudioOutput]) {
        guard !outputs.isEmpty else { return }
        let byId = Dictionary(uniqueKeysWithValues: outputs.map { ($0.id, $0) })

        for lane in timeline.audioLanes {
            // Rule 5: None is a choice, not an absence. Re-binding by channel
            // would otherwise adopt whichever output sits on the channels the
            // lane happened to keep, quietly un-silencing it.
            if lane.isOutputDisabled { continue }

            // Rule 2.
            if let id = lane.outputMappingId, byId[id] != nil { continue }

            // Rule 3: same channels, new identity. Compared the same way
            // `setLaneOutputMapping` assigns, so a lane re-binds to the output it
            // is actually playing out of.
            let match = outputs.first {
                max(0, $0.channelStart) == lane.outputChannelOffset
                    && max(1, $0.channelCount) == lane.outputChannelCount
            }

            // Rule 4 when there is no match.
            setLaneOutputMapping(id: lane.id, mapping: match)
        }
    }
}
