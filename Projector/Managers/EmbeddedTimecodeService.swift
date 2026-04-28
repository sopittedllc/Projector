//
//  EmbeddedTimecodeService.swift
//  Projector
//
//  Actor implementing EmbeddedTimecodeServiceProtocol.
//  Detects embedded timecode from QuickTime tracks, XMP metadata, and ProRes.
//
//  Layer: Managers
//  Contract: EmbeddedTimecodeServiceProtocol
//

import Foundation
import AVFoundation
import CoreMedia
import SwiftTimecodeAV
import SwiftTimecodeCore

/// Actor that detects embedded timecode from media files.
///
/// Checks multiple timecode sources in order of reliability:
/// 1. QuickTime timecode tracks (most reliable)
/// 2. XMP metadata
/// 3. ProRes format description extensions
///
/// ## Thread Safety
///
/// This is an actor, so all methods are isolated and thread-safe.
/// AVFoundation operations run off the main thread.
///
/// ## Usage
///
/// ```swift
/// let service = EmbeddedTimecodeService()
/// if let result = await service.detectTimecode(from: videoURL, bookmark: nil) {
///     print("Found timecode: \(result.formattedTimecode)")
/// }
/// ```
actor EmbeddedTimecodeService: EmbeddedTimecodeServiceProtocol {

    // MARK: - Public API

    /// Detect embedded timecode from a media file.
    ///
    /// - Parameters:
    ///   - url: File URL of the media to analyze
    ///   - bookmark: Optional security-scoped bookmark for sandbox access
    /// - Returns: Detected timecode result, or `nil` if no timecode found
    func detectTimecode(from url: URL, bookmark: Data?) async -> EmbeddedTimecodeResult? {
        debugPrint("EmbeddedTimecodeService: detectTimecode ENTRY - \(url.lastPathComponent)")

        // Resolve security-scoped access if bookmark provided
        var accessingURL = url
        var didStartAccess = false

        if let bookmark = bookmark {
            var isStale = false
            if let resolved = try? URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                accessingURL = resolved
                didStartAccess = accessingURL.startAccessingSecurityScopedResource()
            }
        }

        defer {
            if didStartAccess {
                accessingURL.stopAccessingSecurityScopedResource()
            }
        }

        let asset = AVURLAsset(url: accessingURL)

        // Try each source in order of reliability
        // 0. SwiftTimecodeAV library (most reliable - handles all QuickTime formats)
        debugPrint("EmbeddedTimecodeService: Trying SwiftTimecodeAV library...")
        if let result = await detectUsingSwiftTimecodeAV(asset: asset) {
            debugPrint("EmbeddedTimecodeService: Found timecode via SwiftTimecodeAV: \(result.formattedTimecode)")
            return result
        }

        // 1. QuickTime timecode track (fallback with detailed logging)
        debugPrint("EmbeddedTimecodeService: Checking QuickTime timecode track (fallback)...")
        if let result = await detectFromTimecodeTrack(asset: asset) {
            debugPrint("EmbeddedTimecodeService: Found timecode in QT track: \(result.formattedTimecode)")
            return result
        }

        // 2. QuickTime metadata (com.apple.quicktime.timecode.time)
        debugPrint("EmbeddedTimecodeService: Checking QuickTime metadata...")
        if let result = await detectFromQuickTimeMetadata(asset: asset) {
            debugPrint("EmbeddedTimecodeService: Found timecode in QT metadata: \(result.formattedTimecode)")
            return result
        }

        // 3. XMP metadata
        debugPrint("EmbeddedTimecodeService: Checking XMP metadata...")
        if let result = await detectFromXMPMetadata(asset: asset) {
            debugPrint("EmbeddedTimecodeService: Found timecode in XMP: \(result.formattedTimecode)")
            return result
        }

        // 4. ProRes metadata in video track
        debugPrint("EmbeddedTimecodeService: Checking ProRes metadata...")
        if let result = await detectFromProResMetadata(asset: asset) {
            debugPrint("EmbeddedTimecodeService: Found timecode in ProRes: \(result.formattedTimecode)")
            return result
        }

        // 5. BWF (Broadcast Wave Format) bext chunk for WAV files
        debugPrint("EmbeddedTimecodeService: Checking BWF bext chunk...")
        if let result = detectFromBWFBextChunk(url: accessingURL) {
            debugPrint("EmbeddedTimecodeService: Found timecode in BWF bext: \(result.formattedTimecode)")
            return result
        }

        debugPrint("EmbeddedTimecodeService: No embedded timecode found in \(url.lastPathComponent)")
        return nil
    }

    // MARK: - SwiftTimecodeAV Detection

    /// Detect timecode using the SwiftTimecodeAV library.
    ///
    /// This is the most reliable method as it handles all QuickTime timecode formats
    /// including edge cases with empty sample data.
    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    private func detectUsingSwiftTimecodeAV(asset: AVAsset) async -> EmbeddedTimecodeResult? {
        do {
            // Try to get start timecode using SwiftTimecodeAV's built-in method
            guard let startTimecode = try await asset.startTimecode() else {
                debugPrint("EmbeddedTimecodeService: SwiftTimecodeAV returned nil for startTimecode")
                return nil
            }

            debugPrint("EmbeddedTimecodeService: SwiftTimecodeAV found start timecode: \(startTimecode)")

            // Get the frame rate
            let frameRate = startTimecode.frameRate

            // Convert to our result format
            let formatted = startTimecode.stringValue(format: .default())
            let isDropFrame = frameRate.isDrop

            return EmbeddedTimecodeResult(
                timecodeFrames: startTimecode.frameCount.wholeFrames,
                formattedTimecode: formatted,
                source: .quickTimeTrack,
                frameRate: frameRate.fps,
                isDropFrame: isDropFrame
            )
        } catch {
            debugPrint("EmbeddedTimecodeService: SwiftTimecodeAV error: \(error)")
            return nil
        }
    }

    // MARK: - QuickTime Timecode Track Detection

    /// Detect timecode from QuickTime timecode track.
    ///
    /// QuickTime files can contain a dedicated timecode track that stores
    /// the starting timecode. This is the most reliable source.
    private func detectFromTimecodeTrack(asset: AVAsset) async -> EmbeddedTimecodeResult? {
        do {
            let timecodeTracks = try await asset.loadTracks(withMediaType: .timecode)
            debugPrint("EmbeddedTimecodeService: Found \(timecodeTracks.count) timecode track(s)")
            guard let track = timecodeTracks.first else {
                debugPrint("EmbeddedTimecodeService: No timecode track found")
                return nil
            }

            // Get format description for timecode parameters
            let formatDescriptions = try await track.load(.formatDescriptions)
            debugPrint("EmbeddedTimecodeService: Found \(formatDescriptions.count) format descriptions")
            guard let formatDesc = formatDescriptions.first else {
                debugPrint("EmbeddedTimecodeService: No format description found")
                return nil
            }

            // Extract timecode parameters from format description
            let frameQuanta = CMTimeCodeFormatDescriptionGetFrameQuanta(formatDesc)
            let tcFlags = CMTimeCodeFormatDescriptionGetTimeCodeFlags(formatDesc)
            let isDropFrame = (tcFlags & kCMTimeCodeFlag_DropFrame) != 0
            let mediaSubType = CMFormatDescriptionGetMediaSubType(formatDesc)
            let is64Bit = mediaSubType == kCMTimeCodeFormatType_TimeCode64
            debugPrint("EmbeddedTimecodeService: frameQuanta=\(frameQuanta), flags=\(tcFlags), dropFrame=\(isDropFrame), is64bit=\(is64Bit), subType=\(mediaSubType)")

            // Check for TimeCodeSourceReferenceName extension (reel name with timecode info)
            if let extensions = CMFormatDescriptionGetExtensions(formatDesc) as? [String: Any] {
                debugPrint("EmbeddedTimecodeService: Format description has \(extensions.count) extensions")

                // Look for source reference name which may contain timecode
                if let sourceRef = extensions["SourceReferenceName"] as? [String: Any] {
                    debugPrint("EmbeddedTimecodeService: SourceReferenceName = \(sourceRef)")
                }

                // Log all extension keys
                for key in extensions.keys.sorted() {
                    let val = extensions[key]
                    if key != "VerbatimSampleDescription" {
                        debugPrint("EmbeddedTimecodeService: Extension '\(key)' = \(val ?? "nil")")
                    }
                }
            }

            // Read the first timecode sample
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(output)

            guard reader.startReading() else {
                debugPrint("EmbeddedTimecodeService: Failed to start reading - status: \(reader.status.rawValue), error: \(reader.error?.localizedDescription ?? "nil")")
                return nil
            }
            debugPrint("EmbeddedTimecodeService: AVAssetReader started reading")

            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                debugPrint("EmbeddedTimecodeService: No sample buffer returned")
                return nil
            }
            debugPrint("EmbeddedTimecodeService: Got sample buffer")

            // Get sample size to know how much data we're dealing with
            let sampleSize = CMSampleBufferGetTotalSampleSize(sampleBuffer)
            debugPrint("EmbeddedTimecodeService: Sample size = \(sampleSize) bytes")

            // Try multiple approaches to get the timecode data
            var frameCount: UInt32 = 0
            var gotTimecode = false

            // Approach 1: Try CMSampleBufferGetDataBuffer with direct pointer access
            if let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
                debugPrint("EmbeddedTimecodeService: Got data buffer via GetDataBuffer")
                var length = 0
                var dataPointer: UnsafeMutablePointer<Int8>?
                let status = CMBlockBufferGetDataPointer(
                    dataBuffer,
                    atOffset: 0,
                    lengthAtOffsetOut: nil,
                    totalLengthOut: &length,
                    dataPointerOut: &dataPointer
                )
                if status == noErr, let ptr = dataPointer, length >= 4 {
                    frameCount = ptr.withMemoryRebound(to: UInt32.self, capacity: 1) { $0.pointee.bigEndian }
                    gotTimecode = true
                    debugPrint("EmbeddedTimecodeService: Got frame count via data pointer: \(frameCount)")
                }
            }

            // Approach 2: Try CMBlockBufferCopyDataBytes (works even if pointer access fails)
            if !gotTimecode, let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
                var bytes = [UInt8](repeating: 0, count: 4)
                let status = CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: 4, destination: &bytes)
                if status == noErr {
                    frameCount = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
                    gotTimecode = true
                    debugPrint("EmbeddedTimecodeService: Got frame count via CopyDataBytes: \(frameCount)")
                }
            }

            // Approach 3: Try reading directly into buffer if CMBlockBuffer methods fail
            if !gotTimecode, sampleSize >= 4 {
                debugPrint("EmbeddedTimecodeService: Trying direct sample data read approach")

                // Use CMSampleBufferGetDataBuffer with forced contiguous access
                if let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
                    // Try to make the block buffer contiguous
                    var contiguousBuffer: CMBlockBuffer?
                    let makeContiguous = CMBlockBufferCreateContiguous(
                        allocator: kCFAllocatorDefault,
                        sourceBuffer: dataBuffer,
                        blockAllocator: kCFAllocatorDefault,
                        customBlockSource: nil,
                        offsetToData: 0,
                        dataLength: sampleSize,
                        flags: 0,
                        blockBufferOut: &contiguousBuffer
                    )

                    if makeContiguous == noErr, let contiguous = contiguousBuffer {
                        var length = 0
                        var ptr: UnsafeMutablePointer<Int8>?
                        let status = CMBlockBufferGetDataPointer(
                            contiguous,
                            atOffset: 0,
                            lengthAtOffsetOut: nil,
                            totalLengthOut: &length,
                            dataPointerOut: &ptr
                        )
                        if status == noErr, let dataPtr = ptr, length >= 4 {
                            frameCount = dataPtr.withMemoryRebound(to: UInt32.self, capacity: 1) { $0.pointee.bigEndian }
                            gotTimecode = true
                            debugPrint("EmbeddedTimecodeService: Got frame count from contiguous buffer (approach 3): \(frameCount)")
                        }
                    }
                }
            }

            // Approach 4: Look for timecode in format description extensions (VerbatimSampleDescription)
            if !gotTimecode {
                debugPrint("EmbeddedTimecodeService: Checking format description extensions...")
                if let extensions = CMFormatDescriptionGetExtensions(formatDesc) as? [String: Any] {
                    debugPrint("EmbeddedTimecodeService: Format extensions: \(extensions.keys)")

                    // Check VerbatimSampleDescription - contains the raw tmcd atom data
                    if let verbatimData = extensions["VerbatimSampleDescription"] as? Data {
                        debugPrint("EmbeddedTimecodeService: VerbatimSampleDescription has \(verbatimData.count) bytes")

                        // Try to parse timecode from the sample description
                        // QuickTime timecode sample description format (after size+type):
                        // Bytes 0-3: size, 4-7: 'tmcd', 8-13: reserved, 14-15: data ref index
                        // 16-19: reserved, 20-23: flags, 24-27: time scale, 28-31: frame duration
                        // 32: number of frames, 33: reserved
                        // After this may come additional data including source reference name

                        if verbatimData.count >= 34 {
                            let bytes = [UInt8](verbatimData)

                            // Extract time scale (offset 24-27, big-endian)
                            let timeScale = UInt32(bytes[24]) << 24 | UInt32(bytes[25]) << 16 |
                                            UInt32(bytes[26]) << 8 | UInt32(bytes[27])

                            // Extract frame duration (offset 28-31, big-endian)
                            let frameDuration = UInt32(bytes[28]) << 24 | UInt32(bytes[29]) << 16 |
                                                UInt32(bytes[30]) << 8 | UInt32(bytes[31])

                            // Extract number of frames per second (offset 32)
                            let framesPerSecond = bytes[32]

                            debugPrint("EmbeddedTimecodeService: VerbatimSampleDescription - timeScale=\(timeScale), frameDuration=\(frameDuration), fps=\(framesPerSecond)")

                            // Some files store an initial frame count after the standard fields
                            // Check if there's extra data that could be the starting frame
                            if verbatimData.count >= 38 {
                                // Try reading bytes 34-37 as potential frame count
                                let potentialFrameCount = UInt32(bytes[34]) << 24 | UInt32(bytes[35]) << 16 |
                                                          UInt32(bytes[36]) << 8 | UInt32(bytes[37])
                                debugPrint("EmbeddedTimecodeService: Potential frame count at offset 34: \(potentialFrameCount)")

                                // Sanity check - frame count should be reasonable (less than 24 hours at given fps)
                                let maxReasonableFrames = UInt32(framesPerSecond) * 24 * 60 * 60
                                if potentialFrameCount > 0 && potentialFrameCount < maxReasonableFrames {
                                    frameCount = potentialFrameCount
                                    gotTimecode = true
                                    debugPrint("EmbeddedTimecodeService: Got frame count from VerbatimSampleDescription: \(frameCount)")
                                }
                            }
                        }
                    }

                    // Log other extensions for debugging
                    for (key, value) in extensions where key != "VerbatimSampleDescription" {
                        debugPrint("EmbeddedTimecodeService: Extension '\(key)' = \(value)")
                    }
                }
            }

            // Approach 5: Use sample timing info to compute timecode
            // For timecode tracks, the sample's DTS/PTS relative to the track's media time
            // combined with the format description's frame quanta gives us the timecode
            if !gotTimecode {
                debugPrint("EmbeddedTimecodeService: Trying sample timing approach...")

                // Get timing info for the sample
                var timingInfo = CMSampleTimingInfo()
                let timingStatus = CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &timingInfo)

                if timingStatus == noErr {
                    debugPrint("EmbeddedTimecodeService: Timing - PTS: \(timingInfo.presentationTimeStamp.seconds), DTS: \(timingInfo.decodeTimeStamp.seconds), Duration: \(timingInfo.duration.seconds)")

                    // The timecode track's sample timing should indicate the starting frame
                    // Some QuickTime files encode the frame number in the sample's media data
                    // but store it as timing relative to the track's timescale
                    let trackTimeScale = try await track.load(.naturalTimeScale)
                    debugPrint("EmbeddedTimecodeService: Track time scale: \(trackTimeScale)")

                    // If the timecode data is stored as the sample number in the track's time scale
                    // we can compute it from the sample's decode time
                    if timingInfo.decodeTimeStamp.isValid && timingInfo.decodeTimeStamp != CMTime.invalid {
                        let dtsSamples = Int64(CMTimeGetSeconds(timingInfo.decodeTimeStamp) * Double(frameQuanta))
                        if dtsSamples > 0 {
                            frameCount = UInt32(dtsSamples)
                            gotTimecode = true
                            debugPrint("EmbeddedTimecodeService: Got frame count from DTS: \(frameCount)")
                        }
                    }
                }
            }

            // Approach 6: Read the track's first sample time as the timecode origin
            if !gotTimecode {
                debugPrint("EmbeddedTimecodeService: Trying track sample time approach...")

                // In some QuickTime files, the timecode is stored as the track's
                // start time in the movie's time coordinate system
                let trackSegment = try await track.load(.segments)
                debugPrint("EmbeddedTimecodeService: Track has \(trackSegment.count) segments")

                for (idx, segment) in trackSegment.enumerated() {
                    let targetStart = segment.timeMapping.target.start
                    let targetDuration = segment.timeMapping.target.duration
                    let sourceStart = segment.timeMapping.source.start
                    let sourceDuration = segment.timeMapping.source.duration

                    debugPrint("EmbeddedTimecodeService: Segment[\(idx)] - target: \(targetStart.seconds)s-\(CMTimeAdd(targetStart, targetDuration).seconds)s, source: \(sourceStart.seconds)s-\(CMTimeAdd(sourceStart, sourceDuration).seconds)s")
                    debugPrint("EmbeddedTimecodeService: Segment[\(idx)] - target timescale: \(targetStart.timescale), source timescale: \(sourceStart.timescale)")

                    // The source start time represents the timecode origin
                    // The timescale should match the frame rate * some multiplier
                    if !gotTimecode && sourceStart.isValid && sourceStart.timescale > 0 {
                        // Convert source start to frames using the format's frame quanta
                        let sourceSeconds = CMTimeGetSeconds(sourceStart)
                        let sourceFrames = Int(sourceSeconds * Double(frameQuanta))

                        debugPrint("EmbeddedTimecodeService: Source start in frames (using frameQuanta \(frameQuanta)): \(sourceFrames)")

                        // Also try using the source timescale directly
                        // If timescale is (fps * 100), then value / 100 = frame number
                        let rawSourceValue = sourceStart.value
                        let rawTimescale = Int64(sourceStart.timescale)

                        debugPrint("EmbeddedTimecodeService: Source raw value: \(rawSourceValue), timescale: \(rawTimescale)")

                        // Check if timescale represents frames (e.g., 2400 = 24fps * 100)
                        let possibleFPS = rawTimescale / 100
                        if possibleFPS == Int64(frameQuanta) {
                            let derivedFrames = rawSourceValue / 100
                            debugPrint("EmbeddedTimecodeService: Derived frame count from timescale: \(derivedFrames)")
                            if derivedFrames > 0 {
                                frameCount = UInt32(derivedFrames)
                                gotTimecode = true
                            }
                        }

                        // If frame count still 0, try the direct seconds conversion
                        if !gotTimecode && sourceFrames > 0 {
                            frameCount = UInt32(sourceFrames)
                            gotTimecode = true
                            debugPrint("EmbeddedTimecodeService: Got frame count from segment source: \(frameCount)")
                        }
                    }
                }
            }

            // Approach 7: If sample has data, try direct byte access with different offsets
            if !gotTimecode && sampleSize >= 4 {
                debugPrint("EmbeddedTimecodeService: Trying raw sample data extraction...")

                // Create a mutable block buffer to copy data into
                var outputBlockBuffer: CMBlockBuffer?
                let createStatus = CMBlockBufferCreateEmpty(
                    allocator: kCFAllocatorDefault,
                    capacity: UInt32(sampleSize),
                    flags: 0,
                    blockBufferOut: &outputBlockBuffer
                )

                if createStatus == noErr, let sourceBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
                    // Make it contiguous
                    var contiguousBuffer: CMBlockBuffer?
                    CMBlockBufferCreateContiguous(
                        allocator: kCFAllocatorDefault,
                        sourceBuffer: sourceBuffer,
                        blockAllocator: kCFAllocatorDefault,
                        customBlockSource: nil,
                        offsetToData: 0,
                        dataLength: sampleSize,
                        flags: 0,
                        blockBufferOut: &contiguousBuffer
                    )

                    if let contiguous = contiguousBuffer {
                        var length = 0
                        var dataPointer: UnsafeMutablePointer<Int8>?
                        let ptrStatus = CMBlockBufferGetDataPointer(
                            contiguous,
                            atOffset: 0,
                            lengthAtOffsetOut: nil,
                            totalLengthOut: &length,
                            dataPointerOut: &dataPointer
                        )
                        if ptrStatus == noErr, let ptr = dataPointer, length >= 4 {
                            frameCount = ptr.withMemoryRebound(to: UInt32.self, capacity: 1) { $0.pointee.bigEndian }
                            gotTimecode = true
                            debugPrint("EmbeddedTimecodeService: Got frame count from contiguous buffer: \(frameCount)")
                        }
                    }
                }
            }

            // If we didn't get any timecode data, or the frame count is 0 with empty sample data,
            // return nil to let other detection methods try
            if !gotTimecode {
                debugPrint("EmbeddedTimecodeService: Failed to extract timecode value from sample buffer after all attempts")
                return nil
            }

            // If sample data was empty and frame count is 0, this is likely not a real timecode
            // Let other detection methods try to find the actual timecode
            if sampleSize == 0 && frameCount == 0 {
                debugPrint("EmbeddedTimecodeService: Sample data empty and frame count is 0 - continuing to check other sources")
                return nil
            }

            debugPrint("EmbeddedTimecodeService: Final frame count = \(frameCount)")

            let frameRate = Double(frameQuanta)
            let formatted = formatTimecode(
                frames: Int(frameCount),
                frameRate: frameRate,
                dropFrame: isDropFrame
            )
            debugPrint("EmbeddedTimecodeService: Formatted timecode = \(formatted) at \(frameRate) fps")

            return EmbeddedTimecodeResult(
                timecodeFrames: Int(frameCount),
                formattedTimecode: formatted,
                source: .quickTimeTrack,
                frameRate: frameRate,
                isDropFrame: isDropFrame
            )
        } catch {
            debugPrint("EmbeddedTimecodeService: Exception in detectFromTimecodeTrack: \(error)")
            return nil
        }
    }

    // MARK: - QuickTime Metadata Detection

    /// Detect timecode from QuickTime-specific metadata.
    ///
    /// QuickTime files can store timecode in metadata fields like
    /// `com.apple.quicktime.timecode.time` or as a formatted string.
    private func detectFromQuickTimeMetadata(asset: AVAsset) async -> EmbeddedTimecodeResult? {
        do {
            // Load all metadata
            let allMetadata = try await asset.load(.metadata)
            debugPrint("EmbeddedTimecodeService: QuickTime metadata has \(allMetadata.count) items")

            // Also try loading metadata from the timecode track format
            let timecodeTracks = try await asset.loadTracks(withMediaType: .timecode)
            var videoFrameRate: Double = 24.0

            // Get frame rate from video track for reference
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            if let videoTrack = videoTracks.first {
                let nominalRate = try await videoTrack.load(.nominalFrameRate)
                videoFrameRate = Double(nominalRate)
                debugPrint("EmbeddedTimecodeService: Video frame rate = \(videoFrameRate)")
            }

            // Look for QuickTime timecode metadata identifiers
            for item in allMetadata {
                let identifier = item.identifier?.rawValue ?? ""
                let key = item.key as? String ?? item.commonKey?.rawValue ?? ""

                // Try to load value as string first
                if let stringValue = try? await item.load(.stringValue) {
                    debugPrint("EmbeddedTimecodeService: QT metadata '\(identifier)' / '\(key)' = '\(stringValue)'")

                    // Check if this looks like a timecode string
                    if let result = parseTimecodeString(stringValue, source: .xmpMetadata) {
                        debugPrint("EmbeddedTimecodeService: Parsed timecode from metadata: \(result.formattedTimecode)")
                        return result
                    }
                }

                // Try as data value
                if let dataValue = try? await item.load(.dataValue) {
                    debugPrint("EmbeddedTimecodeService: QT metadata '\(identifier)' / '\(key)' has \(dataValue.count) bytes of data")

                    // Check if this is a 4-byte frame count
                    if dataValue.count == 4 {
                        let frameCount = dataValue.withUnsafeBytes { ptr -> UInt32 in
                            ptr.load(as: UInt32.self).bigEndian
                        }
                        // Sanity check - should be less than 24 hours of frames
                        let maxFrames = UInt32(videoFrameRate * 24 * 60 * 60)
                        if frameCount > 0 && frameCount < maxFrames {
                            let formatted = formatTimecode(frames: Int(frameCount), frameRate: videoFrameRate, dropFrame: false)
                            debugPrint("EmbeddedTimecodeService: Found frame count in metadata: \(frameCount) -> \(formatted)")
                            return EmbeddedTimecodeResult(
                                timecodeFrames: Int(frameCount),
                                formattedTimecode: formatted,
                                source: .xmpMetadata,
                                frameRate: videoFrameRate,
                                isDropFrame: false
                            )
                        }
                    }

                    // Check if it might be a timecode string as data
                    if let string = String(data: dataValue, encoding: .utf8),
                       let result = parseTimecodeString(string, source: .xmpMetadata) {
                        return result
                    }
                }
            }

            // If we have a timecode track, try to get the timecode from track references
            if let timecodeTrack = timecodeTracks.first {
                // Try reading the track's user data or sample description extensions
                let formatDescriptions = try await timecodeTrack.load(.formatDescriptions)
                if let formatDesc = formatDescriptions.first {
                    // The timecode might be stored in the format description's extensions
                    // under different keys depending on the authoring tool
                    if let extensions = CMFormatDescriptionGetExtensions(formatDesc) as? [String: Any] {
                        for (key, value) in extensions {
                            debugPrint("EmbeddedTimecodeService: Timecode track extension '\(key)' = \(value)")
                        }
                    }
                }
            }

            return nil
        } catch {
            debugPrint("EmbeddedTimecodeService: QuickTime metadata error: \(error)")
            return nil
        }
    }

    // MARK: - XMP Metadata Detection

    /// Detect timecode from XMP or common metadata.
    ///
    /// Professional tools often embed timecode in XMP metadata fields.
    private func detectFromXMPMetadata(asset: AVAsset) async -> EmbeddedTimecodeResult? {
        do {
            let metadata = try await asset.load(.metadata)
            debugPrint("EmbeddedTimecodeService: Found \(metadata.count) metadata items")

            // Log all metadata keys for debugging
            for item in metadata {
                let key = item.commonKey?.rawValue ?? item.key as? String ?? "unknown"
                let value = try? await item.load(.stringValue)
                debugPrint("EmbeddedTimecodeService: Metadata key='\(key)' value='\(value ?? "nil")'")
            }

            // Look for timecode-related metadata keys
            for item in metadata {
                guard let key = item.commonKey?.rawValue ?? item.key as? String else { continue }
                let keyLower = key.lowercased()

                // Check for timecode-related keys
                if keyLower.contains("timecode") ||
                   keyLower.contains("starttime") ||
                   keyLower.contains("start_timecode") {
                    if let value = try await item.load(.stringValue),
                       let result = parseTimecodeString(value, source: .xmpMetadata) {
                        debugPrint("EmbeddedTimecodeService: Found timecode in metadata key '\(key)'")
                        return result
                    }
                }
            }

            // Also check format-specific metadata
            let formatMetadata = try await asset.load(.commonMetadata)
            debugPrint("EmbeddedTimecodeService: Found \(formatMetadata.count) common metadata items")
            for item in formatMetadata {
                guard let key = item.commonKey?.rawValue ?? item.key as? String else { continue }
                let keyLower = key.lowercased()

                if keyLower.contains("timecode") || keyLower.contains("starttime") {
                    if let value = try await item.load(.stringValue),
                       let result = parseTimecodeString(value, source: .xmpMetadata) {
                        return result
                    }
                }
            }

            debugPrint("EmbeddedTimecodeService: No timecode found in metadata")
            return nil
        } catch {
            debugPrint("EmbeddedTimecodeService: XMP metadata error: \(error)")
            return nil
        }
    }

    // MARK: - ProRes Metadata Detection

    /// Detect timecode from ProRes format description extensions.
    ///
    /// ProRes files can have timecode embedded in the video track's
    /// format description extensions (tmcd atom).
    private func detectFromProResMetadata(asset: AVAsset) async -> EmbeddedTimecodeResult? {
        do {
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = videoTracks.first else { return nil }

            let formatDescriptions = try await track.load(.formatDescriptions)
            guard let formatDesc = formatDescriptions.first else { return nil }

            // Check for timecode extension in format description
            guard let extensions = CMFormatDescriptionGetExtensions(formatDesc) as? [String: Any] else {
                return nil
            }

            // Look for tmcd (timecode) atom in sample description extensions
            if let sampleExtensions = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any],
               let timecodeData = sampleExtensions["tmcd"] as? Data {
                return parseTimecodeAtom(timecodeData)
            }

            return nil
        } catch {
            return nil
        }
    }

    // MARK: - Safe Byte Reading Helpers

    /// Safely read a UInt32 from Data at a given offset (little-endian).
    /// Avoids misaligned memory access crashes.
    private func readUInt32LE(from data: Data, at offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        let bytes = [data[offset], data[offset + 1], data[offset + 2], data[offset + 3]]
        return UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
    }

    /// Safely read a UInt64 from Data at a given offset (little-endian).
    /// Avoids misaligned memory access crashes.
    private func readUInt64LE(from data: Data, at offset: Int) -> UInt64 {
        guard offset + 8 <= data.count else { return 0 }
        var result: UInt64 = 0
        for i in 0..<8 {
            result |= UInt64(data[offset + i]) << (i * 8)
        }
        return result
    }

    // MARK: - BWF (Broadcast Wave Format) Detection

    /// Detect timecode from BWF bext chunk in WAV files.
    ///
    /// BWF files contain a "bext" chunk with broadcast audio extension data,
    /// including TimeReference (64-bit sample count since midnight) and
    /// OriginationTime (HH:MM:SS text string).
    private func detectFromBWFBextChunk(url: URL) -> EmbeddedTimecodeResult? {
        // Only check WAV files
        let ext = url.pathExtension.lowercased()
        guard ext == "wav" || ext == "wave" || ext == "bwf" else {
            debugPrint("EmbeddedTimecodeService: Not a WAV file, skipping BWF check")
            return nil
        }

        guard let fileHandle = try? FileHandle(forReadingFrom: url) else {
            debugPrint("EmbeddedTimecodeService: Failed to open file for BWF check")
            return nil
        }
        defer { try? fileHandle.close() }

        // Read RIFF header
        guard let riffHeader = try? fileHandle.read(upToCount: 12),
              riffHeader.count == 12 else {
            debugPrint("EmbeddedTimecodeService: Failed to read RIFF header")
            return nil
        }

        let riffMarker = String(data: riffHeader[0..<4], encoding: .ascii)
        let waveMarker = String(data: riffHeader[8..<12], encoding: .ascii)

        guard riffMarker == "RIFF" && waveMarker == "WAVE" else {
            debugPrint("EmbeddedTimecodeService: Not a valid RIFF/WAVE file")
            return nil
        }

        // Search for bext chunk
        var bextData: Data?
        var sampleRate: UInt32 = 48000  // Default

        while let chunkHeader = try? fileHandle.read(upToCount: 8), chunkHeader.count == 8 {
            let chunkId = String(data: chunkHeader[0..<4], encoding: .ascii)
            // Safe unaligned read for chunk size
            let chunkSize = readUInt32LE(from: chunkHeader, at: 4)

            debugPrint("EmbeddedTimecodeService: Found chunk '\(chunkId ?? "nil")' size \(chunkSize)")

            if chunkId == "bext" {
                // Found bext chunk
                bextData = try? fileHandle.read(upToCount: Int(chunkSize))
                debugPrint("EmbeddedTimecodeService: Found bext chunk with \(bextData?.count ?? 0) bytes")
            } else if chunkId == "fmt " {
                // Get sample rate from fmt chunk
                if let fmtData = try? fileHandle.read(upToCount: Int(chunkSize)), fmtData.count >= 8 {
                    sampleRate = readUInt32LE(from: fmtData, at: 4)
                    debugPrint("EmbeddedTimecodeService: Sample rate from fmt chunk: \(sampleRate)")
                }
            } else {
                // Skip this chunk
                try? fileHandle.seek(toOffset: fileHandle.offsetInFile + UInt64(chunkSize))
            }

            // Handle odd chunk sizes (RIFF chunks are word-aligned)
            if chunkSize % 2 != 0 {
                try? fileHandle.seek(toOffset: fileHandle.offsetInFile + 1)
            }

            // If we found bext, we can stop searching
            if bextData != nil && sampleRate != 48000 {
                break
            }
        }

        guard let bext = bextData, bext.count >= 346 else {
            debugPrint("EmbeddedTimecodeService: No valid bext chunk found (need at least 346 bytes)")
            return nil
        }

        // BWF bext chunk structure:
        // Offset 0-255: Description (256 bytes)
        // Offset 256-287: Originator (32 bytes)
        // Offset 288-319: OriginatorReference (32 bytes)
        // Offset 320-329: OriginationDate (10 bytes) "YYYY-MM-DD"
        // Offset 330-337: OriginationTime (8 bytes) "HH:MM:SS"
        // Offset 338-345: TimeReference (8 bytes) - 64-bit sample count since midnight

        // Try to parse TimeReference (primary timecode source) - safe unaligned read
        let timeReference = readUInt64LE(from: bext, at: 338)
        debugPrint("EmbeddedTimecodeService: BWF TimeReference = \(timeReference) samples")

        if timeReference > 0 {
            // Convert samples to timecode
            // TimeReference is sample count since midnight
            let secondsSinceMidnight = Double(timeReference) / Double(sampleRate)

            // Assume 24fps for timecode display (common for audio production)
            // TODO: Could check for video track to get actual frame rate
            let frameRate: Double = 24.0
            let totalFrames = Int(secondsSinceMidnight * frameRate)

            let formatted = formatTimecode(frames: totalFrames, frameRate: frameRate, dropFrame: false)
            debugPrint("EmbeddedTimecodeService: BWF timecode = \(formatted) (\(totalFrames) frames at \(frameRate) fps)")

            return EmbeddedTimecodeResult(
                timecodeFrames: totalFrames,
                formattedTimecode: formatted,
                source: .xmpMetadata,  // Using xmpMetadata as closest source type
                frameRate: frameRate,
                isDropFrame: false
            )
        }

        // Fallback: Try to parse OriginationTime text
        if let originationTime = String(data: bext[330..<338], encoding: .ascii),
           originationTime.count == 8 {
            debugPrint("EmbeddedTimecodeService: BWF OriginationTime = '\(originationTime)'")

            // Parse HH:MM:SS format
            if let result = parseTimecodeString(originationTime + ":00", source: .xmpMetadata) {
                return result
            }
        }

        return nil
    }

    // MARK: - Timecode Parsing Helpers

    /// Format a frame count as timecode string.
    ///
    /// - Parameters:
    ///   - frames: Total frame count
    ///   - frameRate: Frame rate (e.g., 24, 29.97, 30)
    ///   - dropFrame: Whether to use drop-frame notation (semicolon separator)
    /// - Returns: Formatted timecode string (HH:MM:SS:FF or HH:MM:SS;FF)
    private func formatTimecode(frames: Int, frameRate: Double, dropFrame: Bool) -> String {
        let fps = Int(round(frameRate))
        let separator = dropFrame ? ";" : ":"

        var remainingFrames = frames

        // Handle drop-frame calculation for 29.97/59.94
        if dropFrame && (fps == 30 || fps == 60) {
            // Drop-frame timecode drops frame numbers 0 and 1 at the start of each minute,
            // except every 10th minute
            let dropFrames = fps == 30 ? 2 : 4
            let framesPerMinute = fps * 60 - dropFrames
            let framesPer10Minutes = framesPerMinute * 10 + dropFrames

            let tenMinuteChunks = remainingFrames / framesPer10Minutes
            remainingFrames = remainingFrames % framesPer10Minutes

            var additionalMinutes = 0
            if remainingFrames >= dropFrames {
                additionalMinutes = (remainingFrames - dropFrames) / framesPerMinute + 1
                if additionalMinutes > 9 {
                    additionalMinutes = 9
                }
                remainingFrames = remainingFrames - dropFrames - (additionalMinutes - 1) * framesPerMinute
                if remainingFrames < 0 {
                    remainingFrames += framesPerMinute
                    additionalMinutes -= 1
                }
            }

            let totalMinutes = tenMinuteChunks * 10 + additionalMinutes
            let hh = totalMinutes / 60
            let mm = totalMinutes % 60
            let ss = remainingFrames / fps
            let ff = remainingFrames % fps

            return String(format: "%02d:%02d:%02d%@%02d", hh, mm, ss, separator, ff)
        } else {
            // Non-drop-frame calculation
            let ff = remainingFrames % fps
            let totalSeconds = remainingFrames / fps
            let ss = totalSeconds % 60
            let totalMinutes = totalSeconds / 60
            let mm = totalMinutes % 60
            let hh = totalMinutes / 60

            return String(format: "%02d:%02d:%02d%@%02d", hh, mm, ss, separator, ff)
        }
    }

    /// Parse a timecode string into a result.
    ///
    /// Supports formats: HH:MM:SS:FF, HH:MM:SS;FF, HH:MM:SS.FF
    ///
    /// - Parameters:
    ///   - value: Timecode string to parse
    ///   - source: Source type for the result
    /// - Returns: Parsed result, or nil if parsing fails
    private func parseTimecodeString(_ value: String, source: TimecodeSource) -> EmbeddedTimecodeResult? {
        // Match HH:MM:SS:FF or HH:MM:SS;FF or HH:MM:SS.FF
        let pattern = #"(\d{1,2}):(\d{2}):(\d{2})[:;.](\d{2})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else {
            return nil
        }

        guard let hhRange = Range(match.range(at: 1), in: value),
              let mmRange = Range(match.range(at: 2), in: value),
              let ssRange = Range(match.range(at: 3), in: value),
              let ffRange = Range(match.range(at: 4), in: value),
              let hh = Int(value[hhRange]),
              let mm = Int(value[mmRange]),
              let ss = Int(value[ssRange]),
              let ff = Int(value[ffRange]) else {
            return nil
        }

        // Detect drop-frame from separator
        let isDropFrame = value.contains(";")

        // Infer frame rate from frame number (common rates: 24, 25, 30)
        // If ff >= 25, assume 30fps; if ff >= 24, could be 25 or 30; otherwise 24
        let frameRate: Double
        if ff >= 30 {
            frameRate = 60.0
        } else if ff >= 25 {
            frameRate = 30.0
        } else if ff >= 24 {
            frameRate = 25.0
        } else {
            frameRate = 24.0
        }

        let fps = Int(frameRate)
        let totalFrames = (hh * 3600 + mm * 60 + ss) * fps + ff

        return EmbeddedTimecodeResult(
            timecodeFrames: totalFrames,
            formattedTimecode: value,
            source: source,
            frameRate: frameRate,
            isDropFrame: isDropFrame
        )
    }

    /// Parse timecode from a tmcd atom data blob.
    ///
    /// - Parameter data: Raw tmcd atom data
    /// - Returns: Parsed result, or nil if parsing fails
    private func parseTimecodeAtom(_ data: Data) -> EmbeddedTimecodeResult? {
        // tmcd atom structure varies, but typically contains frame count
        guard data.count >= 4 else { return nil }

        let frameCount = data.withUnsafeBytes { ptr -> UInt32 in
            ptr.load(as: UInt32.self).bigEndian
        }

        // Default to 24fps if not determinable from atom
        let frameRate: Double = 24.0
        let formatted = formatTimecode(frames: Int(frameCount), frameRate: frameRate, dropFrame: false)

        return EmbeddedTimecodeResult(
            timecodeFrames: Int(frameCount),
            formattedTimecode: formatted,
            source: .proResMetadata,
            frameRate: frameRate,
            isDropFrame: false
        )
    }
}
