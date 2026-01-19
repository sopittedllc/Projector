import Foundation
import SwiftTimecodeCore

/// Detects non-silent activity segments from waveform data
enum SilenceDetectionService {

    /// Minimum segment duration in buckets to be considered a cue
    private static let minimumBuckets = 3

    /// Threshold multiplier above rmsFloor to detect activity
    private static let thresholdMultiplier: Float = 1.5

    /// Detect activity segments from waveform RMS data
    /// - Parameters:
    ///   - waveformLevel: The waveform level containing RMS data
    ///   - clipStartFrame: Timeline start frame of the clip
    ///   - clipDurationFrames: Duration of the clip in frames
    ///   - timelineConfig: Timeline configuration for timecode conversion
    /// - Returns: Array of detected cues sorted by start frame
    static func detectCues(
        from waveformLevel: WaveformLevel,
        clipStartFrame: Int,
        clipDurationFrames: Int,
        timelineConfig: TimelineConfig
    ) -> [DetectedCue] {
        let rms = waveformLevel.rms
        guard !rms.isEmpty else { return [] }

        let threshold = waveformLevel.rmsFloor * thresholdMultiplier
        let framesPerBucket = Double(clipDurationFrames) / Double(rms.count)

        var segments: [(start: Int, end: Int)] = []
        var segmentStart: Int?

        for (index, value) in rms.enumerated() {
            let isActive = value > threshold

            if isActive && segmentStart == nil {
                segmentStart = index
            } else if !isActive && segmentStart != nil {
                if index - segmentStart! >= minimumBuckets {
                    segments.append((segmentStart!, index))
                }
                segmentStart = nil
            }
        }

        // Handle segment that extends to end
        if let start = segmentStart, rms.count - start >= minimumBuckets {
            segments.append((start, rms.count))
        }

        // Convert bucket indices to timeline frames and create cues
        return segments.enumerated().map { cueIndex, segment in
            let startFrame = clipStartFrame + Int(Double(segment.start) * framesPerBucket)
            let endFrame = clipStartFrame + Int(Double(segment.end) * framesPerBucket)

            return DetectedCue(
                id: UUID(),
                number: cueIndex + 1,
                startFrame: startFrame,
                endFrame: endFrame,
                timecodeIn: timelineConfig.timecode(at: startFrame),
                timecodeOut: timelineConfig.timecode(at: endFrame)
            )
        }
    }
}
