import Foundation
import SwiftTimecodeCore

/// Type of audio source
enum AudioSourceType: String, Codable {
    /// Audio extracted from a video file's audio track
    case videoTrack
    /// Standalone audio file (WAV, AIFF, etc.)
    case audioFile
}

/// Represents an audio clip placed on an audio lane
struct AudioClip: Identifiable, Codable, Equatable {
    /// Unique identifier for the clip
    let id: UUID

    /// Source file URL (video file for videoTrack, audio file for audioFile)
    var sourceURL: URL

    /// Security-scoped bookmark for sandbox access
    var sourceBookmark: Data?

    /// Position on the master timeline (in frames from timeline start)
    var timelineStartFrame: Int

    /// Duration of the clip on the timeline (in frames)
    var durationFrames: Int

    /// In-point within the source file (in source frames)
    var sourceStartFrame: Int

    /// Type of audio source
    var sourceType: AudioSourceType

    /// Track index within source file (for videoTrack type)
    var sourceTrackIndex: Int?

    /// Clip volume (0.0 to 1.0)
    var volume: Float

    /// Whether this clip is muted
    var isMuted: Bool

    /// Display name (derived from filename if not set)
    var name: String?

    /// Channel count of the source audio
    var channelCount: Int

    /// Sample rate of the source audio
    var sampleRate: Double

    /// End frame on timeline (exclusive)
    var timelineEndFrame: Int {
        timelineStartFrame + durationFrames
    }

    /// Computed display name
    var displayName: String {
        if let name = name {
            return name
        }
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        if let trackIndex = sourceTrackIndex {
            return "\(baseName) - Track \(trackIndex + 1)"
        }
        return baseName
    }

    init(
        id: UUID = UUID(),
        sourceURL: URL,
        sourceBookmark: Data? = nil,
        timelineStartFrame: Int,
        durationFrames: Int,
        sourceStartFrame: Int = 0,
        sourceType: AudioSourceType = .audioFile,
        sourceTrackIndex: Int? = nil,
        volume: Float = 1.0,
        isMuted: Bool = false,
        name: String? = nil,
        channelCount: Int = 2,
        sampleRate: Double = 48000
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.sourceBookmark = sourceBookmark
        self.timelineStartFrame = timelineStartFrame
        self.durationFrames = durationFrames
        self.sourceStartFrame = sourceStartFrame
        self.sourceType = sourceType
        self.sourceTrackIndex = sourceTrackIndex
        self.volume = volume
        self.isMuted = isMuted
        self.name = name
        self.channelCount = channelCount
        self.sampleRate = sampleRate
    }

    /// Check if this clip is active at a given timeline frame
    func isActive(at frame: Int) -> Bool {
        frame >= timelineStartFrame && frame < timelineEndFrame
    }

    /// Convert a timeline frame to a source frame
    /// Returns nil if the timeline frame is outside this clip's range
    func sourceFrame(at timelineFrame: Int) -> Int? {
        guard isActive(at: timelineFrame) else { return nil }
        return sourceStartFrame + (timelineFrame - timelineStartFrame)
    }

    /// Convert a timeline frame to source time in seconds
    /// Uses the master timeline frame rate for conversion
    func sourceTime(at timelineFrame: Int, masterFrameRate: TimecodeFrameRate) -> Double? {
        guard let frame = sourceFrame(at: timelineFrame) else { return nil }
        return Double(frame) / masterFrameRate.fps
    }
}

// MARK: - Codable Conformance

extension AudioClip {
    enum CodingKeys: String, CodingKey {
        case id
        case sourcePath
        case sourceBookmark
        case timelineStartFrame
        case durationFrames
        case sourceStartFrame
        case sourceType
        case sourceTrackIndex
        case volume
        case isMuted
        case name
        case channelCount
        case sampleRate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        let sourcePath = try container.decode(String.self, forKey: .sourcePath)
        sourceURL = URL(fileURLWithPath: sourcePath)
        sourceBookmark = try container.decodeIfPresent(Data.self, forKey: .sourceBookmark)
        timelineStartFrame = try container.decode(Int.self, forKey: .timelineStartFrame)
        durationFrames = try container.decode(Int.self, forKey: .durationFrames)
        sourceStartFrame = try container.decode(Int.self, forKey: .sourceStartFrame)
        sourceType = try container.decode(AudioSourceType.self, forKey: .sourceType)
        sourceTrackIndex = try container.decodeIfPresent(Int.self, forKey: .sourceTrackIndex)
        volume = try container.decode(Float.self, forKey: .volume)
        isMuted = try container.decode(Bool.self, forKey: .isMuted)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        channelCount = try container.decodeIfPresent(Int.self, forKey: .channelCount) ?? 2
        sampleRate = try container.decodeIfPresent(Double.self, forKey: .sampleRate) ?? 48000
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(id, forKey: .id)
        try container.encode(sourceURL.path, forKey: .sourcePath)
        try container.encodeIfPresent(sourceBookmark, forKey: .sourceBookmark)
        try container.encode(timelineStartFrame, forKey: .timelineStartFrame)
        try container.encode(durationFrames, forKey: .durationFrames)
        try container.encode(sourceStartFrame, forKey: .sourceStartFrame)
        try container.encode(sourceType, forKey: .sourceType)
        try container.encodeIfPresent(sourceTrackIndex, forKey: .sourceTrackIndex)
        try container.encode(volume, forKey: .volume)
        try container.encode(isMuted, forKey: .isMuted)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encode(channelCount, forKey: .channelCount)
        try container.encode(sampleRate, forKey: .sampleRate)
    }
}
