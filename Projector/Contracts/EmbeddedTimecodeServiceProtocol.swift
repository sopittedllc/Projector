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

/// A single file item in a batch timecode detection operation
///
/// Used when multiple files are dropped simultaneously to track each file's
/// detected timecode and the user's placement preference.
struct BatchTimecodeItem: Identifiable, Sendable {
    /// Unique identifier for this batch item
    let id: UUID

    /// The file URL
    let url: URL

    /// Media type (video or audio)
    let mediaType: BatchMediaType

    /// Detected embedded timecode, or nil if no timecode found
    let detectedTimecode: EmbeddedTimecodeResult?

    /// User's choice: true = place at embedded timecode, false = place at drop location
    var useEmbeddedTimecode: Bool

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
    ///   - useEmbeddedTimecode: Whether to use embedded timecode (defaults to true if timecode exists)
    ///   - targetLaneId: For audio items, the target lane ID
    init(url: URL, mediaType: BatchMediaType, detectedTimecode: EmbeddedTimecodeResult?, useEmbeddedTimecode: Bool? = nil, targetLaneId: UUID? = nil) {
        self.id = UUID()
        self.url = url
        self.mediaType = mediaType
        self.detectedTimecode = detectedTimecode
        self.useEmbeddedTimecode = useEmbeddedTimecode ?? (detectedTimecode != nil)
        self.targetLaneId = targetLaneId
    }
}

/// Pending batch of files awaiting user timecode placement decisions
///
/// Created when multiple files are dropped and at least one has embedded timecode.
/// Stores all the context needed to process the files after user confirmation.
/// Supports mixed video and audio files in a single batch.
struct PendingBatchTimecode: Sendable {
    /// The files in this batch with their detected timecodes
    var items: [BatchTimecodeItem]

    /// The frame where files were dropped (used for files not using embedded timecode)
    let dropFrame: Int

    /// Primary initializer for mixed video/audio batches
    init(items: [BatchTimecodeItem], dropFrame: Int) {
        self.items = items
        self.dropFrame = dropFrame
    }

    /// Whether any file in the batch has detected timecode
    var hasAnyTimecode: Bool {
        items.contains { $0.hasTimecode }
    }

    /// Number of files that will use embedded timecode
    var countUsingTimecode: Int {
        items.filter { $0.useEmbeddedTimecode }.count
    }

    /// Video items in this batch
    var videoItems: [BatchTimecodeItem] {
        items.filter { $0.mediaType == .video }
    }

    /// Audio items in this batch
    var audioItems: [BatchTimecodeItem] {
        items.filter { $0.mediaType == .audio }
    }

    /// Whether this batch contains video files
    var hasVideoItems: Bool {
        items.contains { $0.mediaType == .video }
    }

    /// Whether this batch contains audio files
    var hasAudioItems: Bool {
        items.contains { $0.mediaType == .audio }
    }

    /// Legacy compatibility: returns true if batch contains only video files
    var isVideo: Bool {
        hasVideoItems && !hasAudioItems
    }

    /// Legacy compatibility: returns the first audio lane ID if any audio items exist
    var laneId: UUID? {
        audioItems.first?.targetLaneId
    }

    /// Convenience initializer for backwards compatibility with video-only or audio-only batches
    /// - Parameters:
    ///   - items: The batch items (without mediaType set)
    ///   - dropFrame: The frame where files were dropped
    ///   - isVideo: Whether this is a video-only batch
    ///   - laneId: For audio-only batches, the target lane ID
    init(items: [BatchTimecodeItem], dropFrame: Int, isVideo: Bool, laneId: UUID?) {
        let mediaType: BatchMediaType = isVideo ? .video : .audio
        self.items = items.map { item in
            var newItem = BatchTimecodeItem(
                url: item.url,
                mediaType: mediaType,
                detectedTimecode: item.detectedTimecode,
                useEmbeddedTimecode: item.useEmbeddedTimecode
            )
            if !isVideo {
                newItem.targetLaneId = laneId
            }
            return newItem
        }
        self.dropFrame = dropFrame
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
