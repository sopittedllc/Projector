//
//  MediaOptimizationService.swift
//  Projector
//
//  Actor implementing MediaOptimizationServiceProtocol.
//  Handles media analysis, transcoding, and file management.
//
//  CRITICAL: Preserves original frame rates and sample rates.
//  NO conversion to 30fps. NO resampling.
//

import Foundation
import AVFoundation
import VideoToolbox

// MARK: - Sendable Wrappers for AVFoundation Types

/// Thread-safe wrapper for AVAssetWriterInput used in requestMediaDataWhenReady closures.
///
/// AVAssetWriterInput is not Sendable, but we need to access it from dispatch queue callbacks.
/// This wrapper is safe because the input is only accessed from the dedicated video/audio queues.
private final class WriterInputBox: @unchecked Sendable {
    let input: AVAssetWriterInput
    init(_ input: AVAssetWriterInput) { self.input = input }
}

/// Thread-safe wrapper for AVAssetReaderTrackOutput used in requestMediaDataWhenReady closures.
private final class ReaderOutputBox: @unchecked Sendable {
    let output: AVAssetReaderTrackOutput
    init(_ output: AVAssetReaderTrackOutput) { self.output = output }
}

/// Thread-safe cancellation flag accessible from Sendable closures.
///
/// Uses NSLock for thread-safe access from both the actor and dispatch queue callbacks.
private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _isCancelled = false

    /// Whether cancellation has been requested.
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isCancelled
    }

    /// Requests cancellation of the current operation.
    func cancel() {
        lock.lock()
        _isCancelled = true
        lock.unlock()
    }

    /// Resets the cancellation flag for a new operation.
    func reset() {
        lock.lock()
        _isCancelled = false
        lock.unlock()
    }
}

// MARK: - MediaOptimizationService

/// Actor that handles media optimization (analysis and transcoding).
///
/// `MediaOptimizationService` analyzes media files to determine if optimization is needed,
/// then transcodes them to efficient formats. It uses hardware-accelerated HEVC encoding
/// on Apple Silicon for fast, high-quality results.
///
/// ## Architecture
///
/// ```
/// ┌─────────────────────────────────────────────────────────────────┐
/// │                  OptimizeMediaView (UI)                         │
/// │  (shows progress, handles cancellation)                         │
/// └─────────────────────────────────────────────────────────────────┘
///                               │
///                               ▼
/// ┌─────────────────────────────────────────────────────────────────┐
/// │          MediaOptimizationService (this file)                   │
/// │  - Analyzes media for optimization needs                        │
/// │  - Transcodes video to HEVC 720p using hardware acceleration    │
/// │  - Transcodes audio to AAC stereo                               │
/// │  - Preserves original frame rates and sample rates              │
/// └─────────────────────────────────────────────────────────────────┘
///                               │
///                               ▼
/// ┌─────────────────────────────────────────────────────────────────┐
/// │  AVAssetReader/Writer + VideoToolbox (hardware encoding)        │
/// └─────────────────────────────────────────────────────────────────┘
/// ```
///
/// ## Encoding Strategy
///
/// Video is transcoded using quality-based encoding (similar to CRF mode in HandBrake):
/// - **Codec**: HEVC (H.265) for ~40% better compression than H.264
/// - **Resolution**: 720p (1280×720)
/// - **Quality**: 0.65 (~CRF 23 equivalent, typically yields ~1000-1200 kbps)
/// - **Hardware**: Uses Apple Silicon Media Engine via VideoToolbox
///
/// Audio is transcoded to AAC stereo at 160 kbps, preserving the original sample rate.
///
/// ## Usage
///
/// ```swift
/// let service = MediaOptimizationService()
///
/// // Analyze project media
/// let analysis = try await service.analyzeProject(mediaItems: items)
///
/// // Optimize files that need it
/// let result = try await service.optimizeMedia(
///     items: analysis.items,
///     options: options
/// ) { progress in
///     print("Progress: \(progress.overallProgress * 100)%")
/// }
/// ```
///
/// ## Thread Safety
///
/// This is a Swift Actor, so all state is isolated. Transcoding uses dedicated
/// dispatch queues for video and audio processing via `requestMediaDataWhenReady`.
actor MediaOptimizationService: MediaOptimizationServiceProtocol {

    // MARK: - Properties

    private let cancellationFlag = CancellationFlag()

    private var isCancelled: Bool {
        get { cancellationFlag.isCancelled }
    }

    /// Target encoding specifications for optimized media.
    ///
    /// These values are tuned for a balance of quality, file size, and encoding speed.
    /// Matches HandBrake's "Very Fast 720p30" preset quality.
    private enum TargetSpecs {
        /// Target video width (720p).
        static let videoWidth = 1280

        /// Target video height (720p).
        static let videoHeight = 720

        /// Quality-based encoding value (0.0-1.0 scale).
        ///
        /// 0.65 ≈ CRF 23 equivalent visual quality, results in ~1000-1200 kbps for 720p.
        /// This matches HandBrake's "Very Fast 720p30" output quality.
        static let videoQuality: Float = 0.65

        /// Target audio bitrate in bits per second (160 kbps AAC stereo).
        static let audioBitrate = 160_000

        /// Maximum frame rate (preserves lower rates).
        static let maxFrameRate = 30.0
    }

    // MARK: - Analysis

    /// Analyzes all media items in a project to determine optimization needs.
    ///
    /// Examines each item's codec, resolution, and bitrate to determine if transcoding
    /// would reduce file size. Files already in efficient formats are skipped.
    ///
    /// - Parameter mediaItems: Array of media items to analyze.
    /// - Returns: Analysis result with per-item details and size estimates.
    /// - Throws: Errors from file access or AVFoundation asset loading.
    func analyzeProject(mediaItems: [MediaItem]) async throws -> ProjectAnalysisResult {
        debugPrint("MediaOptimizationService.analyzeProject: analyzing \(mediaItems.count) items")
        var analysisItems: [MediaAnalysisItem] = []
        var totalOriginalSize: UInt64 = 0
        var totalEstimatedSize: UInt64 = 0

        for item in mediaItems {
            debugPrint("MediaOptimizationService.analyzeProject: analyzing \(item.displayName) (type: \(item.type))")
            let analysis = try await analyzeMediaItem(item)
            debugPrint("MediaOptimizationService.analyzeProject: \(item.displayName) - needsOptimization: \(analysis.needsOptimization), codec: \(analysis.currentCodec ?? "unknown")")
            analysisItems.append(analysis)
            totalOriginalSize += analysis.originalSize
            totalEstimatedSize += analysis.estimatedOptimizedSize
        }

        debugPrint("MediaOptimizationService.analyzeProject: complete - \(analysisItems.count) items, \(analysisItems.filter { $0.needsOptimization }.count) need optimization")
        return ProjectAnalysisResult(
            items: analysisItems,
            totalOriginalSize: totalOriginalSize,
            estimatedOptimizedSize: totalEstimatedSize
        )
    }

    private func analyzeMediaItem(_ item: MediaItem) async throws -> MediaAnalysisItem {
        // Get file size
        let fileSize = try getFileSize(url: item.url, bookmark: item.bookmark)

        // Get codec information
        let codecInfo = try await getCodecInfo(url: item.url, bookmark: item.bookmark, isVideo: item.type == .video)

        // Estimate optimized size based on target bitrate and duration
        let estimatedSize = estimateOptimizedSize(
            duration: item.duration,
            isVideo: item.type == .video
        )

        // Determine if optimization is needed
        let optimizationCheck = shouldOptimize(
            isVideo: item.type == .video,
            currentCodec: codecInfo.codec,
            currentResolution: item.videoSize,
            currentBitrate: codecInfo.bitrate
        )

        return MediaAnalysisItem(
            mediaItemId: item.id,
            sourceURL: item.url,
            sourceBookmark: item.bookmark,
            displayName: item.displayName,
            originalSize: fileSize,
            estimatedOptimizedSize: optimizationCheck.needsOptimization ? estimatedSize : fileSize,
            isVideo: item.type == .video,
            needsOptimization: optimizationCheck.needsOptimization,
            skipReason: optimizationCheck.skipReason,
            currentCodec: codecInfo.codec,
            currentResolution: item.videoSize,
            currentFrameRate: item.frameRate,
            currentSampleRate: item.sampleRate,
            currentBitrate: codecInfo.bitrate
        )
    }

    private func getFileSize(url: URL, bookmark: Data?) throws -> UInt64 {
        var accessingURL = url
        var didStartAccess = false

        // Try to resolve bookmark for sandbox access
        if let bookmark = bookmark {
            var isStale = false
            if let resolvedURL = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) {
                accessingURL = resolvedURL
                didStartAccess = accessingURL.startAccessingSecurityScopedResource()
            }
        }

        defer {
            if didStartAccess {
                accessingURL.stopAccessingSecurityScopedResource()
            }
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: accessingURL.path)
        return attributes[.size] as? UInt64 ?? 0
    }

    private struct CodecInfo {
        let codec: String?
        let bitrate: Int?
    }

    private func getCodecInfo(url: URL, bookmark: Data?, isVideo: Bool) async throws -> CodecInfo {
        var accessingURL = url
        var didStartAccess = false

        if let bookmark = bookmark {
            var isStale = false
            if let resolvedURL = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) {
                accessingURL = resolvedURL
                didStartAccess = accessingURL.startAccessingSecurityScopedResource()
            }
        }

        defer {
            if didStartAccess {
                accessingURL.stopAccessingSecurityScopedResource()
            }
        }

        let asset = AVURLAsset(url: accessingURL)

        if isVideo {
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let videoTrack = videoTracks.first else {
                return CodecInfo(codec: nil, bitrate: nil)
            }

            let formatDescriptions = try await videoTrack.load(.formatDescriptions)
            var codecName: String?
            var bitrate: Int?

            if let formatDesc = formatDescriptions.first {
                let mediaSubType = CMFormatDescriptionGetMediaSubType(formatDesc)
                codecName = fourCCToString(mediaSubType)
            }

            // Estimate bitrate from file size and duration
            let duration = try await asset.load(.duration)
            if duration.seconds > 0 {
                let fileSize = try getFileSize(url: url, bookmark: bookmark)
                bitrate = Int((Double(fileSize) * 8) / duration.seconds)
            }

            return CodecInfo(codec: codecName, bitrate: bitrate)
        } else {
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard let audioTrack = audioTracks.first else {
                return CodecInfo(codec: nil, bitrate: nil)
            }

            let formatDescriptions = try await audioTrack.load(.formatDescriptions)
            var codecName: String?
            var bitrate: Int?

            if let formatDesc = formatDescriptions.first {
                let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
                if let format = asbd?.pointee {
                    switch format.mFormatID {
                    case kAudioFormatLinearPCM:
                        codecName = "PCM"
                    case kAudioFormatMPEG4AAC:
                        codecName = "AAC"
                    case kAudioFormatMPEGLayer3:
                        codecName = "MP3"
                    case kAudioFormatAppleLossless:
                        codecName = "ALAC"
                    case kAudioFormatFLAC:
                        codecName = "FLAC"
                    default:
                        codecName = "Unknown"
                    }
                }
            }

            // Estimate bitrate
            let duration = try await asset.load(.duration)
            if duration.seconds > 0 {
                let fileSize = try getFileSize(url: url, bookmark: bookmark)
                bitrate = Int((Double(fileSize) * 8) / duration.seconds)
            }

            return CodecInfo(codec: codecName, bitrate: bitrate)
        }
    }

    private func fourCCToString(_ fourCC: FourCharCode) -> String {
        // Common video codec mappings
        switch fourCC {
        case kCMVideoCodecType_AppleProRes4444XQ: return "ProRes 4444 XQ"
        case kCMVideoCodecType_AppleProRes4444: return "ProRes 4444"
        case kCMVideoCodecType_AppleProRes422HQ: return "ProRes 422 HQ"
        case kCMVideoCodecType_AppleProRes422: return "ProRes 422"
        case kCMVideoCodecType_AppleProRes422LT: return "ProRes 422 LT"
        case kCMVideoCodecType_AppleProRes422Proxy: return "ProRes 422 Proxy"
        case kCMVideoCodecType_H264: return "H.264"
        case kCMVideoCodecType_HEVC: return "HEVC"
        case kCMVideoCodecType_JPEG: return "JPEG"
        case kCMVideoCodecType_MPEG4Video: return "MPEG-4"
        default:
            // Convert FourCC to string safely
            let bytes = [
                (fourCC >> 24) & 0xFF,
                (fourCC >> 16) & 0xFF,
                (fourCC >> 8) & 0xFF,
                fourCC & 0xFF
            ]
            let chars = bytes.compactMap { UnicodeScalar($0) }.map { Character($0) }
            return chars.count == 4 ? String(chars) : String(format: "0x%08X", fourCC)
        }
    }

    /// Estimate optimized file size based on target bitrate and duration
    ///
    /// This provides accurate estimates by calculating:
    /// - Video: ~1000 kbps average (from quality 0.65 HEVC at 720p) × duration
    /// - Audio: 160 kbps AAC stereo × duration
    private func estimateOptimizedSize(duration: Double, isVideo: Bool) -> UInt64 {
        guard duration > 0 else { return 0 }

        if isVideo {
            // HEVC at quality 0.65 averages ~1000 kbps for 720p content
            // Add 160 kbps for audio track
            let videoBitrate: Double = 1_000_000  // 1000 kbps
            let audioBitrate: Double = Double(TargetSpecs.audioBitrate)  // 160 kbps
            let totalBitrate = videoBitrate + audioBitrate

            // Size = bitrate (bits/sec) × duration (sec) / 8 (bits to bytes)
            return UInt64((totalBitrate * duration) / 8)
        } else {
            // Audio only: AAC stereo at 160 kbps
            let audioBitrate: Double = Double(TargetSpecs.audioBitrate)
            return UInt64((audioBitrate * duration) / 8)
        }
    }

    /// Result of optimization check
    private struct OptimizationCheck {
        let needsOptimization: Bool
        let skipReason: String?
    }

    private func shouldOptimize(isVideo: Bool, currentCodec: String?, currentResolution: CGSize?, currentBitrate: Int?) -> OptimizationCheck {
        let codec = currentCodec?.lowercased() ?? ""

        if isVideo {
            // Skip if already H.264/HEVC at 720p or lower with reasonable bitrate
            let skipBitrateThreshold = 2_000_000  // 2 Mbps
            if codec.contains("h.264") || codec.contains("avc") || codec.contains("hevc") {
                if let resolution = currentResolution,
                   resolution.width <= CGFloat(TargetSpecs.videoWidth),
                   resolution.height <= CGFloat(TargetSpecs.videoHeight) {
                    if let bitrate = currentBitrate, bitrate <= skipBitrateThreshold {
                        let codecName = codec.contains("hevc") ? "HEVC" : "H.264"
                        let bitrateStr = formatBitrate(bitrate)
                        return OptimizationCheck(
                            needsOptimization: false,
                            skipReason: "Already \(codecName) at \(Int(resolution.width))×\(Int(resolution.height)), \(bitrateStr)"
                        )
                    }
                }
            }
            return OptimizationCheck(needsOptimization: true, skipReason: nil)
        } else {
            // Skip if already AAC/MP3 with low bitrate
            if codec == "aac" || codec == "mp3" {
                if let bitrate = currentBitrate, bitrate <= TargetSpecs.audioBitrate * 2 {
                    let codecName = codec.uppercased()
                    let bitrateStr = formatBitrate(bitrate)
                    return OptimizationCheck(
                        needsOptimization: false,
                        skipReason: "Already \(codecName) at \(bitrateStr)"
                    )
                }
            }
            return OptimizationCheck(needsOptimization: true, skipReason: nil)
        }
    }

    private func formatBitrate(_ bitrate: Int) -> String {
        if bitrate >= 1_000_000 {
            return String(format: "%.1f Mbps", Double(bitrate) / 1_000_000)
        } else {
            return "\(bitrate / 1000) kbps"
        }
    }

    // MARK: - Optimization (Transcoding)

    /// Optimizes media files by transcoding to efficient formats.
    ///
    /// Transcodes video to HEVC 720p and audio to AAC stereo. Files are written
    /// to the "Optimized Media" folder within the project package.
    ///
    /// - Parameters:
    ///   - items: Analysis items indicating which files need optimization.
    ///   - options: Configuration including output folder and quality settings.
    ///   - progressHandler: Async callback for progress updates.
    /// - Returns: Result containing per-item outcomes and summary statistics.
    /// - Throws: ``MediaOptimizationError.cancelled`` if user cancels.
    ///           ``MediaOptimizationError.insufficientDiskSpace`` if not enough space.
    func optimizeMedia(
        items: [MediaAnalysisItem],
        options: OptimizationOptions,
        progressHandler: @escaping @Sendable (OptimizationProgress) async -> Void
    ) async throws -> OptimizationResult {
        resetCancellation()

        let itemsToOptimize = items.filter { $0.needsOptimization }
        guard !itemsToOptimize.isEmpty else {
            throw MediaOptimizationError.noItemsToOptimize
        }

        // Check disk space - we need space for optimized copies (not replacing originals)
        let requiredSpace = itemsToOptimize.reduce(0) { $0 + $1.estimatedOptimizedSize }
        let availableSpace = try availableDiskSpace()
        if availableSpace < requiredSpace {
            throw MediaOptimizationError.insufficientDiskSpace(required: requiredSpace, available: availableSpace)
        }

        var itemResults: [OptimizedItemResult] = []
        var optimizedCount = 0
        var failedCount = 0
        var totalSaved: UInt64 = 0

        // Create the "Optimized Media" folder
        let optimizedMediaFolder = options.optimizedMediaFolderURL
        try FileManager.default.createDirectory(at: optimizedMediaFolder, withIntermediateDirectories: true)
        debugPrint("MediaOptimizationService: Created Optimized Media folder at \(optimizedMediaFolder.path)")

        for (index, item) in itemsToOptimize.enumerated() {
            if isCancelled {
                throw MediaOptimizationError.cancelled
            }

            // Report progress
            let progress = OptimizationProgress(
                currentItemIndex: index,
                totalItems: itemsToOptimize.count,
                currentItemName: item.displayName,
                currentItemProgress: 0,
                overallProgress: Double(index) / Double(itemsToOptimize.count),
                phase: .transcoding(itemName: item.displayName)
            )
            await progressHandler(progress)

            do {
                let result = try await optimizeItem(
                    item,
                    options: options,
                    progressHandler: { itemProgress in
                        let overallProgress = (Double(index) + itemProgress) / Double(itemsToOptimize.count)
                        let progress = OptimizationProgress(
                            currentItemIndex: index,
                            totalItems: itemsToOptimize.count,
                            currentItemName: item.displayName,
                            currentItemProgress: itemProgress,
                            overallProgress: overallProgress,
                            phase: .transcoding(itemName: item.displayName)
                        )
                        await progressHandler(progress)
                    }
                )
                itemResults.append(result)

                if result.success {
                    optimizedCount += 1
                    if result.originalSize > result.optimizedSize {
                        totalSaved += result.originalSize - result.optimizedSize
                    }
                } else {
                    failedCount += 1
                }
            } catch {
                failedCount += 1
                // Create failed result
                // Note: We need to get the original URL somehow - for now using a placeholder approach
                debugPrint("MediaOptimizationService: Failed to optimize \(item.displayName): \(error)")
            }
        }

        // Final progress
        await progressHandler(OptimizationProgress(
            currentItemIndex: itemsToOptimize.count,
            totalItems: itemsToOptimize.count,
            currentItemName: "",
            currentItemProgress: 1.0,
            overallProgress: 1.0,
            phase: .complete
        ))

        return OptimizationResult(
            itemResults: itemResults,
            optimizedCount: optimizedCount,
            skippedCount: items.count - itemsToOptimize.count,
            failedCount: failedCount,
            totalSavedBytes: totalSaved,
            optimizedMediaFolder: optimizedMediaFolder
        )
    }

    private func optimizeItem(
        _ item: MediaAnalysisItem,
        options: OptimizationOptions,
        progressHandler: @escaping @Sendable (Double) async -> Void
    ) async throws -> OptimizedItemResult {
        // Resolve the source URL with security scope
        var sourceURL = item.sourceURL
        var didStartAccess = false

        if let bookmark = item.sourceBookmark {
            var isStale = false
            if let resolvedURL = try? URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                sourceURL = resolvedURL
                didStartAccess = sourceURL.startAccessingSecurityScopedResource()
            }
        }

        defer {
            if didStartAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        // Create output URL in the "Optimized Media" folder
        // Keep the original filename but with new extension
        let outputExtension = item.isVideo ? "mp4" : "m4a"
        let outputName = sourceURL.deletingPathExtension().lastPathComponent
        let outputURL = options.optimizedMediaFolderURL
            .appendingPathComponent(outputName)
            .appendingPathExtension(outputExtension)

        do {
            debugPrint("MediaOptimizationService: Starting transcode for \(item.displayName)")
            debugPrint("MediaOptimizationService: Output will be saved to \(outputURL.path)")

            if item.isVideo {
                try await transcodeVideo(
                    from: sourceURL,
                    to: outputURL,
                    options: options,
                    sourceFrameRate: item.currentFrameRate,
                    progressHandler: progressHandler
                )
            } else {
                try await transcodeAudio(
                    from: sourceURL,
                    to: outputURL,
                    sourceSampleRate: item.currentSampleRate,
                    progressHandler: progressHandler
                )
            }

            debugPrint("MediaOptimizationService: Transcode complete, getting output size")

            // Get actual output file size
            let outputAttributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
            let outputSize = outputAttributes[.size] as? UInt64 ?? 0

            debugPrint("MediaOptimizationService: Output size: \(outputSize) bytes")
            debugPrint("MediaOptimizationService: Original file left untouched at \(sourceURL.path)")

            debugPrint("MediaOptimizationService: Verifying output file")

            // Verify preserved frame rate/sample rate from output file
            let verifiedFrameRate = item.isVideo ? try await getOutputFrameRate(url: outputURL) : nil
            let verifiedSampleRate = try await getOutputSampleRate(url: outputURL)

            debugPrint("MediaOptimizationService: Verification complete - frameRate: \(String(describing: verifiedFrameRate)), sampleRate: \(String(describing: verifiedSampleRate))")

            return OptimizedItemResult(
                mediaItemId: item.mediaItemId,
                displayName: item.displayName,
                originalSize: item.originalSize,
                optimizedSize: outputSize,
                originalURL: item.sourceURL,
                optimizedURL: outputURL,
                isVideo: item.isVideo,
                frameRate: verifiedFrameRate,
                sampleRate: verifiedSampleRate,
                success: true
            )
        } catch {
            // Clean up partial output if exists
            try? FileManager.default.removeItem(at: outputURL)

            return OptimizedItemResult(
                mediaItemId: item.mediaItemId,
                displayName: item.displayName,
                originalSize: item.originalSize,
                optimizedSize: 0,
                originalURL: item.sourceURL,
                optimizedURL: item.sourceURL,
                isVideo: item.isVideo,
                frameRate: nil,
                sampleRate: nil,
                success: false,
                errorMessage: error.localizedDescription
            )
        }
    }

    // MARK: - Video Transcoding

    private func transcodeVideo(
        from sourceURL: URL,
        to outputURL: URL,
        options: OptimizationOptions,
        sourceFrameRate: Double?,
        progressHandler: @escaping @Sendable (Double) async -> Void
    ) async throws {
        let asset = AVURLAsset(url: sourceURL)

        // Load tracks
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        guard let videoTrack = videoTracks.first else {
            throw MediaOptimizationError.unsupportedFormat(sourceURL, "No video track found")
        }

        let duration = try await asset.load(.duration)
        let totalSeconds = duration.seconds

        // Set up asset reader
        let reader = try AVAssetReader(asset: asset)

        // Video reader output (decompress to raw frames)
        let videoReaderOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ]
        )
        videoReaderOutput.alwaysCopiesSampleData = false

        if reader.canAdd(videoReaderOutput) {
            reader.add(videoReaderOutput)
        }

        // Audio reader output (if present)
        // CRITICAL: Preserve source sample rate per HandBrake AudioSamplerate: "auto"
        var audioReaderOutput: AVAssetReaderTrackOutput?
        var sourceSampleRate: Double = 48000  // Default fallback
        if let audioTrack = audioTracks.first {
            // Get source sample rate to preserve it
            let audioFormatDescs = try await audioTrack.load(.formatDescriptions)
            if let formatDesc = audioFormatDescs.first {
                let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
                if let rate = asbd?.pointee.mSampleRate, rate > 0 {
                    sourceSampleRate = rate
                }
            }

            let output = AVAssetReaderTrackOutput(
                track: audioTrack,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: sourceSampleRate,  // Preserve source sample rate
                    AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false
                ]
            )
            output.alwaysCopiesSampleData = false
            if reader.canAdd(output) {
                reader.add(output)
                audioReaderOutput = output
            }
        }

        // Set up asset writer
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        // Video writer input with HEVC encoding using HARDWARE ACCELERATION
        // HEVC provides ~40% better compression than H.264 at same quality,
        // and hardware encoding speed is identical on Apple Silicon.
        //
        // HARDWARE ACCELERATION: Using VideoToolbox via kVTVideoEncoderSpecification
        // This enables Apple Silicon Media Engine hardware encoding which is
        // 5-10x faster than software encoding with identical quality.
        //
        // QUALITY-BASED ENCODING (like HandBrake's CRF mode):
        // Instead of targeting a fixed bitrate (which wastes bits on simple scenes),
        // we use quality-based encoding that allocates bits intelligently:
        // - Simple scenes: fewer bits needed, smaller file
        // - Complex scenes: more bits for quality
        // This matches HandBrake's CRF 23 approach which achieved ~1091 kbps for 720p.
        //
        // PERFORMANCE OPTIMIZATIONS:
        // - AllowOpenGOP: Allows more efficient encoding with open GOPs
        // - MaxFrameDelayCount: Limits frame buffering for faster throughput
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,  // HEVC for better compression
            AVVideoWidthKey: options.videoTargetWidth,
            AVVideoHeightKey: options.videoTargetHeight,
            AVVideoCompressionPropertiesKey: [
                // QUALITY-BASED ENCODING: Use quality factor instead of average bitrate
                // 0.65 ≈ CRF 23 visual quality, typically yields ~1000-1200 kbps for 720p
                // This is the key change that reduces file size by ~50% vs fixed 2 Mbps
                kVTCompressionPropertyKey_Quality as String: TargetSpecs.videoQuality,
                AVVideoMaxKeyFrameIntervalKey: 60,  // Longer GOP for HEVC efficiency
                AVVideoAllowFrameReorderingKey: true,  // B-frames for better compression
                AVVideoExpectedSourceFrameRateKey: sourceFrameRate ?? 30.0,  // Hint for encoder
                // Performance optimizations
                kVTCompressionPropertyKey_RealTime as String: false,  // Quality mode (not streaming)
                kVTCompressionPropertyKey_AllowOpenGOP as String: true,  // Better compression
                kVTCompressionPropertyKey_MaxFrameDelayCount as String: 3  // HEVC only allows value of 3
            ],
            // Request hardware encoding via VideoToolbox
            AVVideoEncoderSpecificationKey: [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: false  // Fallback to software if needed
            ]
        ]

        let videoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoWriterInput.expectsMediaDataInRealTime = false

        // Get source transform to handle rotation
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        videoWriterInput.transform = preferredTransform

        if writer.canAdd(videoWriterInput) {
            writer.add(videoWriterInput)
        }

        // Audio writer input with AAC encoding
        // Settings match HandBrake: AAC stereo, 160kbps, preserve sample rate
        var audioWriterInput: AVAssetWriterInput?
        if audioReaderOutput != nil {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sourceSampleRate,  // Preserve source sample rate
                AVNumberOfChannelsKey: 2,           // HandBrake AudioMixdown: "stereo"
                AVEncoderBitRateKey: options.audioTargetBitrate  // HandBrake: 160kbps
            ]

            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = false

            if writer.canAdd(input) {
                writer.add(input)
                audioWriterInput = input
            }
        }

        // Start reading and writing
        reader.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        // Process video and audio using event-driven requestMediaDataWhenReady
        // This is MUCH faster than sleep-based polling - the encoder notifies us
        // when it's ready for more data instead of us constantly checking.
        let videoQueue = DispatchQueue(label: "com.projector.video-transcoding")
        let audioQueue = DispatchQueue(label: "com.projector.audio-transcoding")

        // Capture progress for async reporting
        var lastReportedProgress: Double = 0
        let progressLock = NSLock()

        // Use continuations to wait for completion
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var videoFinished = false
            var audioFinished = audioReaderOutput == nil  // Already finished if no audio
            let completionLock = NSLock()

            func checkCompletion() {
                completionLock.lock()
                let done = videoFinished && audioFinished
                completionLock.unlock()
                if done {
                    continuation.resume()
                }
            }

            // Wrap AVFoundation objects for Sendable closure compatibility
            let videoWriterBox = WriterInputBox(videoWriterInput)
            let videoReaderBox = ReaderOutputBox(videoReaderOutput)
            let cancelFlag = self.cancellationFlag

            // Video processing with requestMediaDataWhenReady (event-driven, not polling)
            videoWriterInput.requestMediaDataWhenReady(on: videoQueue) {
                let writerInput = videoWriterBox.input
                let readerOutput = videoReaderBox.output

                while writerInput.isReadyForMoreMediaData {
                    // Check cancellation
                    if cancelFlag.isCancelled {
                        writerInput.markAsFinished()
                        completionLock.lock()
                        videoFinished = true
                        completionLock.unlock()
                        checkCompletion()
                        return
                    }

                    guard let sampleBuffer = readerOutput.copyNextSampleBuffer() else {
                        // No more samples
                        writerInput.markAsFinished()
                        completionLock.lock()
                        videoFinished = true
                        completionLock.unlock()
                        checkCompletion()
                        return
                    }

                    // Calculate and report progress
                    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    let progress = min(pts.seconds / totalSeconds, 1.0)

                    progressLock.lock()
                    if progress - lastReportedProgress >= 0.01 {
                        lastReportedProgress = progress
                        progressLock.unlock()
                        Task {
                            await progressHandler(progress)
                        }
                    } else {
                        progressLock.unlock()
                    }

                    // Append the sample buffer
                    writerInput.append(sampleBuffer)
                }
            }

            // Audio processing (if present) - also event-driven
            if let audioOutput = audioReaderOutput, let audioInput = audioWriterInput {
                let audioWriterBox = WriterInputBox(audioInput)
                let audioReaderBox = ReaderOutputBox(audioOutput)

                audioInput.requestMediaDataWhenReady(on: audioQueue) {
                    let writerInput = audioWriterBox.input
                    let readerOutput = audioReaderBox.output

                    while writerInput.isReadyForMoreMediaData {
                        guard let sampleBuffer = readerOutput.copyNextSampleBuffer() else {
                            writerInput.markAsFinished()
                            completionLock.lock()
                            audioFinished = true
                            completionLock.unlock()
                            checkCompletion()
                            return
                        }
                        writerInput.append(sampleBuffer)
                    }
                }
            }
        }

        // Check for cancellation
        if isCancelled {
            reader.cancelReading()
            writer.cancelWriting()
            throw MediaOptimizationError.cancelled
        }

        // Finish writing
        await writer.finishWriting()

        // Check writer status - must be completed
        switch writer.status {
        case .completed:
            debugPrint("MediaOptimizationService: Video transcoding completed successfully")
        case .failed:
            throw MediaOptimizationError.transcodingFailed(
                sourceURL,
                writer.error?.localizedDescription ?? "Unknown error"
            )
        case .cancelled:
            throw MediaOptimizationError.cancelled
        default:
            throw MediaOptimizationError.transcodingFailed(
                sourceURL,
                "Writer ended with unexpected status: \(writer.status.rawValue)"
            )
        }

        // Final progress update
        await progressHandler(1.0)
    }


    // MARK: - Audio Transcoding

    private func transcodeAudio(
        from sourceURL: URL,
        to outputURL: URL,
        sourceSampleRate: Double?,
        progressHandler: @escaping @Sendable (Double) async -> Void
    ) async throws {
        let asset = AVURLAsset(url: sourceURL)

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw MediaOptimizationError.unsupportedFormat(sourceURL, "Cannot create export session")
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a

        // CRITICAL: Preserve original sample rate by not resampling
        // AVAssetExportPresetAppleM4A preserves the source sample rate

        debugPrint("MediaOptimizationService: Starting audio export for \(sourceURL.lastPathComponent)")

        // Start export asynchronously and monitor progress
        exportSession.exportAsynchronously { }

        // Monitor progress while exporting
        while exportSession.status == .exporting || exportSession.status == .waiting {
            await progressHandler(Double(exportSession.progress))

            if isCancelled {
                exportSession.cancelExport()
                throw MediaOptimizationError.cancelled
            }

            try await Task.sleep(nanoseconds: 100_000_000)  // Check every 0.1s
        }

        // Check final status
        switch exportSession.status {
        case .completed:
            debugPrint("MediaOptimizationService: Audio export completed successfully")
        case .failed:
            throw MediaOptimizationError.transcodingFailed(
                sourceURL,
                exportSession.error?.localizedDescription ?? "Unknown error"
            )
        case .cancelled:
            throw MediaOptimizationError.cancelled
        default:
            throw MediaOptimizationError.transcodingFailed(
                sourceURL,
                "Export ended with unexpected status: \(exportSession.status.rawValue)"
            )
        }

        await progressHandler(1.0)
    }

    // MARK: - Verification Helpers

    private func getOutputFrameRate(url: URL) async throws -> Double? {
        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = videoTracks.first else { return nil }

        let frameRate = try await track.load(.nominalFrameRate)
        return Double(frameRate)
    }

    private func getOutputSampleRate(url: URL) async throws -> Double? {
        let asset = AVURLAsset(url: url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = audioTracks.first else { return nil }

        let formatDescriptions = try await track.load(.formatDescriptions)
        guard let formatDesc = formatDescriptions.first else { return nil }

        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        return asbd?.pointee.mSampleRate
    }

    private func availableDiskSpace() throws -> UInt64 {
        let fileURL = URL(fileURLWithPath: NSHomeDirectory())
        let values = try fileURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return UInt64(values.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    // MARK: - Cancellation

    /// Requests cancellation of the current optimization operation.
    ///
    /// The running transcode will stop at the next safe point and throw
    /// ``MediaOptimizationError.cancelled``. Partial output files are cleaned up.
    func cancel() async {
        cancellationFlag.cancel()
    }

    /// Resets the cancellation flag for a new optimization run.
    private func resetCancellation() {
        cancellationFlag.reset()
    }
}
