import Foundation

/// Represents an audio lane containing multiple audio clips
struct AudioLane: Identifiable, Codable, Equatable {
    /// Unique identifier for the lane
    let id: UUID

    /// Display name for the lane
    var name: String

    /// Audio clips in this lane, sorted by timeline position
    var clips: [AudioClip]

    /// Whether this lane is muted
    var isMuted: Bool

    /// Whether this lane is soloed
    var isSolo: Bool

    /// Lane volume (0.0 to 1.0)
    var volume: Float

    /// Starting channel on the output device (0-indexed)
    var outputChannelOffset: Int

    /// Number of output channels to use (1 = mono, 2 = stereo)
    var outputChannelCount: Int

    /// Output device UID (nil = use global/system default)
    var outputDeviceUID: String?

    /// Mapped output selection ID
    var outputMappingId: UUID?

    /// Color index for visual distinction
    var colorIndex: Int

    init(
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
        colorIndex: Int = 0
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
        self.colorIndex = colorIndex
    }

    /// Get all clips active at a given timeline frame
    func activeClips(at frame: Int) -> [AudioClip] {
        clips.filter { $0.isActive(at: frame) }
    }

    /// Add a clip to the lane, maintaining sorted order
    mutating func addClip(_ clip: AudioClip) {
        clips.append(clip)
        clips.sort { $0.timelineStartFrame < $1.timelineStartFrame }
    }

    /// Remove a clip by ID
    mutating func removeClip(id: UUID) {
        clips.removeAll { $0.id == id }
    }

    /// Update a clip by ID
    mutating func updateClip(_ updatedClip: AudioClip) {
        if let index = clips.firstIndex(where: { $0.id == updatedClip.id }) {
            clips[index] = updatedClip
            clips.sort { $0.timelineStartFrame < $1.timelineStartFrame }
        }
    }

    /// Check if adding a clip would overlap with existing clips
    func hasOverlap(with newClip: AudioClip, excluding clipId: UUID? = nil) -> Bool {
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
    var nextAvailableFrame: Int {
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
        case colorIndex
    }

    init(from decoder: Decoder) throws {
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
        colorIndex = try container.decode(Int.self, forKey: .colorIndex)
    }

    func encode(to encoder: Encoder) throws {
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
        try container.encode(colorIndex, forKey: .colorIndex)
    }
}
