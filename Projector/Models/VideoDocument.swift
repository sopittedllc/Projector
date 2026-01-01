import Foundation
import AVFoundation
import SwiftTimecodeCore
import SwiftTimecodeAV

/// Represents a loaded video file with its metadata and settings
@MainActor
final class VideoDocument: ObservableObject, Identifiable {
    let id = UUID()

    // MARK: - File Properties

    /// URL of the video file
    let url: URL

    /// Display name (filename without extension)
    var displayName: String {
        url.deletingPathExtension().lastPathComponent
    }

    // MARK: - Video Properties

    /// Duration of the video in seconds
    @Published private(set) var duration: Double = 0

    /// Detected frame rate
    @Published private(set) var frameRate: TimecodeFrameRate = .fps24

    /// Video dimensions
    @Published private(set) var videoSize: CGSize = .zero

    /// Whether the video has audio
    @Published private(set) var hasAudio: Bool = false

    /// Number of audio channels
    @Published private(set) var audioChannelCount: Int = 0

    // MARK: - Timecode Properties

    /// Detected start timecode from file metadata
    @Published private(set) var detectedStartTimecode: Timecode?

    /// User-customized start timecode (overrides detected if set)
    @Published var customStartTimecode: Timecode?

    /// Source of the timecode (track, metadata, or none)
    @Published private(set) var timecodeSource: TimecodeSource = .none

    /// Effective start timecode (custom if set, otherwise detected, otherwise zero)
    var startTimecode: Timecode {
        if let custom = customStartTimecode {
            return custom
        }
        if let detected = detectedStartTimecode {
            return detected
        }
        return Timecode(.components(h: 0, m: 0, s: 0, f: 0), at: frameRate, by: .clamping)
    }

    // MARK: - Timecode Source

    enum TimecodeSource: String {
        case track = "Timecode Track"
        case metadata = "Metadata"
        case none = "None"
    }

    // MARK: - Initialization

    init(url: URL) {
        self.url = url
    }

    /// Load metadata from the video file
    func loadMetadata() async throws {
        let asset = AVAsset(url: url)

        // Load duration
        let durationTime = try await asset.load(.duration)
        self.duration = CMTimeGetSeconds(durationTime)

        // Load tracks
        let tracks = try await asset.load(.tracks)

        // Analyze video track
        if let videoTrack = tracks.first(where: { $0.mediaType == .video }) {
            let nominalFPS = try await videoTrack.load(.nominalFrameRate)
            self.frameRate = TimecodeFrameRate.detect(from: nominalFPS)

            let naturalSize = try await videoTrack.load(.naturalSize)
            self.videoSize = naturalSize
        }

        // Analyze audio tracks
        let audioTracks = tracks.filter { $0.mediaType == .audio }
        self.hasAudio = !audioTracks.isEmpty

        if let audioTrack = audioTracks.first {
            let formatDescriptions = try await audioTrack.load(.formatDescriptions)
            if let formatDesc = formatDescriptions.first {
                let audioStreamBasicDesc = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
                self.audioChannelCount = Int(audioStreamBasicDesc?.pointee.mChannelsPerFrame ?? 0)
            }
        }

        // Detect timecode from asset
        await detectTimecode(from: asset)
    }

    // MARK: - Timecode Detection

    private func detectTimecode(from asset: AVAsset) async {
        // Try to read timecode from timecode track first
        if let timecode = await readTimecodeFromTrack(asset: asset) {
            self.detectedStartTimecode = timecode
            self.timecodeSource = .track
            return
        }

        // Fall back to metadata
        if let timecode = await readTimecodeFromMetadata(asset: asset) {
            self.detectedStartTimecode = timecode
            self.timecodeSource = .metadata
            return
        }

        self.timecodeSource = .none
    }

    private func readTimecodeFromTrack(asset: AVAsset) async -> Timecode? {
        do {
            let tracks = try await asset.load(.tracks)
            guard let timecodeTrack = tracks.first(where: { $0.mediaType == .timecode }) else {
                return nil
            }

            // Use AVAssetReader to read the timecode track
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: timecodeTrack, outputSettings: nil)
            reader.add(output)

            guard reader.startReading() else {
                return nil
            }

            guard let sampleBuffer = output.copyNextSampleBuffer(),
                  let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                return nil
            }

            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)

            guard let data = dataPointer else {
                return nil
            }

            // Read the frame number (big endian)
            let frameNumber: Int
            if length >= 8 {
                // 64-bit timecode format
                frameNumber = data.withMemoryRebound(to: UInt64.self, capacity: 1) {
                    Int(CFSwapInt64BigToHost($0.pointee))
                }
            } else if length >= 4 {
                // 32-bit timecode format
                frameNumber = data.withMemoryRebound(to: UInt32.self, capacity: 1) {
                    Int(CFSwapInt32BigToHost($0.pointee))
                }
            } else {
                return nil
            }

            reader.cancelReading()

            // Convert frame number to timecode
            return try? Timecode(.frames(frameNumber), at: frameRate)

        } catch {
            return nil
        }
    }

    private func readTimecodeFromMetadata(asset: AVAsset) async -> Timecode? {
        do {
            let metadata = try await asset.load(.metadata)

            // Look for common timecode metadata keys
            let timecodeKeys = [
                "com.apple.quicktime.timecode.time",
                "com.apple.quicktime.timecode",
                "timecode"
            ]

            for item in metadata {
                guard let key = item.commonKey?.rawValue ?? item.key as? String else {
                    continue
                }

                if timecodeKeys.contains(where: { key.lowercased().contains($0.lowercased()) }) {
                    if let stringValue = try await item.load(.stringValue) {
                        // Try to parse timecode string
                        if let tc = try? Timecode(.string(stringValue), at: frameRate) {
                            return tc
                        }
                    }
                }
            }

            return nil
        } catch {
            return nil
        }
    }

    // MARK: - Timecode Conversion

    /// Convert a position in seconds to timecode
    func timecode(at seconds: Double) -> Timecode {
        let frameOffset = Int(seconds * frameRate.fps)
        let startFrames = startTimecode.frameCount.wholeFrames
        if let tc = try? Timecode(.frames(startFrames + frameOffset), at: frameRate) {
            return tc
        }
        return startTimecode
    }

    /// Convert a timecode to position in seconds (relative to video start)
    func seconds(at timecode: Timecode) -> Double {
        let frameOffset = timecode.frameCount.wholeFrames - startTimecode.frameCount.wholeFrames
        return Double(max(0, frameOffset)) / frameRate.fps
    }

    /// Check if a timecode is within the video's range
    func contains(timecode: Timecode) -> Bool {
        let seconds = self.seconds(at: timecode)
        return seconds >= 0 && seconds <= duration
    }
}

// MARK: - Hashable

extension VideoDocument: Hashable {
    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    nonisolated static func == (lhs: VideoDocument, rhs: VideoDocument) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - TimecodeFrameRate fps extension (use existing from VideoPlayerManager)

extension TimecodeFrameRate {
    /// Returns the frames per second as a Double (if not already defined)
    var fpsValue: Double {
        fps
    }
}
