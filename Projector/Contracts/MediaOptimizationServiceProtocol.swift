//
//  MediaOptimizationServiceProtocol.swift
//  Projector
//
//  THE CONTRACT: Media Optimization Service
//  Defined by: arch-architect
//  Implemented by: backend-logic (MediaOptimizationService)
//  Consumed by: ui-specialist (OptimizationViewModel)
//

import Foundation

// MARK: - Analysis Types

/// Result of analyzing a media item for optimization potential
struct MediaAnalysisItem: Sendable, Identifiable, Equatable {
    /// Unique identifier for this analysis item
    let id: UUID

    /// ID of the source MediaItem in the library
    let mediaItemId: UUID

    /// Source file URL
    let sourceURL: URL

    /// Security-scoped bookmark for sandbox access
    let sourceBookmark: Data?

    /// Display name (filename without extension)
    let displayName: String

    /// Original file size in bytes
    let originalSize: UInt64

    /// Estimated size after optimization in bytes
    let estimatedOptimizedSize: UInt64

    /// Whether this is a video file (false = audio)
    let isVideo: Bool

    /// Whether this file needs optimization (false if already meets target specs)
    let needsOptimization: Bool

    /// Current codec (e.g., "ProRes 422", "H.264", "PCM")
    let currentCodec: String?

    /// Current video resolution (nil for audio files)
    let currentResolution: CGSize?

    /// Current video frame rate (nil for audio files)
    let currentFrameRate: Double?

    /// Current audio sample rate
    let currentSampleRate: Double?

    /// Current bitrate in bits per second
    let currentBitrate: Int?

    /// Estimated savings in bytes
    var estimatedSavings: UInt64 {
        guard estimatedOptimizedSize < originalSize else { return 0 }
        return originalSize - estimatedOptimizedSize
    }

    /// Savings as a percentage (0.0 - 1.0)
    var savingsPercentage: Double {
        guard originalSize > 0 else { return 0 }
        return Double(estimatedSavings) / Double(originalSize)
    }

    init(
        id: UUID = UUID(),
        mediaItemId: UUID,
        sourceURL: URL,
        sourceBookmark: Data?,
        displayName: String,
        originalSize: UInt64,
        estimatedOptimizedSize: UInt64,
        isVideo: Bool,
        needsOptimization: Bool,
        currentCodec: String? = nil,
        currentResolution: CGSize? = nil,
        currentFrameRate: Double? = nil,
        currentSampleRate: Double? = nil,
        currentBitrate: Int? = nil
    ) {
        self.id = id
        self.mediaItemId = mediaItemId
        self.sourceURL = sourceURL
        self.sourceBookmark = sourceBookmark
        self.displayName = displayName
        self.originalSize = originalSize
        self.estimatedOptimizedSize = estimatedOptimizedSize
        self.isVideo = isVideo
        self.needsOptimization = needsOptimization
        self.currentCodec = currentCodec
        self.currentResolution = currentResolution
        self.currentFrameRate = currentFrameRate
        self.currentSampleRate = currentSampleRate
        self.currentBitrate = currentBitrate
    }
}

/// Result of analyzing all project media
struct ProjectAnalysisResult: Sendable, Equatable {
    /// All analyzed items
    let items: [MediaAnalysisItem]

    /// Total original size of all media in bytes
    let totalOriginalSize: UInt64

    /// Estimated total size after optimization in bytes
    let estimatedOptimizedSize: UInt64

    /// Items that need optimization (excludes already-optimized files)
    var itemsNeedingOptimization: [MediaAnalysisItem] {
        items.filter { $0.needsOptimization }
    }

    /// Total estimated savings in bytes
    var estimatedSavings: UInt64 {
        guard estimatedOptimizedSize < totalOriginalSize else { return 0 }
        return totalOriginalSize - estimatedOptimizedSize
    }

    /// Savings as a percentage (0.0 - 1.0)
    var savingsPercentage: Double {
        guard totalOriginalSize > 0 else { return 0 }
        return Double(estimatedSavings) / Double(totalOriginalSize)
    }

    init(items: [MediaAnalysisItem], totalOriginalSize: UInt64, estimatedOptimizedSize: UInt64) {
        self.items = items
        self.totalOriginalSize = totalOriginalSize
        self.estimatedOptimizedSize = estimatedOptimizedSize
    }

    /// Empty result for initial state
    static let empty = ProjectAnalysisResult(items: [], totalOriginalSize: 0, estimatedOptimizedSize: 0)
}

// MARK: - Optimization Options

/// Configuration for the optimization process
///
/// Based on HandBrake "Very Fast 720p30" preset with quality-based encoding:
/// - Video: HEVC hardware-accelerated, quality 0.65 (≈ CRF 23 visual quality)
/// - Audio: AAC stereo, 160 kbps, preserves source sample rate
/// - Frame rate: Preserves source (PFR mode - peak frame rate capped at 30)
///
/// Quality-based encoding (like HandBrake's CRF mode) allocates bits intelligently:
/// - Simple scenes get fewer bits → smaller files
/// - Complex scenes get more bits → maintained quality
/// This typically yields ~1000-1200 kbps for 720p content (vs 2000 kbps with fixed bitrate).
///
/// Note: Original files are never modified. Optimized files are saved to a
/// separate "Optimized Media" folder within the project directory.
struct OptimizationOptions: Sendable, Equatable {
    /// URL of the "Optimized Media" folder where optimized files will be saved
    let optimizedMediaFolderURL: URL

    /// Target video width in pixels (720p = 1280)
    let videoTargetWidth: Int

    /// Target video height in pixels (720p = 720)
    let videoTargetHeight: Int

    /// Target audio bitrate in bits per second
    /// HandBrake preset uses 160 kbps for AAC stereo
    let audioTargetBitrate: Int

    /// Maximum frame rate cap (source fps preserved if below this)
    /// HandBrake "pfr" mode caps at 30fps but preserves lower rates
    let maxFrameRate: Double

    /// Default optimization preset matching HandBrake "Very Fast 720p30" output quality
    /// Uses quality-based encoding which typically yields ~1000-1200 kbps for 720p
    static func handbrakeVeryFast720p(optimizedMediaFolderURL: URL) -> OptimizationOptions {
        OptimizationOptions(
            optimizedMediaFolderURL: optimizedMediaFolderURL,
            videoTargetWidth: 1280,
            videoTargetHeight: 720,
            audioTargetBitrate: 160_000,  // HandBrake AudioBitrate: 160
            maxFrameRate: 30.0            // HandBrake VideoFramerate: "30" with pfr mode
        )
    }

    init(
        optimizedMediaFolderURL: URL,
        videoTargetWidth: Int,
        videoTargetHeight: Int,
        audioTargetBitrate: Int,
        maxFrameRate: Double = 30.0
    ) {
        self.optimizedMediaFolderURL = optimizedMediaFolderURL
        self.videoTargetWidth = videoTargetWidth
        self.videoTargetHeight = videoTargetHeight
        self.audioTargetBitrate = audioTargetBitrate
        self.maxFrameRate = maxFrameRate
    }
}

// MARK: - Progress Types

/// Phase of the optimization process
enum OptimizationPhase: Sendable, Equatable {
    case preparing
    case transcoding(itemName: String)
    case movingFiles
    case updatingReferences
    case complete
}

/// Progress update during optimization
struct OptimizationProgress: Sendable, Equatable {
    /// Index of the currently processing item (0-based)
    let currentItemIndex: Int

    /// Total number of items to process
    let totalItems: Int

    /// Display name of the current item
    let currentItemName: String

    /// Progress of the current item (0.0 - 1.0)
    let currentItemProgress: Double

    /// Overall progress (0.0 - 1.0)
    let overallProgress: Double

    /// Current phase of optimization
    let phase: OptimizationPhase

    init(
        currentItemIndex: Int,
        totalItems: Int,
        currentItemName: String,
        currentItemProgress: Double,
        overallProgress: Double,
        phase: OptimizationPhase
    ) {
        self.currentItemIndex = currentItemIndex
        self.totalItems = totalItems
        self.currentItemName = currentItemName
        self.currentItemProgress = currentItemProgress
        self.overallProgress = overallProgress
        self.phase = phase
    }
}

// MARK: - Result Types

/// Result of optimizing a single item (for verification report)
struct OptimizedItemResult: Sendable, Identifiable, Equatable {
    let id: UUID

    /// Original media item ID
    let mediaItemId: UUID

    /// Display name
    let displayName: String

    /// Original file size
    let originalSize: UInt64

    /// Actual optimized size
    let optimizedSize: UInt64

    /// Original file URL
    let originalURL: URL

    /// New optimized file URL
    let optimizedURL: URL

    /// Whether this was a video (false = audio)
    let isVideo: Bool

    /// Preserved frame rate (video only)
    let frameRate: Double?

    /// Preserved sample rate
    let sampleRate: Double?

    /// Whether optimization succeeded
    let success: Bool

    /// Error message if failed
    let errorMessage: String?

    init(
        id: UUID = UUID(),
        mediaItemId: UUID,
        displayName: String,
        originalSize: UInt64,
        optimizedSize: UInt64,
        originalURL: URL,
        optimizedURL: URL,
        isVideo: Bool,
        frameRate: Double?,
        sampleRate: Double?,
        success: Bool,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.mediaItemId = mediaItemId
        self.displayName = displayName
        self.originalSize = originalSize
        self.optimizedSize = optimizedSize
        self.originalURL = originalURL
        self.optimizedURL = optimizedURL
        self.isVideo = isVideo
        self.frameRate = frameRate
        self.sampleRate = sampleRate
        self.success = success
        self.errorMessage = errorMessage
    }
}

/// Final result of the optimization process
struct OptimizationResult: Sendable, Equatable {
    /// Results for each optimized item (for verification report)
    let itemResults: [OptimizedItemResult]

    /// Number of successfully optimized files
    let optimizedCount: Int

    /// Number of files skipped (already optimized or excluded)
    let skippedCount: Int

    /// Number of files that failed to optimize
    let failedCount: Int

    /// Total bytes saved
    let totalSavedBytes: UInt64

    /// URL of the "Optimized Media" folder where optimized files were saved
    let optimizedMediaFolder: URL

    /// Successfully optimized items
    var successfulItems: [OptimizedItemResult] {
        itemResults.filter { $0.success }
    }

    /// Failed items
    var failedItems: [OptimizedItemResult] {
        itemResults.filter { !$0.success }
    }

    init(
        itemResults: [OptimizedItemResult],
        optimizedCount: Int,
        skippedCount: Int,
        failedCount: Int,
        totalSavedBytes: UInt64,
        optimizedMediaFolder: URL
    ) {
        self.itemResults = itemResults
        self.optimizedCount = optimizedCount
        self.skippedCount = skippedCount
        self.failedCount = failedCount
        self.totalSavedBytes = totalSavedBytes
        self.optimizedMediaFolder = optimizedMediaFolder
    }
}

// MARK: - Error Types

/// Errors that can occur during media optimization
enum MediaOptimizationError: LocalizedError, Sendable {
    case fileAccessDenied(URL)
    case transcodingFailed(URL, String)
    case insufficientDiskSpace(required: UInt64, available: UInt64)
    case unsupportedFormat(URL, String)
    case cancelled
    case noItemsToOptimize

    var errorDescription: String? {
        switch self {
        case .fileAccessDenied(let url):
            return "Cannot access file: \(url.lastPathComponent)"
        case .transcodingFailed(let url, let reason):
            return "Failed to optimize \(url.lastPathComponent): \(reason)"
        case .insufficientDiskSpace(let required, let available):
            return "Insufficient disk space. Required: \(ByteCountFormatter.string(fromByteCount: Int64(required), countStyle: .file)), Available: \(ByteCountFormatter.string(fromByteCount: Int64(available), countStyle: .file))"
        case .unsupportedFormat(let url, let format):
            return "Unsupported format for \(url.lastPathComponent): \(format)"
        case .cancelled:
            return "Optimization was cancelled"
        case .noItemsToOptimize:
            return "No files need optimization"
        }
    }
}

// MARK: - Service Protocol

/// The contract for media optimization services.
///
/// This protocol defines the interface between the Logic layer (actor) and
/// the Presentation layer (ViewModel). It provides:
///
/// 1. **Analysis**: Scan project files and estimate optimization savings
/// 2. **Optimization**: Transcode files with progress reporting
/// 3. **Verification**: Report preserved frame rates and sample rates
///
/// ## Architecture
///
/// ```
/// ┌─────────────────────────────────────────────────────────────────────────┐
/// │                     PRESENTATION LAYER                                   │
/// │                                                                          │
/// │  OptimizationSheetView ←─── OptimizationViewModel (@MainActor)          │
/// │                                   │                                      │
/// │                                   │ Calls async methods                  │
/// │                                   │ Receives progress callbacks          │
/// │                                   ▼                                      │
/// ├───────────────────── MediaOptimizationServiceProtocol ──────────────────┤
/// │                                   ▲                                      │
/// │                                   │ Implemented by                       │
/// │                                   │                                      │
/// │  MediaOptimizationService ◀─── AVAssetWriter/Reader ◀─── File System    │
/// │                                                                          │
/// │                        LOGIC LAYER                                       │
/// └─────────────────────────────────────────────────────────────────────────┘
/// ```
///
/// ## Thread Safety
///
/// - All types are `Sendable` and can cross actor boundaries
/// - Progress callbacks are called from the actor, consumers must dispatch to MainActor
/// - The implementing actor handles all file I/O and transcoding off the main thread
///
/// ## Critical: Timing Preservation
///
/// This service MUST preserve:
/// - Original frame rates (23.976, 24, 29.97, etc.) - NO conversion to 30fps
/// - Original sample rates (48kHz, 44.1kHz, etc.) - NO resampling
///
/// The verification report confirms these values were preserved.
protocol MediaOptimizationServiceProtocol: Sendable {

    // MARK: - Analysis

    /// Analyze all media items in the project and estimate optimization savings.
    ///
    /// This scans each file to determine:
    /// - Current codec, resolution, bitrate
    /// - Whether it needs optimization (already compressed files may not)
    /// - Estimated size after optimization
    ///
    /// - Parameter mediaItems: All media items from the project library
    /// - Returns: Analysis result with per-file and total savings estimates
    func analyzeProject(mediaItems: [MediaItem]) async throws -> ProjectAnalysisResult

    // MARK: - Optimization

    /// Optimize media items with progress reporting.
    ///
    /// For each item:
    /// 1. Video: Transcode to H.264 720p at ~2.5 Mbps, preserving original frame rate
    /// 2. Audio: Transcode to AAC stereo at 128 kbps, preserving original sample rate
    ///
    /// Progress is reported via the callback, which is called from the actor.
    /// The callback should dispatch to MainActor for UI updates.
    ///
    /// - Parameters:
    ///   - items: Analysis items to optimize (from analyzeProject)
    ///   - options: Optimization configuration
    ///   - progressHandler: Callback for progress updates (called from actor)
    /// - Returns: Result with verification report showing preserved timing values
    /// - Throws: `MediaOptimizationError` on failure
    func optimizeMedia(
        items: [MediaAnalysisItem],
        options: OptimizationOptions,
        progressHandler: @escaping @Sendable (OptimizationProgress) async -> Void
    ) async throws -> OptimizationResult

    // MARK: - Cancellation

    /// Cancel the current optimization operation.
    ///
    /// The operation will stop after the current item completes.
    /// Already-optimized files will remain optimized.
    func cancel() async
}
