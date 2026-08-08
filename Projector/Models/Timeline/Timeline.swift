import Foundation
import SwiftTimecodeCore

/// Preview state for linked audio clips being dragged with their parent video reel.
///
/// When a video reel is dragged and has linked audio clips, this preview shows
/// where the linked clips will land on the timeline.
struct LinkedDragPreview: Equatable, Sendable {
    /// Source URL of the linked audio clip
    let sourceURL: URL
    /// Starting frame in the source media
    let sourceStartFrame: Int
    /// Duration of the clip in frames
    let durationFrames: Int
    /// Original timeline position (frames)
    let fromFrame: Int
    /// Target timeline position (frames)
    let toFrame: Int
}

/// Preview state for vertical lane change drag (audio clip moving between lanes).
///
/// Displayed when an audio clip is being dragged vertically to a different lane,
/// showing where the clip will land and whether the drop is valid.
struct LaneChangePreview: Equatable, Sendable {
    /// ID of the clip being dragged
    let clipId: UUID
    /// Starting frame position on the timeline
    let timelineStartFrame: Int
    /// Duration of the clip in frames
    let durationFrames: Int
    /// Index of the lane the clip is being dragged from
    let sourceLaneIndex: Int
    /// Index of the lane the clip will be dropped into
    let targetLaneIndex: Int
    /// Whether the drop target is valid (no overlapping clips)
    let isValidDrop: Bool
}

/// Master timeline containing video reels and audio lanes
struct Timeline: Codable, Equatable, Sendable {
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

    // MARK: - Content Extent

    /// The first frame anything sits on, counting reels and audio clips alike.
    ///
    /// `nil` for an empty timeline, which is the case a caller has to handle
    /// separately rather than treating as frame 0 - there is a difference between
    /// "the content starts at the beginning" and "there is no content".
    ///
    /// Lives on the model rather than being gathered at the call site because
    /// two features ask the same question - framing an import, and snapping the
    /// timeline's start to the head of the programme - and they must not be able
    /// to disagree about what counts as content.
    var earliestContentFrame: Int? {
        var earliest: Int?

        for reel in videoReels {
            earliest = min(earliest ?? reel.timelineStartFrame, reel.timelineStartFrame)
        }
        for lane in audioLanes {
            for clip in lane.clips {
                earliest = min(earliest ?? clip.timelineStartFrame, clip.timelineStartFrame)
            }
        }

        return earliest
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
            // Routed to None: there is nowhere for this lane's audio to go, so
            // it is silent. Enforced here rather than in the engine because this
            // is the one place that decides what sounds.
            if lane.isOutputDisabled { continue }

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

    /// Add an audio lane at the top (index 0).
    mutating func addAudioLaneAtTop(_ lane: AudioLane) {
        audioLanes.insert(lane, at: 0)
    }

    /// Insert an audio lane at a position, clamped into range.
    mutating func insertAudioLane(_ lane: AudioLane, at index: Int) {
        let position = Swift.max(0, Swift.min(index, audioLanes.count))
        audioLanes.insert(lane, at: position)
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

    /// Move an audio lane from one position to another.
    ///
    /// - Parameters:
    ///   - fromIndex: Source position of the lane
    ///   - toIndex: Target position for the lane
    mutating func moveLane(from fromIndex: Int, to toIndex: Int) {
        guard fromIndex != toIndex,
              fromIndex >= 0, fromIndex < audioLanes.count,
              toIndex >= 0, toIndex < audioLanes.count else { return }

        let lane = audioLanes.remove(at: fromIndex)
        audioLanes.insert(lane, at: toIndex)
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

// MARK: - Video File Lane

extension Timeline {
    /// The lane holding audio baked into video files, if one exists.
    ///
    /// Derived from the clips rather than stored on the lane, which keeps
    /// existing project files readable without a migration. A lane qualifies
    /// only if every clip on it came from a video track - a lane holding a mix
    /// could not be presented as "the video file's audio", so nothing else is
    /// allowed to land there (see the drop guards in the timeline view).
    var videoAudioLane: AudioLane? {
        videoAudioLanes.first
    }

    /// Every lane belonging to the video file, in the order they should be drawn.
    ///
    /// There are two once a hard-panned video has been split - one per side -
    /// and one otherwise. Ownership recorded on the lane wins; the derived rule
    /// is the fallback for projects saved before ownership was stored, where a
    /// lane counts if every clip on it came from a video track.
    ///
    /// The two are never mixed. If any lane declares an owner, the derived rule
    /// is not consulted at all - otherwise a split pair would pick up a third,
    /// unowned lane that merely happens to hold video audio.
    var videoAudioLanes: [AudioLane] {
        let owned = audioLanes.filter(\.isLockedToVideo)
        guard owned.isEmpty else {
            return owned.sorted { left, right in
                // Left above right; anything unsided keeps its existing order.
                (left.splitChannel?.channelIndex ?? 0) < (right.splitChannel?.channelIndex ?? 0)
            }
        }

        return audioLanes.filter { lane in
            !lane.clips.isEmpty && lane.clips.allSatisfy { $0.sourceType == .videoTrack }
        }
    }

    /// Audio lanes the user owns - everything except the video file's own audio.
    ///
    /// The video's audio is drawn as part of the combined Video File track, so
    /// it must not also appear in the ordinary lane list.
    var standaloneAudioLanes: [AudioLane] {
        let linkedIds = Set(videoAudioLanes.map(\.id))
        guard !linkedIds.isEmpty else { return audioLanes }
        return audioLanes.filter { !linkedIds.contains($0.id) }
    }
}

// MARK: - Lane Reordering

/// Where a dragged lane would land, given how far it has been dragged.
///
/// Pure arithmetic in its own type because this rule has been wrong twice and is
/// impossible to judge by eye: the failures are a few points wide, and "it feels
/// jumpy" is the only symptom a person can report.
///
/// ## The rule
///
/// A lane changes place once it has been dragged past the halfway point of its
/// neighbour - the behaviour of every list with draggable rows - and then has to be
/// dragged **clear** of that boundary before it changes again.
///
/// ## What it replaced
///
/// First a fixed threshold: reorder once the drag passed 20pt, then count whole
/// rows on top of that. The first swap needed 20pt and every later one a full row,
/// so the gesture was four times more sensitive at the start than after.
///
/// Then plain rounding, which fixed the sensitivity but not the shake: sitting on a
/// midpoint - exactly what a hand does while deciding - flipped the target between
/// two values, and each flip re-animated every lane being pushed aside. The shake
/// was those lanes, not the one in hand. Hence the hysteresis.
struct LaneReorder: Equatable {
    /// Height of one lane row, including the divider under it.
    let rowHeight: CGFloat

    /// How far past a boundary the drag must go before the target changes, in rows.
    let hysteresisRows: CGFloat

    /// - Parameters:
    ///   - source: Index the lane started at.
    ///   - held: Target currently chosen, if any. Passing `nil` means none yet.
    ///   - dragOffset: How far the lane has been dragged vertically, in points.
    ///   - laneCount: How many lanes there are to land among.
    /// - Returns: The index the lane would be inserted at.
    func target(source: Int, held: Int?, dragOffset: CGFloat, laneCount: Int) -> Int {
        guard laneCount > 0, rowHeight > 0 else { return source }

        let rows = dragOffset / rowHeight
        let heldRows = CGFloat((held ?? source) - source)

        let movedRows: CGFloat
        if rows > heldRows + 0.5 + hysteresisRows || rows < heldRows - 0.5 - hysteresisRows {
            movedRows = rows.rounded()
        } else {
            movedRows = heldRows
        }

        return max(0, min(source + Int(movedRows), laneCount - 1))
    }
}
