import Foundation
import AVFoundation
import Accelerate

/// Caches and generates waveform data for audio clips and tracks
@MainActor
final class WaveformCache: ObservableObject {
    // MARK: - Published Properties

    /// Generated waveforms keyed by clip ID
    @Published private(set) var clipWaveforms: [UUID: WaveformData] = [:]

    /// Generated waveforms keyed by track index (legacy mode)
    @Published private(set) var trackWaveforms: [Int: WaveformData] = [:]

    /// Whether waveform generation is in progress
    @Published private(set) var isGenerating = false

    /// Progress of current generation (0...1)
    @Published private(set) var progress: Double = 0

    /// Number of pending generation tasks
    @Published private(set) var pendingCount: Int = 0

    // MARK: - Configuration

    /// Samples per second for the waveform (higher = more detail, more memory)
    var samplesPerSecond: Int = 100

    // MARK: - Private State

    /// Generation tasks in progress
    private var generationTasks: [UUID: Task<Void, Never>] = [:]

    // MARK: - Clip-Based Waveform Methods

    /// Get or generate waveform for an audio clip
    func waveform(for clip: AudioClip) -> WaveformData? {
        // Check cache
        if let cached = clipWaveforms[clip.id] {
            return cached
        }

        // Start generation if not already running
        if generationTasks[clip.id] == nil {
            startGeneration(for: clip)
        }

        return nil
    }

    /// Generate waveform for a clip asynchronously
    private func startGeneration(for clip: AudioClip) {
        let clipId = clip.id
        let url = clip.sourceURL
        let trackIndex = clip.sourceTrackIndex ?? 0
        let sps = samplesPerSecond

        pendingCount += 1

        let task = Task {
            do {
                let waveform = try await Self.generateWaveformForClip(
                    url: url,
                    clipId: clipId,
                    trackIndex: trackIndex,
                    samplesPerSecond: sps
                )

                await MainActor.run {
                    self.clipWaveforms[clipId] = waveform
                    self.generationTasks.removeValue(forKey: clipId)
                    self.pendingCount -= 1
                    self.updateGeneratingState()
                }
            } catch {
                NSLog(">>> WaveformCache: Failed to generate waveform for clip \(clipId): \(error)")
                await MainActor.run {
                    self.generationTasks.removeValue(forKey: clipId)
                    self.pendingCount -= 1
                    self.updateGeneratingState()
                }
            }
        }

        generationTasks[clipId] = task
        updateGeneratingState()
    }

    /// Generate waveform for a specific clip (runs off main thread)
    private nonisolated static func generateWaveformForClip(
        url: URL,
        clipId: UUID,
        trackIndex: Int,
        samplesPerSecond: Int
    ) async throws -> WaveformData {
        let asset = AVAsset(url: url)
        let tracks = try await asset.load(.tracks)
        let audioTracks = tracks.filter { $0.mediaType == .audio }

        guard trackIndex < audioTracks.count else {
            throw WaveformCacheError.invalidTrackIndex
        }

        let track = audioTracks[trackIndex]
        return try await generateWaveform(
            for: asset,
            track: track,
            identifier: clipId.hashValue,
            samplesPerSecond: samplesPerSecond
        )
    }

    /// Cancel generation for a clip
    func cancelGeneration(for clipId: UUID) {
        if let task = generationTasks.removeValue(forKey: clipId) {
            task.cancel()
            pendingCount -= 1
            updateGeneratingState()
        }
    }

    /// Remove cached waveform for a clip
    func removeCachedWaveform(for clipId: UUID) {
        clipWaveforms.removeValue(forKey: clipId)
    }

    // MARK: - Track-Based Waveform Methods (Legacy)

    /// Generate waveforms for all audio tracks in an asset (legacy mode)
    func generateWaveforms(from url: URL) async throws {
        isGenerating = true
        progress = 0
        trackWaveforms.removeAll()

        let asset = AVAsset(url: url)
        let tracks = try await asset.load(.tracks)
        let audioTracks = tracks.filter { $0.mediaType == .audio }

        guard !audioTracks.isEmpty else {
            isGenerating = false
            progress = 1.0
            return
        }

        let trackProgress = 1.0 / Double(audioTracks.count)
        let sps = samplesPerSecond

        for (index, track) in audioTracks.enumerated() {
            do {
                let waveform = try await Task.detached(priority: .userInitiated) {
                    try await Self.generateWaveform(
                        for: asset,
                        track: track,
                        identifier: index,
                        samplesPerSecond: sps
                    )
                }.value
                trackWaveforms[index] = waveform
            } catch {
                NSLog(">>> WaveformCache: Failed to generate waveform for track \(index): \(error)")
            }

            progress = Double(index + 1) * trackProgress
        }

        isGenerating = false
        progress = 1.0
    }

    /// Get waveform for a track by index (legacy mode)
    func waveform(forTrack trackIndex: Int) -> WaveformData? {
        trackWaveforms[trackIndex]
    }

    // MARK: - Shared Generation Logic

    /// Generate waveform for a specific audio track
    private nonisolated static func generateWaveform(
        for asset: AVAsset,
        track: AVAssetTrack,
        identifier: Int,
        samplesPerSecond: Int
    ) async throws -> WaveformData {
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)

        // Create asset reader
        let reader = try AVAssetReader(asset: asset)

        // Configure output for PCM float samples
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        reader.add(output)

        guard reader.startReading() else {
            throw WaveformCacheError.failedToStartReading
        }

        // Calculate expected sample count
        let expectedSamples = Int(durationSeconds * Double(samplesPerSecond))
        var samples: [Float] = []
        samples.reserveCapacity(expectedSamples)

        // Track sample rate for downsampling
        var sampleRate: Double = 48000
        if let formatDesc = try await track.load(.formatDescriptions).first {
            if let basicDesc = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) {
                sampleRate = basicDesc.pointee.mSampleRate
            }
        }

        // Samples per output sample
        let samplesPerOutputSample = Int(sampleRate) / samplesPerSecond
        var sampleBuffer: [Float] = []
        sampleBuffer.reserveCapacity(samplesPerOutputSample * 2)

        // Read and process samples
        while let sampleBuffer2 = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer2) else { continue }

            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &length,
                dataPointerOut: &dataPointer
            )

            guard let data = dataPointer else { continue }

            // Convert to float samples
            let floatCount = length / MemoryLayout<Float>.size
            let floatPointer = data.withMemoryRebound(to: Float.self, capacity: floatCount) { $0 }

            // Process samples in chunks
            for i in 0..<floatCount {
                sampleBuffer.append(abs(floatPointer[i]))

                if sampleBuffer.count >= samplesPerOutputSample {
                    // Calculate peak
                    let peak = sampleBuffer.max() ?? 0
                    samples.append(min(1.0, peak))
                    sampleBuffer.removeAll(keepingCapacity: true)
                }
            }
        }

        // Process remaining samples
        if !sampleBuffer.isEmpty {
            let peak = sampleBuffer.max() ?? 0
            samples.append(min(1.0, peak))
        }

        reader.cancelReading()

        return WaveformData(
            trackIndex: identifier,
            samples: samples,
            samplesPerSecond: samplesPerSecond,
            duration: durationSeconds
        )
    }

    // MARK: - State Management

    private func updateGeneratingState() {
        isGenerating = pendingCount > 0
    }

    /// Clear all cached waveforms
    func clearAll() {
        // Cancel all pending tasks
        for (id, task) in generationTasks {
            task.cancel()
            generationTasks.removeValue(forKey: id)
        }
        pendingCount = 0

        clipWaveforms.removeAll()
        trackWaveforms.removeAll()
        isGenerating = false
        progress = 0
    }

    /// Clear only clip waveforms (keep legacy track waveforms)
    func clearClipWaveforms() {
        for (id, task) in generationTasks {
            task.cancel()
            generationTasks.removeValue(forKey: id)
        }
        pendingCount = 0

        clipWaveforms.removeAll()
        updateGeneratingState()
    }

    /// Clear legacy track waveforms
    func clearTrackWaveforms() {
        trackWaveforms.removeAll()
    }
}

// MARK: - Errors

enum WaveformCacheError: LocalizedError {
    case failedToStartReading
    case noAudioTracks
    case invalidTrackIndex

    var errorDescription: String? {
        switch self {
        case .failedToStartReading:
            return "Failed to start reading audio samples."
        case .noAudioTracks:
            return "No audio tracks found in the media file."
        case .invalidTrackIndex:
            return "The specified audio track index does not exist."
        }
    }
}
