import Foundation
import CoreMedia
import SwiftTimecodeCore

/// Represents a video file (reel) placed on the master timeline
public struct VideoReel: Identifiable, Codable, Equatable, Sendable {
    /// Unique identifier for the reel
    public let id: UUID

    /// Reference to the MediaItem in the library (for optimization status lookup)
    public var mediaItemId: UUID?

    /// Source video file URL
    public var sourceURL: URL

    /// Security-scoped bookmark for sandbox access
    public var sourceBookmark: Data?

    /// Position on the master timeline (in frames from timeline start)
    public var timelineStartFrame: Int

    /// Duration of the clip on the timeline (in frames)
    public var durationFrames: Int

    /// In-point within the source file (in source frames)
    public var sourceStartFrame: Int

    /// Frame rate of the source file
    public var sourceFrameRate: TimecodeFrameRate

    /// Display name (derived from filename if not set)
    public var name: String?

    /// End frame on timeline (exclusive)
    public var timelineEndFrame: Int {
        timelineStartFrame + durationFrames
    }

    /// Computed display name
    public var displayName: String {
        name ?? sourceURL.deletingPathExtension().lastPathComponent
    }

    public init(
        id: UUID = UUID(),
        mediaItemId: UUID? = nil,
        sourceURL: URL,
        sourceBookmark: Data? = nil,
        timelineStartFrame: Int,
        durationFrames: Int,
        sourceStartFrame: Int = 0,
        sourceFrameRate: TimecodeFrameRate = .fps24,
        name: String? = nil
    ) {
        self.id = id
        self.mediaItemId = mediaItemId
        self.sourceURL = sourceURL
        self.sourceBookmark = sourceBookmark
        self.timelineStartFrame = timelineStartFrame
        self.durationFrames = durationFrames
        self.sourceStartFrame = sourceStartFrame
        self.sourceFrameRate = sourceFrameRate
        self.name = name
    }

    /// Check if this reel is active at a given timeline frame
    public func isActive(at frame: Int) -> Bool {
        frame >= timelineStartFrame && frame < timelineEndFrame
    }

    /// Convert a timeline frame to a source frame
    /// Returns nil if the timeline frame is outside this reel's range
    public func sourceFrame(at timelineFrame: Int) -> Int? {
        guard isActive(at: timelineFrame) else { return nil }
        return sourceStartFrame + (timelineFrame - timelineStartFrame)
    }

    /// Convert a timeline frame to source time in seconds
    public func sourceTime(at timelineFrame: Int) -> Double? {
        guard let frame = sourceFrame(at: timelineFrame) else { return nil }
        return Double(frame) / sourceFrameRate.fps
    }

    /// Convert a timeline frame to an exact source time.
    ///
    /// Built from the rate's frame duration as a rational - 1001/24000 for
    /// 23.976 - so the result lands precisely on a frame boundary.
    ///
    /// Seeking used to go through `Double` seconds and a 600-tick `CMTime`,
    /// which cannot represent an NTSC frame boundary: one frame at 23.976 is
    /// 25.025 ticks of a 600 timescale. The requested instant therefore landed
    /// a hair either side of the boundary and, with zero tolerance, the player
    /// returned whichever frame contained it - so a seek was accurate to about
    /// a frame either way, drifting between exact, one early and one late as
    /// the rounding fell. On NTSC material that is a frame of slop on every
    /// hit point.
    ///
    /// - Parameter timelineFrame: Frame on the timeline.
    /// - Returns: Exact source time, or `nil` outside this reel's range.
    public func sourceCMTime(at timelineFrame: Int) -> CMTime? {
        guard let frame = sourceFrame(at: timelineFrame) else { return nil }
        let duration = sourceFrameRate.frameDuration
        return CMTime(
            value: CMTimeValue(frame) * CMTimeValue(duration.numerator),
            timescale: CMTimeScale(duration.denominator)
        )
    }

    /// One frame of this reel's source, exactly.
    public var sourceFrameDuration: CMTime {
        let duration = sourceFrameRate.frameDuration
        return CMTime(
            value: CMTimeValue(duration.numerator),
            timescale: CMTimeScale(duration.denominator)
        )
    }
}

// MARK: - Codable Conformance

extension VideoReel {
    enum CodingKeys: String, CodingKey {
        case id
        case mediaItemId
        case sourcePath
        case sourceBookmark
        case timelineStartFrame
        case durationFrames
        case sourceStartFrame
        case sourceFrameRateIdentifier
        case name
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

        let frameRateIdentifier = try container.decode(String.self, forKey: .sourceFrameRateIdentifier)
        sourceFrameRate = TimecodeFrameRate.allCases.first {
            $0.stringValueVerbose == frameRateIdentifier
        } ?? .fps24

        name = try container.decodeIfPresent(String.self, forKey: .name)
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
        try container.encode(sourceFrameRate.stringValueVerbose, forKey: .sourceFrameRateIdentifier)
        try container.encodeIfPresent(name, forKey: .name)
    }
}
