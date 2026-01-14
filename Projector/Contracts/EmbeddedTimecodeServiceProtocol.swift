//
//  EmbeddedTimecodeServiceProtocol.swift
//  Projector
//
//  THE CONTRACT: Embedded Timecode Detection Service
//  Defined by: arch-architect
//  Implemented by: backend-logic (EmbeddedTimecodeService)
//  Consumed by: ui-specialist (ContentView+Timeline)
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

/// A single file item in a batch timecode detection operation
///
/// Used when multiple files are dropped simultaneously to track each file's
/// detected timecode and the user's placement preference.
struct BatchTimecodeItem: Identifiable, Sendable {
    /// Unique identifier for this batch item
    let id: UUID

    /// The file URL
    let url: URL

    /// Detected embedded timecode, or nil if no timecode found
    let detectedTimecode: EmbeddedTimecodeResult?

    /// User's choice: true = place at embedded timecode, false = place at drop location
    var useEmbeddedTimecode: Bool

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
    ///   - detectedTimecode: Detected timecode result, if any
    ///   - useEmbeddedTimecode: Whether to use embedded timecode (defaults to true if timecode exists)
    init(url: URL, detectedTimecode: EmbeddedTimecodeResult?, useEmbeddedTimecode: Bool? = nil) {
        self.id = UUID()
        self.url = url
        self.detectedTimecode = detectedTimecode
        self.useEmbeddedTimecode = useEmbeddedTimecode ?? (detectedTimecode != nil)
    }
}

/// Pending batch of files awaiting user timecode placement decisions
///
/// Created when multiple files are dropped and at least one has embedded timecode.
/// Stores all the context needed to process the files after user confirmation.
struct PendingBatchTimecode: Sendable {
    /// The files in this batch with their detected timecodes
    var items: [BatchTimecodeItem]

    /// The frame where files were dropped (used for files not using embedded timecode)
    let dropFrame: Int

    /// Whether these are video files (true) or audio files (false)
    let isVideo: Bool

    /// For audio drops, the target lane ID
    let laneId: UUID?

    /// Whether any file in the batch has detected timecode
    var hasAnyTimecode: Bool {
        items.contains { $0.hasTimecode }
    }

    /// Number of files that will use embedded timecode
    var countUsingTimecode: Int {
        items.filter { $0.useEmbeddedTimecode }.count
    }
}

// MARK: - Single File Result Types

/// Result of embedded timecode detection from a media file
///
/// Contains the detected timecode value along with metadata about its source
/// and the frame rate it was recorded at.
struct EmbeddedTimecodeResult: Sendable, Equatable {
    /// The detected timecode as a frame count at the source frame rate
    let timecodeFrames: Int

    /// The detected timecode formatted as HH:MM:SS:FF or HH:MM:SS;FF (drop-frame)
    let formattedTimecode: String

    /// Source of the timecode detection (for display/debugging)
    let source: TimecodeSource

    /// Frame rate of the source timecode
    let frameRate: Double

    /// Whether the timecode uses drop-frame format
    let isDropFrame: Bool

    /// Convert this timecode to a different frame rate
    ///
    /// - Parameter targetFrameRate: The target frame rate to convert to
    /// - Returns: Frame count at the target frame rate
    func convertedFrames(to targetFrameRate: Double) -> Int {
        Int(Double(timecodeFrames) * targetFrameRate / frameRate)
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
