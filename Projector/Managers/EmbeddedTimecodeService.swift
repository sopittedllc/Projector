//
//  EmbeddedTimecodeService.swift
//  Projector
//
//  Actor implementing EmbeddedTimecodeServiceProtocol.
//  Detects embedded timecode from QuickTime tracks, XMP metadata, and ProRes.
//
//  Owned by: backend-logic
//  Contract: EmbeddedTimecodeServiceProtocol
//

import Foundation
import AVFoundation
import CoreMedia

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
        // 1. QuickTime timecode track (most reliable)
        debugPrint("EmbeddedTimecodeService: Checking QuickTime timecode track...")
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

        debugPrint("EmbeddedTimecodeService: No embedded timecode found in \(url.lastPathComponent)")
        return nil
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
            debugPrint("EmbeddedTimecodeService: frameQuanta=\(frameQuanta), flags=\(tcFlags), dropFrame=\(isDropFrame)")

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
                if let firstSegment = trackSegment.first {
                    let startTime = firstSegment.timeMapping.target.start
                    let mediaStartTime = firstSegment.timeMapping.source.start

                    debugPrint("EmbeddedTimecodeService: Track segment - target start: \(startTime.seconds)s, media start: \(mediaStartTime.seconds)s")

                    // The media start time in frames is often the timecode
                    if mediaStartTime.isValid && mediaStartTime.timescale > 0 {
                        let mediaFrames = Int(CMTimeGetSeconds(mediaStartTime) * Double(frameQuanta))
                        if mediaFrames >= 0 {
                            frameCount = UInt32(mediaFrames)
                            gotTimecode = true
                            debugPrint("EmbeddedTimecodeService: Got frame count from media start time: \(frameCount)")
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

            guard gotTimecode else {
                debugPrint("EmbeddedTimecodeService: Failed to extract timecode value from sample buffer after all attempts")
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
