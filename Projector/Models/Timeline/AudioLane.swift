import Foundation

/// Represents an audio lane containing multiple audio clips
public struct AudioLane: Identifiable, Codable, Equatable, Sendable {
    /// Unique identifier for the lane
    public let id: UUID

    /// Display name for the lane
    public var name: String

    /// Audio clips in this lane, sorted by timeline position
    public var clips: [AudioClip]

    /// Whether this lane is muted
    public var isMuted: Bool

    /// Whether this lane is soloed
    public var isSolo: Bool

    /// Lane volume (0.0 to 1.0)
    public var volume: Float

    /// Starting channel on the output device (0-indexed)
    public var outputChannelOffset: Int

    /// Number of output channels to use (1 = mono, 2 = stereo)
    public var outputChannelCount: Int

    /// Output device UID (nil = use global/system default)
    public var outputDeviceUID: String?

    /// Mapped output selection ID
    public var outputMappingId: UUID?

    /// Whether the lane is routed to no output at all.
    ///
    /// Distinct from `outputMappingId == nil`, which means "not yet assigned" and
    /// falls back to the first pair - this means the user chose **None**, and the
    /// lane is silent until they choose otherwise. Kept apart from `isMuted` so
    /// the two controls do not fight: mute is a transport state the M button
    /// toggles, this is where the lane's audio goes.
    public var isOutputDisabled: Bool

    /// Color index for visual distinction
    public var colorIndex: Int

    /// The video reel this lane belongs to, when it is not a lane the user made.
    ///
    /// Set on the lanes created by splitting a hard-panned video: they carry
    /// that video's audio and nothing else, so they are owned by it. An owned
    /// lane cannot be deleted on its own and goes away with the video.
    ///
    /// Recorded rather than inferred. The single video-audio lane is recognized
    /// by inspecting its clips (see `Timeline.videoAudioLanes`), which works
    /// while there is only one but cannot say which of a split *pair* is which,
    /// nor survive the user rearranging clips. Optional so projects saved before
    /// splitting existed still decode, and those fall back to the derived rule.
    public var ownerVideoReelId: UUID?

    /// Which side of a hard-panned source this lane carries.
    ///
    /// `nil` for every ordinary lane. Paired with `ownerVideoReelId` it names
    /// the lane exactly: "the left side of that reel".
    public var splitChannel: SplitChannel?

    /// Whether this lane is owned by a video and cannot stand alone.
    public var isLockedToVideo: Bool {
        ownerVideoReelId != nil
    }

    public init(
        id: UUID = UUID(),
        name: String,
        clips: [AudioClip] = [],
        isMuted: Bool = false,
        isSolo: Bool = false,
        volume: Float = 1.0,
        outputChannelOffset: Int = 0,
        outputChannelCount: Int = 2,
        outputDeviceUID: String? = nil,
        outputMappingId: UUID? = nil,
        isOutputDisabled: Bool = false,
        colorIndex: Int = 0,
        ownerVideoReelId: UUID? = nil,
        splitChannel: SplitChannel? = nil
    ) {
        self.id = id
        self.name = name
        self.clips = clips
        self.isMuted = isMuted
        self.isSolo = isSolo
        self.volume = volume
        self.outputChannelOffset = outputChannelOffset
        self.outputChannelCount = outputChannelCount
        self.outputDeviceUID = outputDeviceUID
        self.outputMappingId = outputMappingId
        self.isOutputDisabled = isOutputDisabled
        self.colorIndex = colorIndex
        self.ownerVideoReelId = ownerVideoReelId
        self.splitChannel = splitChannel
    }

    /// Get all clips active at a given timeline frame
    public func activeClips(at frame: Int) -> [AudioClip] {
        clips.filter { $0.isActive(at: frame) }
    }

    /// Add a clip to the lane, maintaining sorted order
    public mutating func addClip(_ clip: AudioClip) {
        clips.append(clip)
        clips.sort { $0.timelineStartFrame < $1.timelineStartFrame }
    }

    /// Remove a clip by ID
    public mutating func removeClip(id: UUID) {
        clips.removeAll { $0.id == id }
    }

    /// Update a clip by ID
    public mutating func updateClip(_ updatedClip: AudioClip) {
        if let index = clips.firstIndex(where: { $0.id == updatedClip.id }) {
            clips[index] = updatedClip
            clips.sort { $0.timelineStartFrame < $1.timelineStartFrame }
        }
    }

    /// Check if adding a clip would overlap with existing clips
    public func hasOverlap(with newClip: AudioClip, excluding clipId: UUID? = nil) -> Bool {
        for clip in clips {
            if clip.id == clipId { continue }

            // Check for overlap
            let newStart = newClip.timelineStartFrame
            let newEnd = newClip.timelineEndFrame
            let existingStart = clip.timelineStartFrame
            let existingEnd = clip.timelineEndFrame

            if newStart < existingEnd && newEnd > existingStart {
                return true
            }
        }
        return false
    }

    /// Get the next available position after all clips
    public var nextAvailableFrame: Int {
        clips.map { $0.timelineEndFrame }.max() ?? 0
    }
}

// MARK: - Codable

extension AudioLane {
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case clips
        case isMuted
        case isSolo
        case volume
        case outputChannelOffset
        case outputChannelCount
        case outputDeviceUID
        case outputMappingId
        case isOutputDisabled
        case ownerVideoReelId
        case splitChannel
        case colorIndex
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        clips = try container.decode([AudioClip].self, forKey: .clips)
        isMuted = try container.decode(Bool.self, forKey: .isMuted)
        isSolo = try container.decode(Bool.self, forKey: .isSolo)
        volume = try container.decode(Float.self, forKey: .volume)
        outputChannelOffset = try container.decodeIfPresent(Int.self, forKey: .outputChannelOffset) ?? 0
        outputChannelCount = try container.decodeIfPresent(Int.self, forKey: .outputChannelCount) ?? 2
        outputDeviceUID = try container.decodeIfPresent(String.self, forKey: .outputDeviceUID)
        outputMappingId = try container.decodeIfPresent(UUID.self, forKey: .outputMappingId)
        // Absent in projects saved before None existed, which routed everywhere.
        isOutputDisabled = try container.decodeIfPresent(Bool.self, forKey: .isOutputDisabled) ?? false
        ownerVideoReelId = try container.decodeIfPresent(UUID.self, forKey: .ownerVideoReelId)
        splitChannel = try container.decodeIfPresent(SplitChannel.self, forKey: .splitChannel)
        colorIndex = try container.decode(Int.self, forKey: .colorIndex)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(clips, forKey: .clips)
        try container.encode(isMuted, forKey: .isMuted)
        try container.encode(isSolo, forKey: .isSolo)
        try container.encode(volume, forKey: .volume)
        try container.encode(outputChannelOffset, forKey: .outputChannelOffset)
        try container.encode(outputChannelCount, forKey: .outputChannelCount)
        try container.encodeIfPresent(outputDeviceUID, forKey: .outputDeviceUID)
        try container.encodeIfPresent(outputMappingId, forKey: .outputMappingId)
        try container.encode(isOutputDisabled, forKey: .isOutputDisabled)
        try container.encodeIfPresent(ownerVideoReelId, forKey: .ownerVideoReelId)
        try container.encodeIfPresent(splitChannel, forKey: .splitChannel)
        try container.encode(colorIndex, forKey: .colorIndex)
    }
}
