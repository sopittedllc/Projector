import Foundation
import AVFoundation
import Vision
import CoreImage

// MARK: - TimecodeOCRManager

/// Manages detection of burned-in timecode from video frames using OCR.
///
/// `TimecodeOCRManager` uses the Vision framework to detect timecode text that is
/// "burned in" (visually rendered) to video frames. This is useful for detecting
/// discrepancies between metadata timecode and the visible timecode on screen.
///
/// ## Architecture
///
/// ```
/// ┌─────────────────────────────────────────────────────────────────┐
/// │              Video Reel Inspector (UI)                          │
/// │  (calls detectBurnedInTimecode when user requests)              │
/// └─────────────────────────────────────────────────────────────────┘
///                               │
///                               ▼
/// ┌─────────────────────────────────────────────────────────────────┐
/// │           TimecodeOCRManager (this file)                        │
/// │  - Extracts frames from video at sample times                   │
/// │  - Runs Vision OCR to detect text                               │
/// │  - Matches timecode patterns (HH:MM:SS:FF)                      │
/// │  - Compares with metadata timecode                              │
/// └─────────────────────────────────────────────────────────────────┘
///                               │
///                               ▼
/// ┌─────────────────────────────────────────────────────────────────┐
/// │              Vision Framework (VNRecognizeTextRequest)          │
/// └─────────────────────────────────────────────────────────────────┘
/// ```
///
/// ## Detection Strategy
///
/// Frames are sampled at multiple positions (0.5s, 1s, 2s, 5s) to increase the
/// chance of finding burned-in timecode. The detector prefers timecodes in the
/// upper portion of the frame (Y > 0.7 in Vision coordinates) where SEQ TC and
/// record-run timecodes are typically burned in.
///
/// ## Usage
///
/// ```swift
/// let manager = TimecodeOCRManager()
///
/// if let result = await manager.detectBurnedInTimecode(
///     from: videoURL,
///     metadataTimecodeSeconds: 3600.0,  // 01:00:00:00
///     frameRate: 24.0
/// ) {
///     print("Burned-in TC: \(result.burnedInTimecode)")
///     print("Difference: \(result.formattedDifference)")
/// }
/// ```
///
/// ## Thread Safety
///
/// This class is `@MainActor`-isolated for safe UI observation. Vision processing
/// runs on a background queue internally.
@MainActor
final class TimecodeOCRManager: ObservableObject {
    // MARK: - Published Properties

    /// Detected burned-in timecode string (if found)
    @Published private(set) var detectedTimecode: String?

    /// Whether OCR detection is in progress
    @Published private(set) var isDetecting = false

    // MARK: - Detection Result

    /// Result of burned-in timecode detection.
    ///
    /// Contains the detected timecode, the comparison with metadata timecode,
    /// and the calculated difference.
    struct DetectionResult {
        /// The burned-in timecode string as detected by OCR (e.g., "01:23:45:12").
        let burnedInTimecode: String

        /// The burned-in timecode converted to seconds.
        let burnedInSeconds: Double

        /// The metadata timecode in seconds (for comparison).
        let metadataSeconds: Double

        /// Difference between burned-in and metadata in seconds.
        let differenceSeconds: Double

        /// Video frame rate used for frame calculations.
        let frameRate: Double

        /// The offset to add to metadata TC to match burned-in TC.
        var suggestedOffset: Double {
            return burnedInSeconds - metadataSeconds
        }

        /// Human-readable difference in frames (e.g., "+24 frames").
        var formattedDifference: String {
            let frames = Int(abs(differenceSeconds) * frameRate)
            let sign = differenceSeconds >= 0 ? "+" : "-"
            return "\(sign)\(frames) frames"
        }
    }

    // MARK: - Public Methods

    /// Detects burned-in timecode from a video and compares with metadata.
    ///
    /// Samples multiple frames from the video and uses Vision OCR to detect
    /// timecode patterns. Returns a result only if the detected timecode differs
    /// significantly (>1 second) from the metadata timecode.
    ///
    /// - Parameters:
    ///   - url: Video file URL to analyze.
    ///   - metadataTimecodeSeconds: Current timecode offset from metadata (in seconds).
    ///   - frameRate: Video frame rate for frame-to-time conversion.
    /// - Returns: Detection result if burned-in TC differs from metadata, or `nil` if
    ///            no timecode was found or they match.
    func detectBurnedInTimecode(
        from url: URL,
        metadataTimecodeSeconds: Double,
        frameRate: Double
    ) async -> DetectionResult? {
        isDetecting = true
        defer { isDetecting = false }

        // Extract frames from multiple positions to increase detection chances
        let sampleTimes: [Double] = [0.5, 1.0, 2.0, 5.0] // Sample at various points

        for sampleTime in sampleTimes {
            if let frame = await extractFrame(from: url, at: sampleTime) {
                if let timecodeString = await detectTimecodeInImage(frame) {
                    detectedTimecode = timecodeString

                    // Parse the detected timecode to seconds
                    if let burnedInSeconds = parseTimecodeToSeconds(timecodeString, frameRate: frameRate) {
                        // Account for the sample time offset
                        let adjustedBurnedIn = burnedInSeconds - sampleTime
                        let difference = abs(adjustedBurnedIn - metadataTimecodeSeconds)

                        // Only report if difference is more than 1 second (significant mismatch)
                        if difference > 1.0 {
                            return DetectionResult(
                                burnedInTimecode: timecodeString,
                                burnedInSeconds: adjustedBurnedIn,
                                metadataSeconds: metadataTimecodeSeconds,
                                differenceSeconds: adjustedBurnedIn - metadataTimecodeSeconds,
                                frameRate: frameRate
                            )
                        }
                    }
                }
            }
        }

        return nil
    }

    // MARK: - Private Methods

    /// Extracts a single frame from video at the specified time.
    ///
    /// - Parameters:
    ///   - url: Video file URL.
    ///   - timeSeconds: Time offset in seconds to extract.
    /// - Returns: The extracted frame as a CGImage, or `nil` if extraction fails.
    private func extractFrame(from url: URL, at timeSeconds: Double) async -> CGImage? {
        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let time = CMTime(seconds: timeSeconds, preferredTimescale: 600)

        do {
            let (cgImage, _) = try await generator.image(at: time)
            return cgImage
        } catch {
            print("Failed to extract frame: \(error)")
            return nil
        }
    }

    /// Uses Vision OCR to detect timecode text in an image.
    ///
    /// Runs a VNRecognizeTextRequest on the image and searches for timecode patterns.
    /// Prefers timecodes in the upper portion of the frame (Y > 0.7) where burn-in
    /// timecodes are typically placed.
    ///
    /// - Parameter image: The video frame to analyze.
    /// - Returns: The detected timecode string (normalized to HH:MM:SS:FF), or `nil`.
    private func detectTimecodeInImage(_ image: CGImage) async -> String? {
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                guard error == nil,
                      let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: nil)
                    return
                }

                // Collect all timecodes found with their positions
                var foundTimecodes: [(timecode: String, y: CGFloat)] = []

                // Look for timecode patterns in detected text
                for observation in observations {
                    guard let candidate = observation.topCandidates(1).first else { continue }
                    let text = candidate.string

                    // Try to find timecode pattern
                    if let timecode = self.extractTimecodeFromText(text) {
                        // Vision uses normalized coordinates where Y=0 is bottom, Y=1 is top
                        let centerY = (observation.boundingBox.minY + observation.boundingBox.maxY) / 2
                        foundTimecodes.append((timecode, centerY))
                    }
                }

                // Prefer timecodes in the upper portion of the frame (Y > 0.7 in Vision coords)
                // This is where SEQ TC / record run timecodes are typically burned in
                if let upperTimecode = foundTimecodes.first(where: { $0.y > 0.7 }) {
                    continuation.resume(returning: upperTimecode.timecode)
                    return
                }

                // Fall back to any timecode found
                if let anyTimecode = foundTimecodes.first {
                    continuation.resume(returning: anyTimecode.timecode)
                    return
                }

                continuation.resume(returning: nil)
            }

            // Configure for accuracy
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false

            let handler = VNImageRequestHandler(cgImage: image, options: [:])

            do {
                try handler.perform([request])
            } catch {
                print("Vision request failed: \(error)")
                continuation.resume(returning: nil)
            }
        }
    }

    /// Extracts a timecode pattern from OCR text.
    ///
    /// Matches common timecode patterns including non-drop (`:`) and drop-frame (`;`) separators.
    /// Supported patterns: `01:02:03:04`, `01:02:03;04`, `01:02:03.04`
    ///
    /// - Parameter text: Raw text from OCR detection.
    /// - Returns: Normalized timecode string (HH:MM:SS:FF), or `nil` if no pattern found.
    private func extractTimecodeFromText(_ text: String) -> String? {
        // Common timecode patterns:
        // HH:MM:SS:FF (non-drop)
        // HH:MM:SS;FF (drop-frame)
        // HH:MM:SS.FF (alternative)
        // Also handle cases with spaces or other separators

        // Clean up text - remove spaces around colons
        let cleaned = text.replacingOccurrences(of: " : ", with: ":")
                          .replacingOccurrences(of: ": ", with: ":")
                          .replacingOccurrences(of: " :", with: ":")

        // Pattern: 2 digits, separator, 2 digits, separator, 2 digits, separator, 2 digits
        let patterns = [
            #"(\d{2}):(\d{2}):(\d{2})[:;.](\d{2})"#,  // Standard TC
            #"(\d{2})\.(\d{2})\.(\d{2})[:;.](\d{2})"#, // Dot separators
            #"(\d{1,2}):(\d{2}):(\d{2}):(\d{2})"#,     // Hour might be 1 digit
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               let match = regex.firstMatch(in: cleaned, options: [], range: NSRange(cleaned.startIndex..., in: cleaned)) {

                if let range = Range(match.range, in: cleaned) {
                    let matchedString = String(cleaned[range])
                    // Normalize to HH:MM:SS:FF format
                    return normalizeTimecode(matchedString)
                }
            }
        }

        return nil
    }

    /// Normalizes various timecode formats to HH:MM:SS:FF.
    ///
    /// Replaces alternate separators (`;`, `.`) with colons and zero-pads components.
    ///
    /// - Parameter tc: Raw timecode string from pattern matching.
    /// - Returns: Normalized timecode with colon separators and zero-padded components.
    private func normalizeTimecode(_ tc: String) -> String {
        // Replace various separators with colons
        let cleaned = tc.replacingOccurrences(of: ";", with: ":")
                        .replacingOccurrences(of: ".", with: ":")

        // Ensure proper formatting
        let components = cleaned.split(separator: ":")
        if components.count == 4 {
            let h = String(format: "%02d", Int(components[0]) ?? 0)
            let m = String(format: "%02d", Int(components[1]) ?? 0)
            let s = String(format: "%02d", Int(components[2]) ?? 0)
            let f = String(format: "%02d", Int(components[3]) ?? 0)
            return "\(h):\(m):\(s):\(f)"
        }

        return cleaned
    }

    /// Parses a timecode string to total seconds.
    ///
    /// Converts HH:MM:SS:FF format to a floating-point seconds value using
    /// the provided frame rate for the frame component.
    ///
    /// - Parameters:
    ///   - tc: Normalized timecode string (HH:MM:SS:FF).
    ///   - frameRate: Frame rate for converting frames to fractional seconds.
    /// - Returns: Total seconds, or `nil` if the timecode format is invalid.
    private func parseTimecodeToSeconds(_ tc: String, frameRate: Double) -> Double? {
        let components = tc.split(separator: ":")
        guard components.count == 4,
              let hours = Int(components[0]),
              let minutes = Int(components[1]),
              let seconds = Int(components[2]),
              let frames = Int(components[3]) else {
            return nil
        }

        let totalSeconds = Double(hours) * 3600.0 +
                          Double(minutes) * 60.0 +
                          Double(seconds) +
                          Double(frames) / frameRate

        return totalSeconds
    }
}
