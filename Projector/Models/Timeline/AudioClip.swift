import Foundation
import SwiftTimecodeCore

/// Type of audio source
public enum AudioSourceType: String, Codable, Sendable {
    /// Audio extracted from a video file's audio track
    case videoTrack
    /// Standalone audio file (WAV, AIFF, etc.)
    case audioFile
}

/// Represents an audio clip placed on an audio lane
public struct AudioClip: Identifiable, Codable, Equatable, Sendable {
    /// Unique identifier for the clip
    public let id: UUID

    /// Reference to the MediaItem in the library (for optimization status lookup)
    /// For videoTrack sources, this references the parent video's MediaItem
    public var mediaItemId: UUID?

    /// Source file URL (video file for videoTrack, audio file for audioFile)
    public var sourceURL: URL

    /// Security-scoped bookmark for sandbox access
    public var sourceBookmark: Data?

    /// Position on the master timeline (in frames from timeline start)
    public var timelineStartFrame: Int

    /// Duration of the clip on the timeline (in frames)
    public var durationFrames: Int

    /// In-point within the source file (in source frames)
    public var sourceStartFrame: Int

    /// Type of audio source
    public var sourceType: AudioSourceType

    /// Track index within source file (for videoTrack type)
    public var sourceTrackIndex: Int?

    /// Clip volume (0.0 to 1.0)
    public var volume: Float

    /// Whether this clip is muted
    public var isMuted: Bool

    /// Display name (derived from filename if not set)
    public var name: String?

    /// Channel count of the source audio
    public var channelCount: Int

    /// Sample rate of the source audio
    public var sampleRate: Double

    /// Pre-extracted audio file URL (for videoTrack sources extracted during import)
    /// This avoids security-scoped resource issues in async contexts
    public var extractedAudioURL: URL?

    /// Source frame rate (for videoTrack sources - needed for sync with video)
    /// This must match the video's sourceFrameRate for proper audio/video sync
    public var sourceFrameRate: TimecodeFrameRate?

    /// Which side of a hard-panned source this clip plays, if it was split.
    ///
    /// `nil` for every ordinary clip, which takes the source whole. When set,
    /// `extractedAudioURL` points at a mono file holding only that side, so the
    /// clip plays one channel of a split track without the other bleeding in.
    public var sourceChannel: SplitChannel?

    /// End frame on timeline (exclusive)
    public var timelineEndFrame: Int {
        timelineStartFrame + durationFrames
    }

    /// Computed display name
    public var displayName: String {
        if let name = name {
            return name
        }
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        if let trackIndex = sourceTrackIndex {
            return "\(baseName) - Track \(trackIndex + 1)"
        }
        return baseName
    }

    public init(
        id: UUID = UUID(),
        mediaItemId: UUID? = nil,
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
        sampleRate: Double = 48000,
        extractedAudioURL: URL? = nil,
        sourceFrameRate: TimecodeFrameRate? = nil,
        sourceChannel: SplitChannel? = nil
    ) {
        self.id = id
        self.mediaItemId = mediaItemId
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
        self.extractedAudioURL = extractedAudioURL
        self.sourceFrameRate = sourceFrameRate
        self.sourceChannel = sourceChannel
    }

    /// Check if this clip is active at a given timeline frame
    public func isActive(at frame: Int) -> Bool {
        frame >= timelineStartFrame && frame < timelineEndFrame
    }

    /// Convert a timeline frame to a source frame
    /// Returns nil if the timeline frame is outside this clip's range
    public func sourceFrame(at timelineFrame: Int) -> Int? {
        guard isActive(at: timelineFrame) else { return nil }
        return sourceStartFrame + (timelineFrame - timelineStartFrame)
    }

    /// Convert a timeline frame to source time in seconds.
    ///
    /// Uses sourceFrameRate if available (for video-sourced clips), otherwise masterFrameRate.
    /// This ensures audio stays in sync with video from the same source.
    ///
    /// - Parameters:
    ///   - timelineFrame: The frame number on the master timeline
    ///   - masterFrameRate: The timeline's frame rate (fallback if no sourceFrameRate)
    /// - Returns: Time in seconds from the clip's source start, or `nil` if frame is outside clip
    ///
    /// ## NTSC Frame Rate Precision
    ///
    /// At NTSC rates (29.97, 59.94 fps), the time calculation preserves full Double precision:
    /// ```
    /// Frame 1000 at 29.97 fps = 33.36670003... seconds
    /// ```
    ///
    /// When converting to audio samples, callers should round (not truncate) to maintain
    /// sample-accurate sync:
    /// ```
    /// 33.3667s × 48000 Hz = 1,601,601.6 samples → round to 1,601,602
    /// ```
    ///
    /// Truncation loses ~0.6 samples per frame at 29.97 fps, causing ~1.3 second drift
    /// over 1 hour of playback.
    public func sourceTime(at timelineFrame: Int, masterFrameRate: TimecodeFrameRate) -> Double? {
        guard let frame = sourceFrame(at: timelineFrame) else { return nil }
        // Use source frame rate for video-sourced clips to match video timing exactly
        let fps = sourceFrameRate?.fps ?? masterFrameRate.fps
        return Double(frame) / fps
    }
}

// MARK: - Codable Conformance

extension AudioClip {
    enum CodingKeys: String, CodingKey {
        case id
        case mediaItemId
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
        case extractedAudioPath
        case sourceFrameRate
        case sourceChannel
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        mediaItemId = try container.decodeIfPresent(UUID.self, forKey: .mediaItemId)
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

        // Only restore extractedAudioURL if file still exists (temp files may be cleaned)
        if let extractedPath = try container.decodeIfPresent(String.self, forKey: .extractedAudioPath),
           FileManager.default.fileExists(atPath: extractedPath) {
            extractedAudioURL = URL(fileURLWithPath: extractedPath)
        } else {
            extractedAudioURL = nil
        }

        sourceFrameRate = try container.decodeIfPresent(TimecodeFrameRate.self, forKey: .sourceFrameRate)
        sourceChannel = try container.decodeIfPresent(SplitChannel.self, forKey: .sourceChannel)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(mediaItemId, forKey: .mediaItemId)
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
        try container.encodeIfPresent(extractedAudioURL?.path, forKey: .extractedAudioPath)
        try container.encodeIfPresent(sourceFrameRate, forKey: .sourceFrameRate)
        try container.encodeIfPresent(sourceChannel, forKey: .sourceChannel)
    }
}
