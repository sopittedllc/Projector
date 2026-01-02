import Foundation
import SwiftTimecodeCore

/// Master timeline containing video reels and audio lanes
struct Timeline: Codable, Equatable {
    /// Timeline configuration (start/end, frame rate)
    var config: TimelineConfig

    /// Video reels on the timeline
    var videoReels: [VideoReel]

    /// Audio lanes on the timeline
    var audioLanes: [AudioLane]

    /// Default empty timeline
    static var empty: Timeline {
        Timeline(
            config: .default,
            videoReels: [],
            audioLanes: []
        )
    }

    init(
        config: TimelineConfig = .default,
        videoReels: [VideoReel] = [],
        audioLanes: [AudioLane] = []
    ) {
        self.config = config
        self.videoReels = videoReels
        self.audioLanes = audioLanes
    }

    // MARK: - Video Reel Queries

    /// Get the video reel active at a given timeline frame
    func videoReel(at frame: Int) -> VideoReel? {
        videoReels.first { $0.isActive(at: frame) }
    }

    /// Get all video reels sorted by timeline position
    var sortedVideoReels: [VideoReel] {
        videoReels.sorted { $0.timelineStartFrame < $1.timelineStartFrame }
    }

    /// Check if a frame is within a gap (no video)
    func isVideoGap(at frame: Int) -> Bool {
        videoReel(at: frame) == nil
    }

    // MARK: - Audio Lane Queries

    /// Get all active audio clips at a given timeline frame
    func activeAudioClips(at frame: Int) -> [(lane: AudioLane, clip: AudioClip)] {
        var result: [(lane: AudioLane, clip: AudioClip)] = []

        // Check for solo lanes first
        let soloLanes = audioLanes.filter { $0.isSolo }
        let lanesToCheck = soloLanes.isEmpty ? audioLanes : soloLanes

        for lane in lanesToCheck {
            if lane.isMuted { continue }

            for clip in lane.activeClips(at: frame) {
                if !clip.isMuted {
                    result.append((lane: lane, clip: clip))
                }
            }
        }

        return result
    }

    /// Get all audio clips across all lanes
    var allAudioClips: [AudioClip] {
        audioLanes.flatMap { $0.clips }
    }

    // MARK: - Video Reel Mutations

    /// Add a video reel to the timeline
    mutating func addVideoReel(_ reel: VideoReel) {
        videoReels.append(reel)
        videoReels.sort { $0.timelineStartFrame < $1.timelineStartFrame }
    }

    /// Remove a video reel by ID
    mutating func removeVideoReel(id: UUID) {
        videoReels.removeAll { $0.id == id }
    }

    /// Update a video reel
    mutating func updateVideoReel(_ reel: VideoReel) {
        if let index = videoReels.firstIndex(where: { $0.id == reel.id }) {
            videoReels[index] = reel
            videoReels.sort { $0.timelineStartFrame < $1.timelineStartFrame }
        }
    }

    // MARK: - Audio Lane Mutations

    /// Add an audio lane
    mutating func addAudioLane(_ lane: AudioLane) {
        audioLanes.append(lane)
    }

    /// Remove an audio lane by ID
    mutating func removeAudioLane(id: UUID) {
        audioLanes.removeAll { $0.id == id }
    }

    /// Update an audio lane
    mutating func updateAudioLane(_ lane: AudioLane) {
        if let index = audioLanes.firstIndex(where: { $0.id == lane.id }) {
            audioLanes[index] = lane
        }
    }

    /// Add a clip to a lane
    mutating func addClip(_ clip: AudioClip, toLane laneId: UUID) {
        if let index = audioLanes.firstIndex(where: { $0.id == laneId }) {
            audioLanes[index].addClip(clip)
        }
    }

    /// Remove a clip from a lane
    mutating func removeClip(clipId: UUID, fromLane laneId: UUID) {
        if let index = audioLanes.firstIndex(where: { $0.id == laneId }) {
            audioLanes[index].removeClip(id: clipId)
        }
    }

    // MARK: - Timeline Range

    /// Get the range of frames that contain content (video or audio)
    var contentRange: ClosedRange<Int>? {
        var minFrame = Int.max
        var maxFrame = Int.min

        for reel in videoReels {
            minFrame = min(minFrame, reel.timelineStartFrame)
            maxFrame = max(maxFrame, reel.timelineEndFrame)
        }

        for lane in audioLanes {
            for clip in lane.clips {
                minFrame = min(minFrame, clip.timelineStartFrame)
                maxFrame = max(maxFrame, clip.timelineEndFrame)
            }
        }

        if minFrame > maxFrame {
            return nil
        }

        return minFrame...maxFrame
    }

    /// Total duration of content in seconds
    var contentDuration: Double {
        guard let range = contentRange else { return 0 }
        return Double(range.count) / config.frameRate.fps
    }
}

// MARK: - Frame Rate Conversion Helpers

extension Timeline {
    /// Convert a frame count from one frame rate to another
    static func convertFrames(_ frames: Int, from sourceRate: TimecodeFrameRate, to destRate: TimecodeFrameRate) -> Int {
        if sourceRate == destRate { return frames }
        let seconds = Double(frames) / sourceRate.fps
        return Int(seconds * destRate.fps)
    }
}
