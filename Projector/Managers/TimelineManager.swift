import Foundation
import SwiftTimecodeCore
import Combine
import AVFoundation

/// Manages timeline state and CRUD operations for video reels and audio clips
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

    // MARK: - Video Reel Operations

    /// Add a video reel from a file URL
    func addVideoReel(from url: URL, at timelineFrame: Int) async throws -> VideoReel {
        // Create security-scoped bookmark
        let bookmark = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        // Get video metadata
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)

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

        let durationFrames = Int(duration.seconds * frameRate.fps)

        let reel = VideoReel(
            sourceURL: url,
            sourceBookmark: bookmark,
            timelineStartFrame: timelineFrame,
            durationFrames: durationFrames,
            sourceStartFrame: 0,
            sourceFrameRate: frameRate
        )

        timeline.addVideoReel(reel)
        return reel
    }

    /// Remove a video reel by ID
    func removeVideoReel(id: UUID) {
        timeline.removeVideoReel(id: id)
    }

    /// Move a video reel to a new timeline position
    func moveVideoReel(id: UUID, to newFrame: Int) {
        if var reel = timeline.videoReels.first(where: { $0.id == id }) {
            reel.timelineStartFrame = newFrame
            timeline.updateVideoReel(reel)
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

        // Create security-scoped bookmark
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

        timeline.addClip(clip, toLane: laneId)
        return clip
    }

    /// Extract audio from a video reel and add it to a lane
    func extractAudioFromReel(_ reelId: UUID, trackIndex: Int, toLane laneId: UUID) async throws -> AudioClip? {
        guard let reel = timeline.videoReels.first(where: { $0.id == reelId }),
              timeline.audioLanes.contains(where: { $0.id == laneId }) else {
            return nil
        }

        // Get audio track info from the video
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
            sourceURL: reel.sourceURL,
            sourceBookmark: reel.sourceBookmark,
            timelineStartFrame: reel.timelineStartFrame,
            durationFrames: reel.durationFrames,
            sourceStartFrame: reel.sourceStartFrame,
            sourceType: .videoTrack,
            sourceTrackIndex: trackIndex,
            channelCount: channelCount,
            sampleRate: sampleRate
        )

        timeline.addClip(clip, toLane: laneId)
        return clip
    }

    /// Remove an audio clip from a lane
    func removeAudioClip(clipId: UUID, fromLane laneId: UUID) {
        timeline.removeClip(clipId: clipId, fromLane: laneId)
    }

    /// Move an audio clip to a new position
    func moveAudioClip(clipId: UUID, inLane laneId: UUID, to newFrame: Int) {
        if let laneIndex = timeline.audioLanes.firstIndex(where: { $0.id == laneId }),
           var clip = timeline.audioLanes[laneIndex].clips.first(where: { $0.id == clipId }) {
            clip.timelineStartFrame = newFrame
            timeline.audioLanes[laneIndex].updateClip(clip)
        }
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
