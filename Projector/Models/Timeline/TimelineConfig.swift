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

    /// Default timeline configuration (2 hours at 24fps, starting at 00:59:50:00)
    ///
    /// Starts at 00:59:50:00 so content placed at 01:00:00:00 (a common hour
    /// mark) lands ten seconds in, with room for pre-roll. Duration is auto-
    /// managed: the timeline extends when content is placed beyond its bounds
    /// and shrinks when content is deleted, so the default just needs to be
    /// long enough for comfortable initial placement.
    public static var `default`: TimelineConfig {
        TimelineConfig(
            startTimecode: Timecode(.components(h: 0, m: 59, s: 50, f: 0), at: .fps24, by: .clamping),
            endTimecode: Timecode(.components(h: 2, m: 59, s: 50, f: 0), at: .fps24, by: .clamping),
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

    /// Re-express the timeline at another frame rate, keeping its clock.
    ///
    /// The bounds are addresses on a clock, not frame counts, so they survive a
    /// rate change by their *components*: a timeline starting at 00:59:50:00 at
    /// 24 fps still starts at 00:59:50:00 at 25 fps.
    ///
    /// Carrying the frame count across instead is what put a 25 fps reel two and
    /// a half minutes out of place. The default start, 86160 frames at 24 fps,
    /// reads as 00:57:26:10 when the same count is counted at 25 - so every
    /// timecode on the timeline, including the reel placed by its own embedded
    /// timecode, was reported 2:23:15 early. It looks like a broken file rather
    /// than a broken conversion, because picture and readout are wrong together.
    ///
    /// A frames value with nowhere to go at the new rate rolls into the second
    /// that follows - 00:59:50:24 at 25 fps becomes 00:59:51:00 at 24 - which
    /// only arises for a bound set to the last frame of a second, and moves it
    /// by less than a frame of real time.
    ///
    /// - Parameter newRate: The rate to express the timeline at.
    public mutating func setFrameRate(_ newRate: TimecodeFrameRate) {
        guard newRate != frameRate else { return }
        startTimecode = Timecode(.components(startTimecode.components), at: newRate, by: .clamping)
        endTimecode = Timecode(.components(endTimecode.components), at: newRate, by: .clamping)
        frameRate = newRate
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
