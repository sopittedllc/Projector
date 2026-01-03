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
                let atlas = try await Self.generateAtlasForClip(
                    clip: clip,
                    samplesPerSecond: sps,
                    bucketCounts: atlasBucketCounts
                )

                await MainActor.run {
                    self.clipAtlases[clipId] = atlas
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

        let samples: [Float]
        switch clip.sourceType {
        case .audioFile:
            let sampleCount = max(10, Int(durationSeconds * Double(samplesPerSecond)))
            let analyzer = WaveformAnalyzer()
            samples = try await analyzer.samples(fromAudioAt: url, count: sampleCount)
        case .videoTrack:
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard !audioTracks.isEmpty else {
                throw WaveformCacheError.noAudioTracks
            }
            let trackIndex = clip.sourceTrackIndex ?? 0
            guard audioTracks.indices.contains(trackIndex) else {
                throw WaveformCacheError.invalidTrackIndex
            }
            samples = try await samplesUsingAssetReader(
                asset: asset,
                track: audioTracks[trackIndex],
                samplesPerSecond: samplesPerSecond,
                durationSeconds: durationSeconds
            )
        }

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

        let expectedSamples = Int(durationSeconds * Double(samplesPerSecond))
        var samples: [Float] = []
        samples.reserveCapacity(expectedSamples)

        var sampleRate: Double = 48000
        if let formatDesc = try await track.load(.formatDescriptions).first,
           let basicDesc = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) {
            sampleRate = basicDesc.pointee.mSampleRate
        }

        let samplesPerOutputSample = max(1, Int(sampleRate) / samplesPerSecond)
        var sampleBuffer: [Float] = []
        sampleBuffer.reserveCapacity(samplesPerOutputSample * 2)

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

            let floatCount = length / MemoryLayout<Float>.size
            let floatPointer = data.withMemoryRebound(to: Float.self, capacity: floatCount) { $0 }

            for i in 0..<floatCount {
                sampleBuffer.append(abs(floatPointer[i]))

                if sampleBuffer.count >= samplesPerOutputSample {
                    let peak = sampleBuffer.max() ?? 0
                    samples.append(min(1.0, peak))
                    sampleBuffer.removeAll(keepingCapacity: true)
                }
            }
        }

        if !sampleBuffer.isEmpty {
            let peak = sampleBuffer.max() ?? 0
            samples.append(min(1.0, peak))
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
