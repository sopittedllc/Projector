import Foundation
import SwiftTimecodeCore

/// Represents a video file (reel) placed on the master timeline
struct VideoReel: Identifiable, Codable, Equatable {
    /// Unique identifier for the reel
    let id: UUID

    /// Reference to the MediaItem in the library (for optimization status lookup)
    var mediaItemId: UUID?

    /// Source video file URL
    var sourceURL: URL

    /// Security-scoped bookmark for sandbox access
    var sourceBookmark: Data?

    /// Position on the master timeline (in frames from timeline start)
    var timelineStartFrame: Int

    /// Duration of the clip on the timeline (in frames)
    var durationFrames: Int

    /// In-point within the source file (in source frames)
    var sourceStartFrame: Int

    /// Frame rate of the source file
    var sourceFrameRate: TimecodeFrameRate

    /// Display name (derived from filename if not set)
    var name: String?

    /// End frame on timeline (exclusive)
    var timelineEndFrame: Int {
        timelineStartFrame + durationFrames
    }

    /// Computed display name
    var displayName: String {
        name ?? sourceURL.deletingPathExtension().lastPathComponent
    }

    init(
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
    func isActive(at frame: Int) -> Bool {
        frame >= timelineStartFrame && frame < timelineEndFrame
    }

    /// Convert a timeline frame to a source frame
    /// Returns nil if the timeline frame is outside this reel's range
    func sourceFrame(at timelineFrame: Int) -> Int? {
        guard isActive(at: timelineFrame) else { return nil }
        return sourceStartFrame + (timelineFrame - timelineStartFrame)
    }

    /// Convert a timeline frame to source time in seconds
    func sourceTime(at timelineFrame: Int) -> Double? {
        guard let frame = sourceFrame(at: timelineFrame) else { return nil }
        return Double(frame) / sourceFrameRate.fps
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

    init(from decoder: Decoder) throws {
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

    func encode(to encoder: Encoder) throws {
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
