//
//  EmbeddedTimecodeServiceProtocol.swift
//  Projector
//
//  THE CONTRACT: Embedded Timecode Detection Service
//  Layer: Contracts
//  Implemented in: Managers
//  Consumed in: Views
//

import Foundation

// MARK: - Result Types

/// Source of detected embedded timecode
enum TimecodeSource: String, Sendable, Equatable {
    /// Timecode from QuickTime timecode track (most reliable)
    case quickTimeTrack = "QuickTime Timecode Track"
    /// Timecode from XMP metadata
    case xmpMetadata = "XMP Metadata"
    /// Timecode from ProRes format description extensions
    case proResMetadata = "ProRes Metadata"
}

// MARK: - Batch Timecode Types

/// Media type for batch items
enum BatchMediaType: String, Sendable, Equatable {
    case video
    case audio
}

/// A single file in a multi-file import, with whatever timecode it carries.
///
/// Import places each file at its own timecode without asking, so this records
/// what was found and where the file is headed - there is no longer a user
/// choice to carry alongside it.
struct BatchTimecodeItem: Identifiable, Sendable {
    /// Unique identifier for this batch item
    let id: UUID

    /// The file URL
    let url: URL

    /// Media type (video or audio)
    let mediaType: BatchMediaType

    /// Detected embedded timecode, or nil if no timecode found
    let detectedTimecode: EmbeddedTimecodeResult?

    /// For audio items, the target lane ID (nil for video)
    var targetLaneId: UUID?

    /// Display name for the file
    var displayName: String {
        url.deletingPathExtension().lastPathComponent
    }

    /// Whether this file has detected timecode
    var hasTimecode: Bool {
        detectedTimecode != nil
    }

    /// Initialize with automatic defaults
    /// - Parameters:
    ///   - url: The file URL
    ///   - mediaType: The media type (video or audio)
    ///   - detectedTimecode: Detected timecode result, if any
    ///   - targetLaneId: For audio items, the target lane ID
    init(url: URL, mediaType: BatchMediaType, detectedTimecode: EmbeddedTimecodeResult?, targetLaneId: UUID? = nil) {
        self.id = UUID()
        self.url = url
        self.mediaType = mediaType
        self.detectedTimecode = detectedTimecode
        self.targetLaneId = targetLaneId
    }
}

// MARK: - Single File Result Types

/// Result of embedded timecode detection from a media file
///
/// Contains the detected timecode value along with metadata about its source
/// and the frame rate it was recorded at.
struct EmbeddedTimecodeResult: Sendable, Equatable {
    /// The detected timecode as a count of frames on its own counting grid.
    ///
    /// A timecode address, not an elapsed duration. `01:10:12:03` at 23.976 is
    /// 101091 frames because timecode labels advance 24 per second regardless
    /// of the rate actually running - see ``convertedFrames(to:)``.
    let timecodeFrames: Int

    /// The detected timecode formatted as HH:MM:SS:FF or HH:MM:SS;FF (drop-frame)
    let formattedTimecode: String

    /// Source of the timecode detection (for display/debugging)
    let source: TimecodeSource

    /// Frame rate of the source timecode
    let frameRate: Double

    /// Whether the timecode uses drop-frame format
    let isDropFrame: Bool

    /// This timecode as a frame count on another rate's counting grid.
    ///
    /// ## Grids, not speeds
    ///
    /// Timecode counts labels, and an NTSC rate counts the same labels as its
    /// integer cousin: 23.976 and 24 both run 00, 01 ... 23 within a second,
    /// and 29.97 and 30 both run 00 ... 29. They differ in how long that second
    /// takes in the real world, not in how the address is spelled. So a
    /// timecode address carries between the two unchanged, and only a genuine
    /// change of grid - 24 to 25, say - moves the count at all.
    ///
    /// Scaling by the *real* rates instead is what put a reel four seconds late
    /// on the timeline. `01:10:12:03` is 101091 frames; multiplying by
    /// 24/23.976 gives 101192, which reads as `01:10:16:08`. The error is the
    /// 1000/1001 NTSC ratio applied to a whole hour of timecode, and it shows
    /// up as a fixed offset, the same at the head of the reel as at the tail -
    /// picture and position simply disagree from the first frame.
    ///
    /// - Parameter targetFrameRate: Rate whose grid the count is wanted on.
    /// - Returns: Frame count on that grid.
    func convertedFrames(to targetFrameRate: Double) -> Int {
        let sourceGrid = Self.countingGrid(for: frameRate)
        let targetGrid = Self.countingGrid(for: targetFrameRate)
        guard sourceGrid > 0, targetGrid > 0 else { return timecodeFrames }
        if sourceGrid == targetGrid { return timecodeFrames }
        return Int((Double(timecodeFrames) * targetGrid / sourceGrid).rounded())
    }

    /// Labels per second for a rate: 23.976 counts 24, 29.97 counts 30.
    ///
    /// Rounding is the whole rule. Every rate the app supports is either an
    /// integer or that integer pulled down by 1000/1001, and the pulldown never
    /// moves it as far as half a frame.
    private static func countingGrid(for frameRate: Double) -> Double {
        frameRate.rounded()
    }
}

// MARK: - Service Protocol

/// Protocol for detecting embedded timecode from media files.
///
/// This protocol defines the interface between the Logic layer (actor) and
/// the Presentation layer (drop handlers). It provides timecode detection
/// from multiple sources in order of reliability.
///
/// ## Detection Priority
///
/// 1. **QuickTime Timecode Tracks** - Most reliable, uses `AVMediaType.timecode`
/// 2. **XMP Metadata** - Common in professional workflows
/// 3. **ProRes Format Extensions** - ProRes-specific `tmcd` atom
///
/// ## Architecture
///
/// ```
/// ┌─────────────────────────────────────────────────────────────────────────┐
/// │                     PRESENTATION LAYER                                   │
/// │                                                                          │
/// │  ContentView+Timeline ──── handleVideoDropOnTimeline()                   │
/// │                                   │                                      │
/// │                                   │ Calls async method                   │
/// │                                   ▼                                      │
/// ├───────────────────── EmbeddedTimecodeServiceProtocol ───────────────────┤
/// │                                   ▲                                      │
/// │                                   │ Implemented by                       │
/// │                                   │                                      │
/// │  EmbeddedTimecodeService ◀─── AVFoundation ◀─── Media Files             │
/// │                                                                          │
/// │                        LOGIC LAYER                                       │
/// └─────────────────────────────────────────────────────────────────────────┘
/// ```
///
/// ## Thread Safety
///
/// - All types are `Sendable` and can cross actor boundaries
/// - The implementing actor handles all AVFoundation work off the main thread
/// - Returns `nil` if no timecode found (not an error condition)
protocol EmbeddedTimecodeServiceProtocol: Sendable {

    /// Detect embedded timecode from a media file.
    ///
    /// Checks multiple timecode sources in order of reliability:
    /// 1. QuickTime timecode tracks
    /// 2. XMP metadata
    /// 3. ProRes format description extensions
    ///
    /// Returns the first timecode found, or `nil` if no embedded timecode exists.
    ///
    /// - Parameters:
    ///   - url: File URL of the media to analyze
    ///   - bookmark: Optional security-scoped bookmark for sandbox access
    /// - Returns: Detected timecode result, or `nil` if no timecode found
    func detectTimecode(from url: URL, bookmark: Data?) async -> EmbeddedTimecodeResult?
}
