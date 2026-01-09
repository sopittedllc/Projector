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

    /// Target specs matching HandBrake "Very Fast 720p30" preset
    /// Source: github.com/HandBrake/HandBrake/preset/preset_builtin.json
    private enum TargetSpecs {
        static let videoWidth = 1280
        static let videoHeight = 720
        static let videoBitrate = 2_000_000  // HandBrake VideoAvgBitrate: 2000 (kbps -> bps)
        static let audioBitrate = 160_000    // HandBrake AudioBitrate: 160 (kbps -> bps)
        static let maxFrameRate = 30.0       // HandBrake VideoFramerate: "30" with pfr mode
        // HandBrake settings: VideoProfile: "main", VideoLevel: "3.1"
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
            sourceURL: item.url,
            sourceBookmark: item.bookmark,
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

        // Also start access to the parent directory for writing
        let parentDir = sourceURL.deletingLastPathComponent()
        let didStartParentAccess = parentDir.startAccessingSecurityScopedResource()

        defer {
            if didStartAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
            if didStartParentAccess {
                parentDir.stopAccessingSecurityScopedResource()
            }
        }

        // Create output URL (same directory, new extension) - use security-scoped sourceURL
        let outputExtension = item.isVideo ? "mp4" : "m4a"
        let outputName = sourceURL.deletingPathExtension().lastPathComponent + "_optimized"
        let outputURL = sourceURL.deletingLastPathComponent()
            .appendingPathComponent(outputName)
            .appendingPathExtension(outputExtension)

        do {
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

            // Get actual output file size
            let outputAttributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
            let outputSize = outputAttributes[.size] as? UInt64 ?? 0

            // Handle originals - use security-scoped sourceURL
            if let originalsFolder = originalsFolder {
                // Move original to originals folder
                let originalDest = originalsFolder.appendingPathComponent(sourceURL.lastPathComponent)
                try FileManager.default.moveItem(at: sourceURL, to: originalDest)
            } else {
                // Move original to trash
                try FileManager.default.trashItem(at: sourceURL, resultingItemURL: nil)
            }

            // Rename optimized file to original name (keep same base name, new extension)
            let finalURL = sourceURL.deletingPathExtension().appendingPathExtension(outputExtension)
            if finalURL != outputURL {
                // If the original had a different extension, rename
                if FileManager.default.fileExists(atPath: finalURL.path) {
                    try FileManager.default.removeItem(at: finalURL)
                }
                try FileManager.default.moveItem(at: outputURL, to: finalURL)
            }

            // Verify preserved frame rate/sample rate from output file
            let verifiedFrameRate = item.isVideo ? try await getOutputFrameRate(url: finalURL) : nil
            let verifiedSampleRate = try await getOutputSampleRate(url: finalURL)

            return OptimizedItemResult(
                mediaItemId: item.mediaItemId,
                displayName: item.displayName,
                originalSize: item.originalSize,
                optimizedSize: outputSize,
                originalURL: item.sourceURL,
                optimizedURL: finalURL,
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

        // Video writer input with H.264 encoding
        // Settings match HandBrake "Very Fast 720p30" preset:
        // - Profile: Main (VideoProfile: "main")
        // - Level: 3.1 (VideoLevel: "3.1")
        // - Bitrate: ~2 Mbps (VideoAvgBitrate: 2000)
        // CRITICAL: Frame rate is preserved via sample buffer timestamps
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: options.videoTargetWidth,
            AVVideoHeightKey: options.videoTargetHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: options.videoBitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264Main31,  // HandBrake: Main 3.1
                AVVideoMaxKeyFrameIntervalKey: 30,
                AVVideoAllowFrameReorderingKey: true  // B-frames for better compression
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

        // Process video and audio on background threads
        // Use a concurrent queue with dispatch group to track completion
        let processingQueue = DispatchQueue(label: "com.projector.transcoding", attributes: .concurrent)
        let dispatchGroup = DispatchGroup()

        // Capture progress for async reporting
        var lastReportedProgress: Double = 0

        // Video processing
        dispatchGroup.enter()
        processingQueue.async {
            self.processTrackSync(
                readerOutput: videoReaderOutput,
                writerInput: videoWriterInput,
                totalSeconds: totalSeconds,
                progressCallback: { progress in
                    // Only report if progress increased significantly
                    if progress - lastReportedProgress >= 0.01 {
                        lastReportedProgress = progress
                        Task {
                            await progressHandler(progress)
                        }
                    }
                }
            )
            dispatchGroup.leave()
        }

        // Audio processing (if present)
        if let audioOutput = audioReaderOutput, let audioInput = audioWriterInput {
            dispatchGroup.enter()
            processingQueue.async {
                self.processTrackSync(
                    readerOutput: audioOutput,
                    writerInput: audioInput,
                    totalSeconds: totalSeconds,
                    progressCallback: { _ in }  // Don't report audio progress separately
                )
                dispatchGroup.leave()
            }
        }

        // Wait for all processing to complete
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            dispatchGroup.notify(queue: .main) {
                continuation.resume()
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

        if writer.status == .failed {
            throw MediaOptimizationError.transcodingFailed(
                sourceURL,
                writer.error?.localizedDescription ?? "Unknown error"
            )
        }
    }

    private nonisolated func processTrackSync(
        readerOutput: AVAssetReaderTrackOutput,
        writerInput: AVAssetWriterInput,
        totalSeconds: Double,
        progressCallback: @escaping (Double) -> Void
    ) {
        // Pull-based synchronous processing (runs on background thread)
        while !writerInput.isReadyForMoreMediaData {
            Thread.sleep(forTimeInterval: 0.001)
        }

        while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
            while !writerInput.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.001)
            }

            // Calculate progress from presentation time
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let currentSeconds = pts.seconds
            let progress = min(currentSeconds / totalSeconds, 1.0)
            progressCallback(progress)

            writerInput.append(sampleBuffer)
        }

        writerInput.markAsFinished()
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

        // Start export
        await exportSession.export()

        // Monitor progress
        while exportSession.status == .exporting {
            await progressHandler(Double(exportSession.progress))
            try await Task.sleep(nanoseconds: 100_000_000)  // Check every 0.1s

            if isCancelled {
                exportSession.cancelExport()
                throw MediaOptimizationError.cancelled
            }
        }

        if exportSession.status == .failed {
            throw MediaOptimizationError.transcodingFailed(
                sourceURL,
                exportSession.error?.localizedDescription ?? "Unknown error"
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
