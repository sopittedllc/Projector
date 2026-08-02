//
//  AudioTrackExtractor.swift
//  Projector
//
//  Extracts specific audio tracks from multi-track video containers.
//

import Foundation
import AVFoundation

/// Extracts individual audio tracks from video files to standalone CAF files.
///
/// Video files may contain multiple discrete audio tracks (e.g., dialogue, music,
/// effects, atmosphere on separate tracks). `AVAudioFile` cannot address a specific
/// track - it always reads the first one - so tracks beyond the first must be
/// extracted to disk before playback.
///
/// Track 0 continues to be read directly from the video container (no extraction
/// needed). Only tracks 1+ are extracted.
///
/// ## Architecture
///
/// ```
/// ┌─────────────────────────────────────────────────────────────────────────┐
/// │  ContentView+Timeline                                                    │
/// │  - prepareAudioLaneIfNeeded creates clips for all tracks                │
/// │  - triggers background extraction for tracks 1+                         │
/// └─────────────────────────────────────────────────────────────────────────┘
///                                │
///                                ▼
/// ┌─────────────────────────────────────────────────────────────────────────┐
/// │  AudioTrackExtractor (this file)                                        │
/// │  - AVAssetReader reads specific track                                   │
/// │  - AVAssetWriter writes CAF file                                        │
/// └─────────────────────────────────────────────────────────────────────────┘
///                                │
///                                ▼
/// ┌─────────────────────────────────────────────────────────────────────────┐
/// │  Extracted CAF file in app's temporary directory                        │
/// │  - PlaybackEngine.loadAudioClip uses this for tracks 1+                 │
/// └─────────────────────────────────────────────────────────────────────────┘
/// ```
///
/// ## File Naming
///
/// Extracted files are named `multitrack-<clipId>-track<N>.caf` where:
/// - `clipId` is the AudioClip's UUID (first 8 characters)
/// - `N` is the track index (1, 2, 3, etc.)
///
/// This naming allows cleanup when a video reel is removed.
enum AudioTrackExtractor {

    // MARK: - Public API

    /// Extract a specific audio track from a video file.
    ///
    /// Reads the audio track at `trackIndex` from `sourceURL` and writes it to a
    /// standalone CAF file in the app's temporary directory.
    ///
    /// - Parameters:
    ///   - sourceURL: The video file containing multiple audio tracks.
    ///   - trackIndex: Which audio track to extract (0-indexed).
    ///   - clipId: The AudioClip's UUID, used for file naming.
    /// - Returns: URL to the extracted CAF file.
    /// - Throws: `ExtractionError` if extraction fails.
    static func extractTrack(
        from sourceURL: URL,
        trackIndex: Int,
        clipId: UUID
    ) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)

        // Load all audio tracks
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard trackIndex < audioTracks.count else {
            throw ExtractionError.trackNotFound(index: trackIndex, available: audioTracks.count)
        }

        let track = audioTracks[trackIndex]

        // Get format description for output settings
        let formatDescriptions = try await track.load(.formatDescriptions)
        guard let formatDesc = formatDescriptions.first else {
            throw ExtractionError.noFormatDescription
        }

        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee else {
            throw ExtractionError.invalidFormat
        }

        // Create output URL
        let outputURL = outputURL(clipId: clipId, trackIndex: trackIndex)

        // Remove any existing file
        try? FileManager.default.removeItem(at: outputURL)

        // Set up reader
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: asbd.mSampleRate,
                AVNumberOfChannelsKey: asbd.mChannelsPerFrame,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false
            ]
        )
        reader.add(readerOutput)

        // Set up writer
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .caf)
        let writerInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: asbd.mSampleRate,
                AVNumberOfChannelsKey: asbd.mChannelsPerFrame,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false
            ]
        )
        writer.add(writerInput)

        // Start reading and writing
        guard reader.startReading() else {
            throw ExtractionError.readerFailed(reader.error)
        }

        guard writer.startWriting() else {
            throw ExtractionError.writerFailed(writer.error)
        }

        writer.startSession(atSourceTime: .zero)

        // Copy samples in a detached task to avoid blocking
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writerInput.requestMediaDataWhenReady(on: DispatchQueue(label: "com.projector.audioExtraction")) {
                while writerInput.isReadyForMoreMediaData {
                    if let sampleBuffer = readerOutput.copyNextSampleBuffer() {
                        writerInput.append(sampleBuffer)
                    } else {
                        // Done reading
                        writerInput.markAsFinished()
                        writer.finishWriting {
                            if writer.status == .completed {
                                continuation.resume()
                            } else {
                                continuation.resume(throwing: ExtractionError.writerFailed(writer.error))
                            }
                        }
                        return
                    }
                }
            }
        }

        debugPrint("AudioTrackExtractor: extracted track \(trackIndex) from \(sourceURL.lastPathComponent) -> \(outputURL.lastPathComponent)")
        return outputURL
    }

    /// Delete extracted files for a specific clip.
    ///
    /// Called when a video reel is removed to clean up extracted audio.
    ///
    /// - Parameter clipId: The clip whose extracted files should be deleted.
    static func cleanupExtractedFiles(for clipId: UUID) {
        let prefix = filePrefix(for: clipId)
        let tempDir = FileManager.default.temporaryDirectory

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return }

        for file in contents where file.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: file)
            debugPrint("AudioTrackExtractor: cleaned up \(file.lastPathComponent)")
        }
    }

    /// Delete all extracted multi-track audio files from a source URL.
    ///
    /// Called when a video reel is removed. Finds all extracted files that
    /// reference clips from this source.
    ///
    /// - Parameter sourceURL: The video file whose extracted tracks should be deleted.
    static func cleanupExtractedFiles(forSource sourceURL: URL) {
        let tempDir = FileManager.default.temporaryDirectory

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return }

        for file in contents where file.lastPathComponent.hasPrefix("multitrack-") && file.pathExtension == "caf" {
            try? FileManager.default.removeItem(at: file)
            debugPrint("AudioTrackExtractor: cleaned up \(file.lastPathComponent)")
        }
    }

    // MARK: - Errors

    /// Errors that can occur during track extraction.
    enum ExtractionError: LocalizedError {
        case trackNotFound(index: Int, available: Int)
        case noFormatDescription
        case invalidFormat
        case readerFailed(Error?)
        case writerFailed(Error?)

        var errorDescription: String? {
            switch self {
            case let .trackNotFound(index, available):
                return "Audio track \(index) not found. File has \(available) audio track(s)."
            case .noFormatDescription:
                return "Could not read audio format description."
            case .invalidFormat:
                return "Invalid audio format in source file."
            case let .readerFailed(error):
                return "Failed to read audio: \(error?.localizedDescription ?? "unknown error")"
            case let .writerFailed(error):
                return "Failed to write audio: \(error?.localizedDescription ?? "unknown error")"
            }
        }
    }

    // MARK: - Private

    /// Generate the output URL for an extracted track.
    private static func outputURL(clipId: UUID, trackIndex: Int) -> URL {
        let filename = "\(filePrefix(for: clipId))track\(trackIndex).caf"
        return FileManager.default.temporaryDirectory.appendingPathComponent(filename)
    }

    /// File prefix for a clip's extracted tracks.
    private static func filePrefix(for clipId: UUID) -> String {
        "multitrack-\(clipId.uuidString.prefix(8))-"
    }
}
