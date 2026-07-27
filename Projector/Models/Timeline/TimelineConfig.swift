import Foundation
import SwiftTimecodeCore

/// Configuration for the master timeline
public struct TimelineConfig: Codable, Equatable, Sendable {
    /// Starting timecode of the timeline (e.g., 00:58:00:00)
    public var startTimecode: Timecode

    /// Ending timecode of the timeline (e.g., 03:30:00:00)
    public var endTimecode: Timecode

    /// Master frame rate for the timeline
    public var frameRate: TimecodeFrameRate

    /// Total duration in frames
    public var durationFrames: Int {
        endTimecode.frameCount.wholeFrames - startTimecode.frameCount.wholeFrames
    }

    /// Total duration in seconds
    public var durationSeconds: Double {
        Double(durationFrames) / frameRate.fps
    }

    /// Default timeline configuration (1 hour at 24fps, starting at 00:00:00:00)
    ///
    /// Was 4 hours, which cost nothing to store but made the default view
    /// unusable: zoom is relative to duration, so fit-to-view on a 4-hour
    /// timeline put the playhead at ~0.0024pt per frame - it advanced half a
    /// point in ten seconds, and running playback was indistinguishable from a
    /// stopped transport.
    ///
    /// Nothing depends on the timeline starting out long. `extendTimelineIfNeeded`
    /// grows it whenever media lands past the end, and media drops add padding
    /// beyond the clip, so a shorter default simply defers the length until
    /// there is content to justify it.
    public static var `default`: TimelineConfig {
        TimelineConfig(
            startTimecode: Timecode(.components(h: 0, m: 0, s: 0, f: 0), at: .fps24, by: .clamping),
            endTimecode: Timecode(.components(h: 1, m: 0, s: 0, f: 0), at: .fps24, by: .clamping),
            frameRate: .fps24
        )
    }

    public init(
        startTimecode: Timecode,
        endTimecode: Timecode,
        frameRate: TimecodeFrameRate
    ) {
        self.startTimecode = startTimecode
        self.endTimecode = endTimecode
        self.frameRate = frameRate
    }

    /// Convert a timeline frame to timecode
    public func timecode(at frame: Int) -> Timecode {
        let absoluteFrame = startTimecode.frameCount.wholeFrames + frame
        return Timecode(.frames(absoluteFrame), at: frameRate, by: .clamping)
    }

    /// Convert a timecode to timeline frame (relative to start)
    public func frame(for timecode: Timecode) -> Int {
        timecode.frameCount.wholeFrames - startTimecode.frameCount.wholeFrames
    }

    /// Check if a frame is within the timeline bounds
    public func isValidFrame(_ frame: Int) -> Bool {
        frame >= 0 && frame < durationFrames
    }
}

// MARK: - Codable Conformance

extension TimelineConfig {
    enum CodingKeys: String, CodingKey {
        case startFrames
        case endFrames
        case frameRateIdentifier
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let frameRateIdentifier = try container.decode(String.self, forKey: .frameRateIdentifier)
        frameRate = TimecodeFrameRate.allCases.first {
            $0.stringValueVerbose == frameRateIdentifier
        } ?? .fps24

        let startFrames = try container.decode(Int.self, forKey: .startFrames)
        let endFrames = try container.decode(Int.self, forKey: .endFrames)

        startTimecode = Timecode(.frames(startFrames), at: frameRate, by: .clamping)
        endTimecode = Timecode(.frames(endFrames), at: frameRate, by: .clamping)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(startTimecode.frameCount.wholeFrames, forKey: .startFrames)
        try container.encode(endTimecode.frameCount.wholeFrames, forKey: .endFrames)
        try container.encode(frameRate.stringValueVerbose, forKey: .frameRateIdentifier)
    }
}
