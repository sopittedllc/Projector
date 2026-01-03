import Foundation
import SwiftTimecodeCore

/// Configuration for the master timeline
struct TimelineConfig: Codable, Equatable {
    /// Starting timecode of the timeline (e.g., 00:58:00:00)
    var startTimecode: Timecode

    /// Ending timecode of the timeline (e.g., 03:30:00:00)
    var endTimecode: Timecode

    /// Master frame rate for the timeline
    var frameRate: TimecodeFrameRate

    /// Total duration in frames
    var durationFrames: Int {
        endTimecode.frameCount.wholeFrames - startTimecode.frameCount.wholeFrames
    }

    /// Total duration in seconds
    var durationSeconds: Double {
        Double(durationFrames) / frameRate.fps
    }

    /// Default timeline configuration (2 hours at 24fps, starting at 00:00:00:00)
    static var `default`: TimelineConfig {
        TimelineConfig(
            startTimecode: Timecode(.components(h: 0, m: 0, s: 0, f: 0), at: .fps24, by: .clamping),
            endTimecode: Timecode(.components(h: 1, m: 0, s: 0, f: 0), at: .fps24, by: .clamping),
            frameRate: .fps24
        )
    }

    /// Convert a timeline frame to timecode
    func timecode(at frame: Int) -> Timecode {
        let absoluteFrame = startTimecode.frameCount.wholeFrames + frame
        return Timecode(.frames(absoluteFrame), at: frameRate, by: .clamping)
    }

    /// Convert a timecode to timeline frame (relative to start)
    func frame(for timecode: Timecode) -> Int {
        timecode.frameCount.wholeFrames - startTimecode.frameCount.wholeFrames
    }

    /// Check if a frame is within the timeline bounds
    func isValidFrame(_ frame: Int) -> Bool {
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

    init(from decoder: Decoder) throws {
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

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(startTimecode.frameCount.wholeFrames, forKey: .startFrames)
        try container.encode(endTimecode.frameCount.wholeFrames, forKey: .endFrames)
        try container.encode(frameRate.stringValueVerbose, forKey: .frameRateIdentifier)
    }
}
