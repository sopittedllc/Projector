import Foundation
import SwiftTimecodeCore

/// A cue marker on the timeline representing a timed event.
///
/// Cues can be created manually or imported from detected audio activity.
/// They support external sync with systems like Google Sheets for round-trip editing.
///
/// ## Overview
///
/// Use cues to mark important points in your timeline:
/// - Scene changes
/// - Audio cues for performers
/// - Light cues for stage shows
/// - Chapter markers for video content
///
/// ## Example
///
/// ```swift
/// let cue = Cue(
///     number: 1,
///     title: "Opening",
///     startFrame: 0,
///     endFrame: 720,  // 30 seconds at 24fps
///     notes: "Stage lights come up"
/// )
/// ```
struct Cue: Identifiable, Codable, Equatable, Sendable {
    /// Unique identifier for this cue
    let id: UUID

    /// Sequential cue number for display
    var number: Int

    /// User-defined title for the cue
    var title: String

    /// Start frame on the timeline (relative to timeline start)
    var startFrame: Int

    /// End frame on the timeline (relative to timeline start)
    var endFrame: Int

    /// User notes or description for this cue
    var notes: String

    /// External identifier for sync with external systems (e.g., Google Sheets row ID)
    var externalId: String?

    /// Timestamp of last local modification (for sync conflict resolution)
    var lastModified: Date?

    // MARK: - Computed Properties

    /// Duration of the cue in frames
    var durationFrames: Int {
        max(0, endFrame - startFrame)
    }

    // MARK: - Initialization

    /// Creates a new cue.
    ///
    /// - Parameters:
    ///   - id: Unique identifier (defaults to new UUID)
    ///   - number: Sequential cue number
    ///   - title: User-defined title
    ///   - startFrame: Start frame on timeline
    ///   - endFrame: End frame on timeline
    ///   - notes: User notes
    ///   - externalId: Optional external system ID
    ///   - lastModified: Optional modification timestamp
    init(
        id: UUID = UUID(),
        number: Int,
        title: String = "",
        startFrame: Int,
        endFrame: Int,
        notes: String = "",
        externalId: String? = nil,
        lastModified: Date? = nil
    ) {
        self.id = id
        self.number = number
        self.title = title
        self.startFrame = startFrame
        self.endFrame = endFrame
        self.notes = notes
        self.externalId = externalId
        self.lastModified = lastModified
    }

    // MARK: - Timecode Conversion

    /// Returns the timecode for the cue start point.
    ///
    /// - Parameter config: Timeline configuration containing frame rate and start timecode
    /// - Returns: Absolute timecode for the cue start
    func timecodeIn(config: TimelineConfig) -> Timecode {
        let absoluteFrame = config.startTimecode.frameCount.wholeFrames + startFrame
        return Timecode(.frames(absoluteFrame), at: config.frameRate, by: .clamping)
    }

    /// Returns the timecode for the cue end point.
    ///
    /// - Parameter config: Timeline configuration containing frame rate and start timecode
    /// - Returns: Absolute timecode for the cue end
    func timecodeOut(config: TimelineConfig) -> Timecode {
        let absoluteFrame = config.startTimecode.frameCount.wholeFrames + endFrame
        return Timecode(.frames(absoluteFrame), at: config.frameRate, by: .clamping)
    }

    /// Returns the duration as a timecode.
    ///
    /// - Parameter frameRate: The frame rate to use for conversion
    /// - Returns: Timecode representing the cue duration
    func durationTimecode(at frameRate: TimecodeFrameRate) -> Timecode {
        Timecode(.frames(durationFrames), at: frameRate, by: .clamping)
    }
}

// MARK: - Factory Methods

extension Cue {
    /// Creates a cue from a detected audio cue.
    ///
    /// - Parameters:
    ///   - detected: The detected cue from silence detection
    ///   - title: Optional title (defaults to empty)
    /// - Returns: A new Cue instance
    static func from(_ detected: DetectedCue, title: String = "") -> Cue {
        Cue(
            number: detected.number,
            title: title,
            startFrame: detected.startFrame,
            endFrame: detected.endFrame
        )
    }
}
