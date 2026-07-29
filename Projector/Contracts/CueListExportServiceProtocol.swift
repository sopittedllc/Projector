//
//  CueListExportServiceProtocol.swift
//  Projector
//
//  THE CONTRACT: Cue List Export Service
//  Layer: Contracts
//  Implemented in: Managers/CueListExportService.swift
//  Consumed in: Views/ContentView.swift
//

import Foundation

// MARK: - Detected Cue

/// A single detected cue from audio analysis.
///
/// Cues are regions of audio activity between silence gaps. Each cue has a title
/// derived from the source clip name and a sequential number.
public struct DetectedCue: Sendable, Identifiable, Equatable {
    /// Unique identifier for this cue
    public let id: UUID

    /// Display title (e.g., "MyClip Cue 1")
    public let title: String

    /// Timecode in as formatted string (HH:MM:SS:FF)
    public let timecodeIn: String

    /// Timecode out as formatted string (HH:MM:SS:FF)
    public let timecodeOut: String

    /// Frame number for cue start (timeline-relative)
    public let frameIn: Int

    /// Frame number for cue end (timeline-relative)
    public let frameOut: Int

    public init(
        id: UUID = UUID(),
        title: String,
        timecodeIn: String,
        timecodeOut: String,
        frameIn: Int,
        frameOut: Int
    ) {
        self.id = id
        self.title = title
        self.timecodeIn = timecodeIn
        self.timecodeOut = timecodeOut
        self.frameIn = frameIn
        self.frameOut = frameOut
    }
}

// MARK: - Silence Detection Configuration

/// Configuration parameters for silence detection.
///
/// Controls the sensitivity and minimum durations for detecting silence and cues.
public struct SilenceDetectionConfig: Sendable, Equatable {
    /// RMS threshold below which audio is considered silence (0.0 to 1.0).
    /// Default is 0.02 (2% of full scale).
    public let silenceThresholdRMS: Float

    /// Minimum duration in seconds for a gap to be considered silence.
    /// Shorter gaps are ignored and treated as continuous audio.
    public let minimumSilenceDuration: Double

    /// Minimum duration in seconds for a region to be considered a cue.
    /// Shorter audio regions are filtered out.
    public let minimumCueDuration: Double

    /// Default configuration with sensible values for music/dialogue detection.
    public static let `default` = SilenceDetectionConfig(
        silenceThresholdRMS: 0.02,
        minimumSilenceDuration: 0.5,
        minimumCueDuration: 1.0
    )

    public init(
        silenceThresholdRMS: Float = 0.02,
        minimumSilenceDuration: Double = 0.5,
        minimumCueDuration: Double = 1.0
    ) {
        self.silenceThresholdRMS = silenceThresholdRMS
        self.minimumSilenceDuration = minimumSilenceDuration
        self.minimumCueDuration = minimumCueDuration
    }
}

// MARK: - Export Result

/// Result of a successful cue list export.
public struct CueListExportResult: Sendable, Equatable {
    /// The detected cues that were exported
    public let cues: [DetectedCue]

    /// Path where the CSV was written
    public let exportURL: URL

    public init(cues: [DetectedCue], exportURL: URL) {
        self.cues = cues
        self.exportURL = exportURL
    }
}

// MARK: - Error Type

/// Error that can occur during cue list export.
///
/// Uses a simple message string for display in alerts.
public struct CueListExportError: LocalizedError, Sendable {
    /// Human-readable error message
    public let message: String

    public var errorDescription: String? { message }

    public init(_ message: String) {
        self.message = message
    }

    // Common error cases
    public static let noMXLane = CueListExportError("No MX lane found. Create an audio lane named \"MX\" and add clips to it.")
    public static let emptyMXLane = CueListExportError("The MX lane has no audio clips. Add audio clips to the MX lane first.")
    public static let noCuesDetected = CueListExportError("No cues detected. The audio may be entirely silent or below the detection threshold.")

    public static func audioReadFailed(_ reason: String) -> CueListExportError {
        CueListExportError("Failed to read audio: \(reason)")
    }

    public static func writeFailed(_ reason: String) -> CueListExportError {
        CueListExportError("Failed to write CSV: \(reason)")
    }
}

// MARK: - Service Protocol

/// The contract for cue list export services.
///
/// This protocol defines the interface for detecting audio cues in the MX lane
/// and exporting them as a CSV file compatible with CueDB.
///
/// ## Architecture
///
/// ```
/// ┌─────────────────────────────────────────────────────────────────────────┐
/// │                     PRESENTATION LAYER                                   │
/// │                                                                          │
/// │  ContentView ──────── exports via ──────────▶ NSSavePanel               │
/// │       │                                                                  │
/// │       │ Calls async methods                                              │
/// │       ▼                                                                  │
/// ├────────────────── CueListExportServiceProtocol ─────────────────────────┤
/// │                          ▲                                               │
/// │                          │ Implemented by                                │
/// │                          │                                               │
/// │  CueListExportService ◀── AVAssetReader ◀── Audio Files                 │
/// │                                                                          │
/// │                     LOGIC LAYER                                          │
/// └─────────────────────────────────────────────────────────────────────────┘
/// ```
///
/// ## Silence Detection Algorithm
///
/// 1. Find the lane named "MX" (case-insensitive)
/// 2. For each clip, read high-resolution RMS data
/// 3. Identify silence regions (consecutive samples below threshold)
/// 4. Filter out silences shorter than minimum duration
/// 5. Invert to get cue regions (audio activity between silences)
/// 6. Filter out cues shorter than minimum duration
/// 7. Convert sample positions to timeline timecodes
///
/// ## Thread Safety
///
/// - All types are `Sendable` and can cross actor boundaries
/// - The implementing actor handles file I/O off the main thread
/// - Results should be received on MainActor for UI updates
public protocol CueListExportServiceProtocol: Sendable {

    /// Detects cues in the MX lane based on silence gaps.
    ///
    /// - Parameters:
    ///   - lanes: All audio lanes in the timeline
    ///   - frameRate: The timeline's frame rate (for timecode conversion)
    ///   - startTimecode: The timeline's start timecode
    ///   - config: Silence detection parameters
    /// - Returns: Array of detected cues with timecodes
    /// - Throws: `CueListExportError` if detection fails
    func detectCues(
        in lanes: [AudioLane],
        frameRate: Double,
        startTimecodeFrames: Int,
        config: SilenceDetectionConfig
    ) async throws -> [DetectedCue]

    /// Exports detected cues to a CSV file.
    ///
    /// The CSV format is compatible with CueDB:
    /// ```
    /// Title,TC In,TC Out
    /// MyClip Cue 1,01:00:00:00,01:00:15:12
    /// ```
    ///
    /// - Parameters:
    ///   - cues: The cues to export
    ///   - destinationURL: Where to write the CSV file
    /// - Throws: `CueListExportError` if writing fails
    func exportToCSV(
        cues: [DetectedCue],
        to destinationURL: URL
    ) async throws
}
