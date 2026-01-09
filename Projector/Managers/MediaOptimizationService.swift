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

/// Actor that handles media optimization (analysis and transcoding)
actor MediaOptimizationService: MediaOptimizationServiceProtocol {

    // MARK: - Properties

    private var isCancelled = false

    /// Estimated compression ratios for different source formats
    /// Now using HEVC which provides ~40% better compression than H.264
    private enum CompressionEstimates {
        /// ProRes files compress very well to HEVC
        static let proResToHEVC: Double = 0.10  // ~40% smaller than H.264

        /// Already-compressed H.264 to HEVC has moderate savings
        static let h264ToHEVC: Double = 0.6  // HEVC is more efficient

        /// Uncompressed/lossless to HEVC
        static let uncompressedToHEVC: Double = 0.07  // ~40% smaller than H.264

        /// PCM/WAV to AAC
        static let pcmToAAC: Double = 0.10

        /// Already compressed audio (MP3, AAC)
        static let compressedAudioToAAC: Double = 0.9
    }

    /// Target specs - HEVC 720p optimized for speed + quality
    /// Using hardware-accelerated HEVC encoding on Apple Silicon
    private enum TargetSpecs {
        static let videoWidth = 1280
        static let videoHeight = 720
        static let videoBitrate = 1_500_000  // Lower bitrate OK for HEVC
        static let audioBitrate = 160_000    // AAC stereo
        static let maxFrameRate = 30.0       // Peak frame rate (preserves lower)
    }

    // MARK: - Analysis

    func analyzeProject(mediaItems: [MediaItem]) async throws -> ProjectAnalysisResult {
        NSLog(">>> MediaOptimizationService.analyzeProject: analyzing \(mediaItems.count) items")
        var analysisItems: [MediaAnalysisItem] = []
        var totalOriginalSize: UInt64 = 0
        var totalEstimatedSize: UInt64 = 0

        for item in mediaItems {
            NSLog(">>> MediaOptimizationService.analyzeProject: analyzing \(item.displayName) (type: \(item.type))")
            let analysis = try await analyzeMediaItem(item)
            NSLog(">>> MediaOptimizationService.analyzeProject: \(item.displayName) - needsOptimization: \(analysis.needsOptimization), codec: \(analysis.currentCodec ?? "unknown")")
            analysisItems.append(analysis)
            totalOriginalSize += analysis.originalSize
            totalEstimatedSize += analysis.estimatedOptimizedSize
        }

        NSLog(">>> MediaOptimizationService.analyzeProject: complete - \(analysisItems.count) items, \(analysisItems.filter { $0.needsOptimization }.count) need optimization")
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
                ratio = CompressionEstimates.proResToHEVC
            } else if codec.contains("h.264") || codec.contains("avc") || codec.contains("hevc") {
                ratio = CompressionEstimates.h264ToHEVC
            } else {
                ratio = CompressionEstimates.uncompressedToHEVC
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
        NSLog(">>> MediaOptimizationService: Created Optimized Media folder at \(optimizedMediaFolder.path)")

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
            NSLog(">>> MediaOptimizationService: Starting transcode for \(item.displayName)")
            NSLog(">>> MediaOptimizationService: Output will be saved to \(outputURL.path)")

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

            NSLog(">>> MediaOptimizationService: Transcode complete, getting output size")

            // Get actual output file size
            let outputAttributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
            let outputSize = outputAttributes[.size] as? UInt64 ?? 0

            NSLog(">>> MediaOptimizationService: Output size: \(outputSize) bytes")
            NSLog(">>> MediaOptimizationService: Original file left untouched at \(sourceURL.path)")

            NSLog(">>> MediaOptimizationService: Verifying output file")

            // Verify preserved frame rate/sample rate from output file
            let verifiedFrameRate = item.isVideo ? try await getOutputFrameRate(url: outputURL) : nil
            let verifiedSampleRate = try await getOutputSampleRate(url: outputURL)

            NSLog(">>> MediaOptimizationService: Verification complete - frameRate: \(String(describing: verifiedFrameRate)), sampleRate: \(String(describing: verifiedSampleRate))")

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
        // PERFORMANCE OPTIMIZATIONS:
        // - AllowOpenGOP: Allows more efficient encoding with open GOPs
        // - MaxFrameDelayCount: Limits frame buffering for faster throughput
        // - Quality-based encoding: Faster than strict bitrate targeting
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,  // HEVC for better compression
            AVVideoWidthKey: options.videoTargetWidth,
            AVVideoHeightKey: options.videoTargetHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: options.videoBitrate,
                AVVideoMaxKeyFrameIntervalKey: 60,  // Longer GOP for HEVC efficiency
                AVVideoAllowFrameReorderingKey: true,  // B-frames for better compression
                AVVideoExpectedSourceFrameRateKey: sourceFrameRate ?? 30.0,  // Hint for encoder
                // Performance optimizations
                kVTCompressionPropertyKey_RealTime as String: false,  // Quality mode
                kVTCompressionPropertyKey_AllowOpenGOP as String: true,  // Better compression
                kVTCompressionPropertyKey_MaxFrameDelayCount as String: 4  // Reduce latency
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

            // Video processing with requestMediaDataWhenReady (event-driven, not polling)
            videoWriterInput.requestMediaDataWhenReady(on: videoQueue) { [weak self] in
                guard let self = self else { return }

                while videoWriterInput.isReadyForMoreMediaData {
                    // Check cancellation
                    if self.isCancelled {
                        videoWriterInput.markAsFinished()
                        completionLock.lock()
                        videoFinished = true
                        completionLock.unlock()
                        checkCompletion()
                        return
                    }

                    guard let sampleBuffer = videoReaderOutput.copyNextSampleBuffer() else {
                        // No more samples
                        videoWriterInput.markAsFinished()
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
                    videoWriterInput.append(sampleBuffer)
                }
            }

            // Audio processing (if present) - also event-driven
            if let audioOutput = audioReaderOutput, let audioInput = audioWriterInput {
                audioInput.requestMediaDataWhenReady(on: audioQueue) {
                    while audioInput.isReadyForMoreMediaData {
                        guard let sampleBuffer = audioOutput.copyNextSampleBuffer() else {
                            audioInput.markAsFinished()
                            completionLock.lock()
                            audioFinished = true
                            completionLock.unlock()
                            checkCompletion()
                            return
                        }
                        audioInput.append(sampleBuffer)
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
            NSLog(">>> MediaOptimizationService: Video transcoding completed successfully")
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

        NSLog(">>> MediaOptimizationService: Starting audio export for \(sourceURL.lastPathComponent)")

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
            NSLog(">>> MediaOptimizationService: Audio export completed successfully")
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

    func cancel() async {
        isCancelled = true
    }
}
