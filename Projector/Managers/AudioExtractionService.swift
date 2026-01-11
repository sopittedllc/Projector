//
//  AudioExtractionService.swift
//  Projector
//
//  Service responsible for extracting audio tracks from video files.
//  Creates placeholder audio clips immediately, then extracts audio in background.
//

import Foundation
import AVFoundation

/// Service for extracting audio tracks from video files and managing audio lane creation.
///
/// This service handles the two-phase audio extraction workflow:
/// 1. Immediate placeholder creation - Creates an audio clip without extracted audio
///    so the UI shows the region right away
/// 2. Background extraction - Extracts the actual audio to a temporary file and
///    updates the clip with the extracted URL
///
/// - Note: This service requires `@MainActor` because it interacts with
///   `TimelineManager` which manages UI-bound state.
@MainActor
final class AudioExtractionService {

    // MARK: - Dependencies

    /// The timeline manager used to create lanes and clips
    private let timelineManager: TimelineManager

    // MARK: - Initialization

    /// Creates a new audio extraction service.
    ///
    /// - Parameter timelineManager: The timeline manager to use for lane and clip operations.
    init(timelineManager: TimelineManager) {
        self.timelineManager = timelineManager
    }

    // MARK: - Public Methods

    /// Checks if a video has audio tracks and creates a lane with a placeholder clip immediately.
    ///
    /// This method performs the following steps:
    /// 1. Loads the audio tracks from the video asset
    /// 2. Extracts channel count and sample rate from the first audio track
    /// 3. Creates a placeholder `AudioClip` without an extracted audio URL
    /// 4. Finds an existing lane that can fit the clip, or creates a new one
    /// 5. Adds the clip to the lane
    ///
    /// - Parameter reel: The video reel to check for audio tracks.
    /// - Returns: A tuple containing the audio lane and clip ID if audio tracks exist,
    ///            or `nil` if no audio tracks are found.
    func prepareAudioLaneIfNeeded(for reel: VideoReel) async -> (lane: AudioLane, clipId: UUID)? {
        let asset = AVAsset(url: reel.sourceURL)
        do {
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard !audioTracks.isEmpty else {
                debugPrint("prepareAudioLaneIfNeeded: No audio tracks found")
                return nil
            }

            // Get channel count and sample rate from audio format
            let audioTrack = audioTracks[0]
            let formatDescriptions = try await audioTrack.load(.formatDescriptions)
            var channelCount = 2
            var sampleRate: Double = 48000

            if let formatDesc = formatDescriptions.first {
                let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
                if let format = asbd?.pointee {
                    channelCount = Int(format.mChannelsPerFrame)
                    sampleRate = format.mSampleRate
                }
            }

            // Create a placeholder clip IMMEDIATELY (without extractedAudioURL)
            // This ensures the audio region appears in UI right away, before extraction completes
            let clip = AudioClip(
                mediaItemId: reel.mediaItemId,
                sourceURL: reel.sourceURL,
                sourceBookmark: reel.sourceBookmark,
                timelineStartFrame: reel.timelineStartFrame,
                durationFrames: reel.durationFrames,
                sourceStartFrame: reel.sourceStartFrame,
                sourceType: .videoTrack,
                sourceTrackIndex: 0,
                channelCount: channelCount,
                sampleRate: sampleRate,
                extractedAudioURL: nil,  // Will be set after extraction
                sourceFrameRate: reel.sourceFrameRate
            )

            // Try to find an existing lane where the clip fits without overlap
            var targetLane: AudioLane?
            for lane in timelineManager.timeline.audioLanes {
                if !lane.hasOverlap(with: clip) {
                    targetLane = lane
                    debugPrint("prepareAudioLaneIfNeeded: Found existing lane '\(lane.name)' with no overlap")
                    break
                }
            }

            // If no existing lane can fit the clip, create a new one
            if targetLane == nil {
                let laneNumber = timelineManager.timeline.audioLanes.count + 1
                targetLane = timelineManager.addAudioLaneAtTop(name: "Audio \(laneNumber)")
                debugPrint("prepareAudioLaneIfNeeded: Created new lane '\(targetLane!.name)'")
            }

            guard let lane = targetLane else {
                debugPrint("prepareAudioLaneIfNeeded: Failed to get target lane")
                return nil
            }

            timelineManager.timeline.addClip(clip, toLane: lane.id)

            debugPrint("prepareAudioLaneIfNeeded: Added clip to lane '\(lane.name)' with \(audioTracks.count) audio track(s)")
            return (lane, clip.id)
        } catch {
            debugPrint("prepareAudioLaneIfNeeded: Failed to check audio tracks - \(error)")
            return nil
        }
    }

    /// Extracts audio from a video reel in the background and updates an existing clip.
    ///
    /// This method performs the actual audio extraction work:
    /// 1. Creates an AVAsset from the reel's source URL
    /// 2. Extracts the audio track to a temporary file using passthrough (no re-encoding)
    /// 3. Updates the existing placeholder clip with the extracted audio URL
    ///
    /// - Parameters:
    ///   - reel: The video reel containing the audio to extract.
    ///   - laneId: The ID of the audio lane containing the placeholder clip.
    ///   - clipId: The ID of the placeholder clip to update with the extracted audio URL.
    func extractAudioInBackground(reel: VideoReel, laneId: UUID, clipId: UUID) async {
        let startTime = CFAbsoluteTimeGetCurrent()
        func elapsed() -> String { String(format: "%.3fs", CFAbsoluteTimeGetCurrent() - startTime) }

        debugPrint("extractAudioInBackground: ENTRY [T+\(elapsed())] - \(reel.displayName)")

        let asset = AVAsset(url: reel.sourceURL)
        do {
            // Do the slow extraction
            let extractedURL = try await extractAudioTrackToTemp(from: asset, trackIndex: 0, sourceURL: reel.sourceURL)
            debugPrint("extractAudioInBackground: Export complete [T+\(elapsed())] -> \(extractedURL.lastPathComponent)")

            // Update the existing clip with the extracted audio URL
            await MainActor.run {
                timelineManager.updateExtractedAudioURL(clipId: clipId, inLane: laneId, extractedURL: extractedURL)
            }
            debugPrint("extractAudioInBackground: COMPLETE [T+\(elapsed())]")
        } catch {
            debugPrint("extractAudioInBackground: FAILED [T+\(elapsed())] - \(error)")
        }
    }

    // MARK: - Private Methods

    /// Extracts an audio track from an asset to a temporary file.
    ///
    /// Uses passthrough (no re-encoding) for maximum speed. The audio stream is copied
    /// directly to a `.mov` container without any transcoding.
    ///
    /// - Parameters:
    ///   - asset: The AVAsset containing the audio track.
    ///   - trackIndex: The index of the audio track to extract (typically 0).
    ///   - sourceURL: The original source URL, used to generate a deterministic temp filename.
    /// - Returns: The URL of the extracted audio file in the temporary directory.
    /// - Throws: An error if extraction fails.
    /// - Note: Must be called while security-scoped access is active for the source file.
    private func extractAudioTrackToTemp(from asset: AVAsset, trackIndex: Int, sourceURL: URL) async throws -> URL {
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard trackIndex < audioTracks.count else {
            throw NSError(
                domain: "AudioExtractionService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid audio track index"]
            )
        }

        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw NSError(
                domain: "AudioExtractionService",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create composition track"]
            )
        }

        let track = audioTracks[trackIndex]
        let duration = try await asset.load(.duration)
        try compositionTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: duration),
            of: track,
            at: .zero
        )

        // Use passthrough preset - copies audio stream without re-encoding (MUCH faster)
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw NSError(
                domain: "AudioExtractionService",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create export session"]
            )
        }

        // Deterministic filename based on source URL and track
        // Use .mov container for passthrough compatibility
        let keyHash = "\(sourceURL.absoluteString)-track\(trackIndex)".hashValue
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("projector-audio-\(abs(keyHash)).mov")

        if FileManager.default.fileExists(atPath: tempURL.path) {
            try FileManager.default.removeItem(at: tempURL)
        }

        if #available(macOS 15.0, *) {
            try await export.export(to: tempURL, as: .mov)
        } else {
            export.outputURL = tempURL
            export.outputFileType = .mov

            // Wrapper to make AVAssetExportSession usable in Sendable closure
            final class ExportBox: @unchecked Sendable {
                let session: AVAssetExportSession
                init(_ session: AVAssetExportSession) { self.session = session }
            }
            let exportBox = ExportBox(export)

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                exportBox.session.exportAsynchronously {
                    switch exportBox.session.status {
                    case .completed:
                        continuation.resume(returning: ())
                    case .failed:
                        continuation.resume(throwing: exportBox.session.error ?? NSError(
                            domain: "AudioExtractionService",
                            code: -4,
                            userInfo: nil
                        ))
                    default:
                        continuation.resume(throwing: NSError(
                            domain: "AudioExtractionService",
                            code: -5,
                            userInfo: nil
                        ))
                    }
                }
            }
        }

        return tempURL
    }
}
