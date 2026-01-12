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

        // 2. XMP metadata
        debugPrint("EmbeddedTimecodeService: Checking XMP metadata...")
        if let result = await detectFromXMPMetadata(asset: asset) {
            debugPrint("EmbeddedTimecodeService: Found timecode in XMP: \(result.formattedTimecode)")
            return result
        }

        // 3. ProRes metadata in video track
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

            guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                debugPrint("EmbeddedTimecodeService: No data buffer in sample")
                return nil
            }
            debugPrint("EmbeddedTimecodeService: Got data buffer")

            // Parse timecode value from data buffer
            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(
                dataBuffer,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &length,
                dataPointerOut: &dataPointer
            )
            debugPrint("EmbeddedTimecodeService: CMBlockBufferGetDataPointer status=\(status), length=\(length)")

            guard status == noErr, let ptr = dataPointer, length >= 4 else {
                debugPrint("EmbeddedTimecodeService: Failed to get data pointer or insufficient length")
                return nil
            }

            // Timecode is stored as big-endian 32-bit frame count
            let frameCount = ptr.withMemoryRebound(to: UInt32.self, capacity: 1) { pointer in
                UInt32(bigEndian: pointer.pointee)
            }
            debugPrint("EmbeddedTimecodeService: Raw frame count = \(frameCount)")

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
