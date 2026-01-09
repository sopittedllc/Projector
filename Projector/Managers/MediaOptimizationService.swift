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

/// Actor that handles media optimization (analysis and transcoding)
actor MediaOptimizationService: MediaOptimizationServiceProtocol {

    // MARK: - Properties

    private var isCancelled = false

    /// Estimated compression ratios for different source formats
    private enum CompressionEstimates {
        /// ProRes files compress very well to H.264
        static let proResToH264: Double = 0.15

        /// Already-compressed formats (H.264, HEVC) have less savings
        static let compressedToH264: Double = 0.7

        /// Uncompressed/lossless to H.264
        static let uncompressedToH264: Double = 0.10

        /// PCM/WAV to AAC
        static let pcmToAAC: Double = 0.10

        /// Already compressed audio (MP3, AAC)
        static let compressedAudioToAAC: Double = 0.9
    }

    /// Target specs
    private enum TargetSpecs {
        static let videoWidth = 1280
        static let videoHeight = 720
        static let videoBitrate = 2_500_000  // 2.5 Mbps
        static let audioBitrate = 128_000    // 128 kbps
    }

    // MARK: - Analysis

    func analyzeProject(mediaItems: [MediaItem]) async throws -> ProjectAnalysisResult {
        var analysisItems: [MediaAnalysisItem] = []
        var totalOriginalSize: UInt64 = 0
        var totalEstimatedSize: UInt64 = 0

        for item in mediaItems {
            let analysis = try await analyzeMediaItem(item)
            analysisItems.append(analysis)
            totalOriginalSize += analysis.originalSize
            totalEstimatedSize += analysis.estimatedOptimizedSize
        }

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

        // Estimate optimized size
        let estimatedSize = estimateOptimizedSize(
            originalSize: fileSize,
            isVideo: item.type == .video,
            currentCodec: codecInfo.codec,
            currentResolution: item.videoSize
        )

        // Determine if optimization is needed
        let needsOptimization = shouldOptimize(
            isVideo: item.type == .video,
            currentCodec: codecInfo.codec,
            currentResolution: item.videoSize,
            currentBitrate: codecInfo.bitrate
        )

        return MediaAnalysisItem(
            mediaItemId: item.id,
            displayName: item.displayName,
            originalSize: fileSize,
            estimatedOptimizedSize: needsOptimization ? estimatedSize : fileSize,
            isVideo: item.type == .video,
            needsOptimization: needsOptimization,
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
            // Convert FourCC to string
            let chars = [
                Character(UnicodeScalar((fourCC >> 24) & 0xFF)!),
                Character(UnicodeScalar((fourCC >> 16) & 0xFF)!),
                Character(UnicodeScalar((fourCC >> 8) & 0xFF)!),
                Character(UnicodeScalar(fourCC & 0xFF)!)
            ]
            return String(chars)
        }
    }

    private func estimateOptimizedSize(originalSize: UInt64, isVideo: Bool, currentCodec: String?, currentResolution: CGSize?) -> UInt64 {
        let codec = currentCodec?.lowercased() ?? ""

        if isVideo {
            // Determine compression ratio based on source codec
            var ratio: Double

            if codec.contains("prores") {
                ratio = CompressionEstimates.proResToH264
            } else if codec.contains("h.264") || codec.contains("avc") || codec.contains("hevc") {
                ratio = CompressionEstimates.compressedToH264
            } else {
                ratio = CompressionEstimates.uncompressedToH264
            }

            // Adjust for resolution scaling if source is larger than 720p
            if let resolution = currentResolution {
                let sourcePixels = resolution.width * resolution.height
                let targetPixels = CGFloat(TargetSpecs.videoWidth * TargetSpecs.videoHeight)
                if sourcePixels > targetPixels {
                    ratio *= (targetPixels / sourcePixels)
                }
            }

            return UInt64(Double(originalSize) * ratio)
        } else {
            // Audio compression estimate
            if codec == "pcm" || codec.contains("wav") || codec.contains("aiff") || codec == "alac" || codec == "flac" {
                return UInt64(Double(originalSize) * CompressionEstimates.pcmToAAC)
            } else {
                return UInt64(Double(originalSize) * CompressionEstimates.compressedAudioToAAC)
            }
        }
    }

    private func shouldOptimize(isVideo: Bool, currentCodec: String?, currentResolution: CGSize?, currentBitrate: Int?) -> Bool {
        let codec = currentCodec?.lowercased() ?? ""

        if isVideo {
            // Skip if already H.264 at 720p or lower with reasonable bitrate
            if codec.contains("h.264") || codec.contains("avc") {
                if let resolution = currentResolution,
                   resolution.width <= CGFloat(TargetSpecs.videoWidth),
                   resolution.height <= CGFloat(TargetSpecs.videoHeight) {
                    if let bitrate = currentBitrate, bitrate <= TargetSpecs.videoBitrate * 2 {
                        return false
                    }
                }
            }
            return true
        } else {
            // Skip if already AAC with low bitrate
            if codec == "aac" || codec == "mp3" {
                if let bitrate = currentBitrate, bitrate <= TargetSpecs.audioBitrate * 2 {
                    return false
                }
            }
            return true
        }
    }

    // MARK: - Optimization (Transcoding)

    func optimizeMedia(
        items: [MediaAnalysisItem],
        options: OptimizationOptions,
        progressHandler: @escaping @Sendable (OptimizationProgress) async -> Void
    ) async throws -> OptimizationResult {
        isCancelled = false

        let itemsToOptimize = items.filter { $0.needsOptimization }
        guard !itemsToOptimize.isEmpty else {
            throw MediaOptimizationError.noItemsToOptimize
        }

        // Check disk space
        let requiredSpace = itemsToOptimize.reduce(0) { $0 + $1.originalSize }
        let availableSpace = try availableDiskSpace()
        if availableSpace < requiredSpace {
            throw MediaOptimizationError.insufficientDiskSpace(required: requiredSpace, available: availableSpace)
        }

        var itemResults: [OptimizedItemResult] = []
        var optimizedCount = 0
        var failedCount = 0
        var totalSaved: UInt64 = 0
        var originalsFolder: URL?

        // Create originals folder if not replacing
        if !options.replaceOriginals {
            originalsFolder = try createOriginalsFolder()
        }

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
                    originalsFolder: originalsFolder,
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
                NSLog(">>> MediaOptimizationService: Failed to optimize \(item.displayName): \(error)")
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
            originalsFolder: originalsFolder
        )
    }

    private func optimizeItem(
        _ item: MediaAnalysisItem,
        options: OptimizationOptions,
        originalsFolder: URL?,
        progressHandler: @escaping @Sendable (Double) async -> Void
    ) async throws -> OptimizedItemResult {
        // This will be implemented with actual transcoding
        // For now, return a placeholder that simulates the operation
        // TODO: Implement actual AVAssetWriter transcoding

        // Simulate progress for now
        for i in 0...10 {
            if isCancelled { throw MediaOptimizationError.cancelled }
            try await Task.sleep(nanoseconds: 100_000_000)  // 0.1s
            await progressHandler(Double(i) / 10.0)
        }

        // Return placeholder result
        // This will be replaced with real transcoding
        return OptimizedItemResult(
            mediaItemId: item.mediaItemId,
            displayName: item.displayName,
            originalSize: item.originalSize,
            optimizedSize: item.estimatedOptimizedSize,
            originalURL: URL(fileURLWithPath: "/placeholder/original"),
            optimizedURL: URL(fileURLWithPath: "/placeholder/optimized"),
            isVideo: item.isVideo,
            frameRate: item.currentFrameRate,
            sampleRate: item.currentSampleRate,
            success: true
        )
    }

    private func createOriginalsFolder() throws -> URL {
        // Create in temp for now - will be moved to project folder
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectorOriginals-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func availableDiskSpace() throws -> UInt64 {
        let fileURL = URL(fileURLWithPath: NSHomeDirectory())
        let values = try fileURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return UInt64(values.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    // MARK: - Cancellation

    func cancel() async {
        isCancelled = true
    }
}
