import Foundation
import AVFoundation
import DSWaveformImage

/// Caches and generates waveform data for audio clips and tracks
@MainActor
final class WaveformCache: ObservableObject {
    // MARK: - Published Properties

    /// Generated waveform atlases keyed by clip ID
    @Published private(set) var clipAtlases: [UUID: WaveformAtlas] = [:]

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
    /// 200 samples/sec provides good visual detail for typical zoom levels
    var samplesPerSecond: Int = 200

    // MARK: - Private State

    /// Generation tasks in progress
    private var generationTasks: [UUID: Task<Void, Never>] = [:]

    /// Shared waveform analyzer instance
    private let analyzer = WaveformAnalyzer()

    /// Bucket counts used for atlas levels.
    private let atlasBucketCounts: [Int] = [256, 512, 1024, 2048, 4096, 8192, 16384]

    // MARK: - Clip-Based Waveform Methods

    /// Get or generate waveform render data for a clip at a target width.
    func renderData(for clip: AudioClip, targetWidth: Int) -> WaveformRenderData? {
        if let atlas = clipAtlases[clip.id] {
            let bucketCount = closestBucketCount(for: targetWidth)
            if let level = atlas.levels[bucketCount] {
                return WaveformRenderData(duration: atlas.duration, level: level)
            }
        }

        if generationTasks[clip.id] == nil {
            startGeneration(for: clip)
        }

        return nil
    }

    /// Generate waveform for a clip asynchronously
    private func startGeneration(for clip: AudioClip) {
        let clipId = clip.id
        let sps = samplesPerSecond

        pendingCount += 1

        let task = Task {
            do {
                let bucketCounts = atlasBucketCounts
                let atlas = try await Task.detached(priority: .userInitiated) {
                    try await Self.generateAtlasForClip(
                        clip: clip,
                        samplesPerSecond: sps,
                        bucketCounts: bucketCounts
                    )
                }.value

                self.clipAtlases[clipId] = atlas
                self.generationTasks.removeValue(forKey: clipId)
                self.pendingCount -= 1
                self.updateGeneratingState()
            } catch {
                NSLog(">>> WaveformCache: Failed to generate waveform for clip \(clipId): \(error)")
                self.generationTasks.removeValue(forKey: clipId)
                self.pendingCount -= 1
                self.updateGeneratingState()
            }
        }

        generationTasks[clipId] = task
        updateGeneratingState()
    }

    /// Generate waveform atlas for a specific clip.
    private nonisolated static func generateAtlasForClip(
        clip: AudioClip,
        samplesPerSecond: Int,
        bucketCounts: [Int]
    ) async throws -> WaveformAtlas {
        let url = clip.sourceURL
        let accessGranted = url.startAccessingSecurityScopedResource()
        defer {
            if accessGranted {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let asset = AVAsset(url: url)
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        let maxSampleCount = (bucketCounts.max() ?? 16384) * 8
        let rawSampleCount = Int(durationSeconds * Double(samplesPerSecond))
        let sampleCount = max(10, min(rawSampleCount, maxSampleCount))
        let effectiveSamplesPerSecond = max(
            1,
            min(samplesPerSecond, Int(Double(sampleCount) / max(durationSeconds, 1)))
        )

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
            throw WaveformCacheError.noAudioTracks
        }
        let trackIndex = clip.sourceTrackIndex ?? 0
        guard audioTracks.indices.contains(trackIndex) else {
            throw WaveformCacheError.invalidTrackIndex
        }
        let track = audioTracks[trackIndex]
        let trackTimeRange = try await track.load(.timeRange)
        let trackStartSeconds = CMTimeGetSeconds(trackTimeRange.start)

        let rawSamples = try await samplesUsingAssetReader(
            asset: asset,
            track: track,
            samplesPerSecond: effectiveSamplesPerSecond,
            durationSeconds: durationSeconds
        )

        let samples = applyTrackOffset(
            samples: rawSamples,
            expectedSamples: sampleCount,
            trackStartSeconds: trackStartSeconds,
            durationSeconds: durationSeconds
        )

        let normalizedSamples = normalize(samples: samples)
        let levels = buildLevels(from: normalizedSamples, bucketCounts: bucketCounts)
        return WaveformAtlas(duration: durationSeconds, levels: levels)
    }

    private nonisolated static func samplesUsingAssetReader(
        asset: AVAsset,
        track: AVAssetTrack,
        samplesPerSecond: Int,
        durationSeconds: Double
    ) async throws -> [Float] {
        let reader = try AVAssetReader(asset: asset)
        let expectedSamples = Int(durationSeconds * Double(samplesPerSecond))
        var samples: [Float] = []
        samples.reserveCapacity(expectedSamples)

        var sampleRate: Double = 48000
        if let formatDesc = try await track.load(.formatDescriptions).first,
           let basicDesc = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) {
            sampleRate = basicDesc.pointee.mSampleRate
        }

        let targetSampleRate = min(sampleRate, max(8000, Double(samplesPerSecond) * 20))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)

        guard reader.startReading() else {
            throw WaveformCacheError.failedToStartReading
        }

        let processingSampleRate = targetSampleRate
        let samplesPerOutputSample = max(1, Int(processingSampleRate) / samplesPerSecond)
        let int16Scale: Float = 1.0 / 32768.0
        var samplesInBucket = 0
        var currentPeak: Int32 = 0

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

            let sampleCount = length / MemoryLayout<Int16>.size
            let samplePointer = data.withMemoryRebound(to: Int16.self, capacity: sampleCount) { $0 }

            for sampleIndex in 0..<sampleCount {
                let absValue = abs(Int32(samplePointer[sampleIndex]))
                if absValue > currentPeak {
                    currentPeak = absValue
                }
                samplesInBucket += 1
                if samplesInBucket >= samplesPerOutputSample {
                    samples.append(min(1.0, Float(currentPeak) * int16Scale))
                    samplesInBucket = 0
                    currentPeak = 0
                }
            }
        }

        if samplesInBucket > 0 {
            samples.append(min(1.0, Float(currentPeak) * int16Scale))
        }

        reader.cancelReading()

        return samples
    }

    /// Check if waveform is currently being generated for a clip
    func isLoading(for clip: AudioClip) -> Bool {
        generationTasks[clip.id] != nil
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
        clipAtlases.removeValue(forKey: clipId)
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

        for (index, _) in audioTracks.enumerated() {
            do {
                let duration = try await asset.load(.duration)
                let durationSeconds = CMTimeGetSeconds(duration)
                let sampleCount = max(10, Int(durationSeconds * Double(sps)))

                let analyzer = WaveformAnalyzer()
                let samples = try await analyzer.samples(fromAudioAt: url, count: sampleCount)

                trackWaveforms[index] = WaveformData(
                    trackIndex: index,
                    samples: samples,
                    samplesPerSecond: sps,
                    duration: durationSeconds
                )
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

        clipAtlases.removeAll()
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

        clipAtlases.removeAll()
        updateGeneratingState()
    }

    /// Clear legacy track waveforms
    func clearTrackWaveforms() {
        trackWaveforms.removeAll()
    }

    private func closestBucketCount(for targetWidth: Int) -> Int {
        let clampedTarget = max(1, targetWidth)
        return atlasBucketCounts.min(by: { abs($0 - clampedTarget) < abs($1 - clampedTarget) }) ?? atlasBucketCounts.last ?? 512
    }

    private nonisolated static func normalize(samples: [Float]) -> [Float] {
        guard let peak = samples.map({ abs($0) }).max(), peak > 0 else {
            return samples.map { abs($0) }
        }
        let scale = 1.0 / peak
        return samples.map { abs($0) * scale }
    }

    private nonisolated static func applyTrackOffset(
        samples: [Float],
        expectedSamples: Int,
        trackStartSeconds: Double,
        durationSeconds: Double
    ) -> [Float] {
        guard expectedSamples > 0 else { return samples }
        var output = samples
        if trackStartSeconds > 0, durationSeconds > 0 {
            let leadingSamples = max(0, Int(round((trackStartSeconds / durationSeconds) * Double(expectedSamples))))
            if leadingSamples > 0 {
                output.insert(contentsOf: Array(repeating: 0, count: leadingSamples), at: 0)
            }
        }

        if output.count < expectedSamples {
            output.append(contentsOf: Array(repeating: 0, count: expectedSamples - output.count))
        } else if output.count > expectedSamples {
            output = Array(output.prefix(expectedSamples))
        }

        return output
    }

    private nonisolated static func buildLevels(from samples: [Float], bucketCounts: [Int]) -> [Int: WaveformLevel] {
        var levels: [Int: WaveformLevel] = [:]
        for bucketCount in bucketCounts {
            levels[bucketCount] = buildLevel(samples: samples, bucketCount: bucketCount)
        }
        return levels
    }

    private nonisolated static func buildLevel(samples: [Float], bucketCount: Int) -> WaveformLevel {
        let safeBucketCount = max(1, bucketCount)
        var minValues = Array(repeating: Float(0), count: safeBucketCount)
        var maxValues = Array(repeating: Float(0), count: safeBucketCount)
        var rmsValues = Array(repeating: Float(0), count: safeBucketCount)

        guard !samples.isEmpty else {
            return WaveformLevel(min: minValues, max: maxValues, rms: rmsValues)
        }

        let bucketSize = Double(samples.count) / Double(safeBucketCount)
        for bucketIndex in 0..<safeBucketCount {
            let startIndex = Int(Double(bucketIndex) * bucketSize)
            let endIndex = min(samples.count, Int(Double(bucketIndex + 1) * bucketSize))
            if startIndex >= endIndex {
                continue
            }
            var minValue: Float = 1
            var maxValue: Float = 0
            var sumSquares: Float = 0
            for i in startIndex..<endIndex {
                let value = samples[i]
                minValue = min(minValue, value)
                maxValue = max(maxValue, value)
                sumSquares += value * value
            }
            minValues[bucketIndex] = minValue
            maxValues[bucketIndex] = maxValue
            let meanSquare = sumSquares / Float(endIndex - startIndex)
            rmsValues[bucketIndex] = sqrt(meanSquare)
        }

        return WaveformLevel(min: minValues, max: maxValues, rms: rmsValues)
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
