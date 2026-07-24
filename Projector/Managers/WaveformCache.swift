import Foundation
import AVFoundation
import DSWaveformImage

// MARK: - WaveformCache

/// A multi-resolution waveform cache for audio clips with lazy generation.
///
/// `WaveformCache` generates and caches waveform amplitude data for audio clips,
/// supporting multiple resolution levels for efficient rendering at different zoom levels.
/// It uses DSWaveformImage for analysis and provides:
/// - **Multi-resolution levels**: 256 to 16384 samples per waveform
/// - **Lazy generation**: Waveforms are generated on-demand in background tasks
/// - **Clip-based caching**: Keyed by AudioClip ID for efficient lookup
/// - **Legacy track support**: Backward compatibility with track-indexed waveforms
///
/// ## Architecture
///
/// ```
/// ┌─────────────────────────────────────────────────────────────────┐
/// │                     WaveformCache                                │
/// │  ┌─────────────────────────────────────────────────────────────┐│
/// │  │ clipAtlases: [UUID: WaveformAtlas]                          ││
/// │  │   └── WaveformAtlas                                         ││
/// │  │         ├── level[256]: WaveformLevel (min/max/rms)         ││
/// │  │         ├── level[512]: WaveformLevel                       ││
/// │  │         ├── level[1024]: WaveformLevel                      ││
/// │  │         └── ...                                              ││
/// │  └─────────────────────────────────────────────────────────────┘│
/// │  ┌─────────────────────────────────────────────────────────────┐│
/// │  │ generationTasks: [UUID: Task]                               ││
/// │  │   └── Tracks in-flight generation to prevent duplicates    ││
/// │  └─────────────────────────────────────────────────────────────┘│
/// └─────────────────────────────────────────────────────────────────┘
/// ```
///
/// ## Thread Safety
///
/// - The cache is `@MainActor` isolated for safe SwiftUI observation
/// - Waveform generation runs on detached tasks for concurrent processing
/// - Static generation methods are `nonisolated` for background execution
///
/// ## Usage
///
/// ```swift
/// @StateObject var waveformCache = WaveformCache()
///
/// // Get render data for a clip at a target width
/// if let data = waveformCache.renderData(for: clip, targetWidth: 500) {
///     // Use data.level.max for peak visualization
/// }
///
/// // Check if still generating
/// if waveformCache.isLoading(for: clip) {
///     ProgressView()
/// }
///
/// // Clean up when clip is removed
/// waveformCache.removeCachedWaveform(for: clip.id)
/// ```
@MainActor
final class WaveformCache: ObservableObject {

    // MARK: - Published Properties

    /// Multi-resolution waveform atlases keyed by audio clip ID.
    ///
    /// Each atlas contains multiple resolution levels (WaveformLevels) for a single clip.
    /// Published to allow SwiftUI views to observe changes and re-render when new
    /// waveforms become available.
    @Published private(set) var clipAtlases: [UUID: WaveformAtlas] = [:]

    /// Legacy waveforms keyed by track index.
    ///
    /// Used for track-based waveform generation mode (deprecated in favor of clip-based).
    /// Each WaveformData contains raw samples at a fixed resolution.
    @Published private(set) var trackWaveforms: [Int: WaveformData] = [:]

    /// Whether any waveform generation is currently in progress.
    ///
    /// `true` when at least one clip is being processed.
    @Published private(set) var isGenerating = false

    /// Overall progress of current generation operations (0.0 to 1.0).
    ///
    /// Only meaningful for legacy track-based generation mode.
    @Published private(set) var progress: Double = 0

    /// Number of pending generation tasks.
    ///
    /// Used to track how many clips are queued for processing.
    @Published private(set) var pendingCount: Int = 0

    // MARK: - Configuration

    /// Number of waveform samples to generate per second of audio.
    ///
    /// Higher values provide more visual detail but consume more memory:
    /// - 100: Low detail, fast generation
    /// - 200: Good balance (default)
    /// - 400: High detail, slower generation
    var samplesPerSecond: Int = 200

    // MARK: - Private State

    /// In-flight generation tasks keyed by clip ID.
    ///
    /// Prevents duplicate generation requests for the same clip.
    private struct Generation {
        let token: UUID
        let task: Task<Void, Never>
    }

    private var generationTasks: [UUID: Generation] = [:]

    private final class AssetReaderBox: @unchecked Sendable {
        let reader: AVAssetReader
        init(_ reader: AVAssetReader) { self.reader = reader }
    }

    /// Requests deferred until the current SwiftUI update has completed.
    ///
    /// `renderData` is called while SwiftUI evaluates a view. Starting generation
    /// synchronously from there publishes state during the view update, which is
    /// undefined behavior. This set prevents duplicate deferred requests.
    private var queuedGenerationIDs: Set<UUID> = []

    /// DSWaveformImage analyzer for legacy track-based mode.
    private let analyzer = WaveformAnalyzer()

    /// Predefined bucket counts for atlas resolution levels.
    ///
    /// These values represent the number of samples at each resolution level.
    /// Higher counts provide more detail for zoomed-in views.
    private let atlasBucketCounts: [Int] = [256, 512, 1024, 2048, 4096, 8192, 16384]

    // MARK: - Clip-Based Waveform Methods

    /// Returns waveform render data for an audio clip, triggering generation if needed.
    ///
    /// This is the primary method for retrieving waveform data. It:
    /// 1. Checks if a cached atlas exists for the clip
    /// 2. Finds the best resolution level for the target width
    /// 3. If not cached, triggers background generation
    ///
    /// - Parameters:
    ///   - clip: The audio clip to get waveform data for
    ///   - targetWidth: Desired rendering width in pixels (used to select resolution)
    /// - Returns: Waveform render data if available, `nil` if still generating
    ///
    /// ## Example
    /// ```swift
    /// if let data = cache.renderData(for: clip, targetWidth: viewWidth) {
    ///     drawWaveform(using: data.level.max)
    /// } else {
    ///     showLoadingIndicator()
    /// }
    /// ```
    func renderData(for clip: AudioClip, targetWidth: Int) -> WaveformRenderData? {
        if let atlas = clipAtlases[clip.id] {
            let bucketCount = closestBucketCount(for: targetWidth)
            if let level = atlas.levels[bucketCount] {
                return WaveformRenderData(duration: atlas.duration, level: level)
            }
        }

        if generationTasks[clip.id] == nil, !queuedGenerationIDs.contains(clip.id) {
            queuedGenerationIDs.insert(clip.id)
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.queuedGenerationIDs.remove(clip.id) != nil else { return }
                guard self.clipAtlases[clip.id] == nil,
                      self.generationTasks[clip.id] == nil else { return }
                self.startGeneration(for: clip)
            }
        }

        return nil
    }

    /// Starts asynchronous waveform generation for an audio clip.
    ///
    /// Spawns a detached task to generate a multi-resolution atlas for the clip.
    /// Upon completion, the atlas is stored in `clipAtlases` and published.
    ///
    /// - Parameter clip: The audio clip to generate waveforms for
    ///
    /// - Note: This method is idempotent - duplicate calls for the same clip are ignored.
    private func startGeneration(for clip: AudioClip) {
        let clipId = clip.id
        let sps = samplesPerSecond
        let bucketCounts = atlasBucketCounts
        let token = UUID()

        pendingCount += 1

        let worker = Task.detached(priority: .userInitiated) {
            try await Self.generateAtlasForClip(
                clip: clip,
                samplesPerSecond: sps,
                bucketCounts: bucketCounts
            )
        }

        let task = Task { [weak self] in
            guard let self else {
                worker.cancel()
                return
            }

            defer {
                self.finishGeneration(for: clipId, token: token)
            }

            do {
                let atlas = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                try Task.checkCancellation()

                guard self.generationTasks[clipId]?.token == token else { return }
                self.clipAtlases[clipId] = atlas
            } catch is CancellationError {
                // Cancellation is expected when clips are removed or caches reset.
            } catch {
                debugPrint("WaveformCache: Failed to generate waveform for clip \(clipId): \(error)")
            }
        }

        generationTasks[clipId] = Generation(token: token, task: task)
        updateGeneratingState()
    }

    /// Generates a multi-resolution waveform atlas for an audio clip.
    ///
    /// This method:
    /// 1. Loads the audio asset from the clip's source URL
    /// 2. Reads audio samples using AVAssetReader
    /// 3. Normalizes and processes samples
    /// 4. Builds multiple resolution levels
    ///
    /// - Parameters:
    ///   - clip: The audio clip to analyze
    ///   - samplesPerSecond: Target sample density
    ///   - bucketCounts: Resolution levels to generate
    /// - Returns: A WaveformAtlas containing all resolution levels
    /// - Throws: `WaveformCacheError` if the audio cannot be read
    ///
    /// - Note: This method is `nonisolated static` for background execution.
    private nonisolated static func generateAtlasForClip(
        clip: AudioClip,
        samplesPerSecond: Int,
        bucketCounts: [Int]
    ) async throws -> WaveformAtlas {
        let url = clip.sourceURL
        try Task.checkCancellation()
        let accessGranted = url.startAccessingSecurityScopedResource()
        defer {
            if accessGranted {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let asset = AVAsset(url: url)
        let duration = try await asset.load(.duration)
        try Task.checkCancellation()
        let durationSeconds = CMTimeGetSeconds(duration)
        let maxSampleCount = (bucketCounts.max() ?? 16384) * 8
        let rawSampleCount = Int(durationSeconds * Double(samplesPerSecond))
        let sampleCount = max(10, min(rawSampleCount, maxSampleCount))
        let effectiveSamplesPerSecond = max(
            1,
            min(samplesPerSecond, Int(Double(sampleCount) / max(durationSeconds, 1)))
        )

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        try Task.checkCancellation()
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

        try Task.checkCancellation()
        let normalizedSamples = normalize(samples: samples)
        try Task.checkCancellation()
        let levels = try buildLevels(from: normalizedSamples, bucketCounts: bucketCounts)
        return WaveformAtlas(duration: durationSeconds, levels: levels)
    }

    /// Reads audio samples from an asset using AVAssetReader.
    ///
    /// Configures the reader to output mono 16-bit PCM audio, then processes
    /// the samples to extract peak values at the target sample rate.
    ///
    /// - Parameters:
    ///   - asset: The AVAsset to read from
    ///   - track: The specific audio track to process
    ///   - samplesPerSecond: Target output sample rate
    ///   - durationSeconds: Duration for capacity estimation
    /// - Returns: Array of normalized peak amplitude values (0.0 to 1.0)
    /// - Throws: `WaveformCacheError.failedToStartReading` if reader fails
    private nonisolated static func samplesUsingAssetReader(
        asset: AVAsset,
        track: AVAssetTrack,
        samplesPerSecond: Int,
        durationSeconds: Double
    ) async throws -> [Float] {
        let reader = try AVAssetReader(asset: asset)
        let readerBox = AssetReaderBox(reader)
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

        try await withTaskCancellationHandler {
            while let sampleBuffer2 = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
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
                    if sampleIndex.isMultiple(of: 16_384) {
                        try Task.checkCancellation()
                    }
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
        } onCancel: {
            readerBox.reader.cancelReading()
        }

        if samplesInBucket > 0 {
            samples.append(min(1.0, Float(currentPeak) * int16Scale))
        }

        reader.cancelReading()

        return samples
    }

    /// Returns whether waveform generation is in progress for a clip.
    ///
    /// - Parameter clip: The audio clip to check
    /// - Returns: `true` if a generation task is running, `false` otherwise
    func isLoading(for clip: AudioClip) -> Bool {
        generationTasks[clip.id] != nil || queuedGenerationIDs.contains(clip.id)
    }

    /// Cancels any pending waveform generation for a clip.
    ///
    /// - Parameter clipId: The UUID of the clip to cancel
    func cancelGeneration(for clipId: UUID) {
        queuedGenerationIDs.remove(clipId)
        if let generation = generationTasks.removeValue(forKey: clipId) {
            generation.task.cancel()
            pendingCount = max(0, pendingCount - 1)
            updateGeneratingState()
        }
    }

    /// Removes cached waveform data for a clip.
    ///
    /// Call this when a clip is removed from the timeline to free memory.
    ///
    /// - Parameter clipId: The UUID of the clip to remove
    func removeCachedWaveform(for clipId: UUID) {
        clipAtlases.removeValue(forKey: clipId)
    }

    // MARK: - Track-Based Waveform Methods (Legacy)

    /// Generates waveforms for all audio tracks in an asset.
    ///
    /// This is the legacy track-based generation mode, superseded by clip-based
    /// generation. Use `renderData(for:targetWidth:)` for new code.
    ///
    /// - Parameter url: URL of the audio/video file
    /// - Throws: If the asset cannot be loaded
    ///
    /// - Note: Updates `progress` as tracks are processed.
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
                debugPrint("WaveformCache: Failed to generate waveform for track \(index): \(error)")
            }

            progress = Double(index + 1) * trackProgress
        }

        isGenerating = false
        progress = 1.0
    }

    /// Returns waveform data for a track by index (legacy mode).
    ///
    /// - Parameter trackIndex: The audio track index
    /// - Returns: Waveform data if available, `nil` otherwise
    func waveform(forTrack trackIndex: Int) -> WaveformData? {
        trackWaveforms[trackIndex]
    }

    // MARK: - State Management

    /// Updates the isGenerating flag based on pending task count.
    private func updateGeneratingState() {
        isGenerating = pendingCount > 0
    }

    /// Completes one tracked generation exactly once.
    private func finishGeneration(for clipId: UUID, token: UUID) {
        guard generationTasks[clipId]?.token == token else { return }
        generationTasks.removeValue(forKey: clipId)
        pendingCount = max(0, pendingCount - 1)
        updateGeneratingState()
    }

    /// Clears all cached waveforms and cancels pending tasks.
    ///
    /// Removes both clip-based and legacy track-based waveforms.
    func clearAll() {
        // Cancel all pending tasks
        for generation in generationTasks.values {
            generation.task.cancel()
        }
        generationTasks.removeAll()
        queuedGenerationIDs.removeAll()
        pendingCount = 0

        clipAtlases.removeAll()
        trackWaveforms.removeAll()
        isGenerating = false
        progress = 0
    }

    /// Clears clip-based waveforms only.
    ///
    /// Keeps legacy track waveforms intact.
    func clearClipWaveforms() {
        for generation in generationTasks.values {
            generation.task.cancel()
        }
        generationTasks.removeAll()
        queuedGenerationIDs.removeAll()
        pendingCount = 0

        clipAtlases.removeAll()
        updateGeneratingState()
    }

    /// Clears legacy track waveforms only.
    func clearTrackWaveforms() {
        trackWaveforms.removeAll()
    }

    // MARK: - Private Helpers

    /// Finds the closest predefined bucket count for a target width.
    ///
    /// - Parameter targetWidth: Desired rendering width in pixels
    /// - Returns: The nearest bucket count from `atlasBucketCounts`
    private func closestBucketCount(for targetWidth: Int) -> Int {
        let clampedTarget = max(1, targetWidth)
        return atlasBucketCounts.min(by: { abs($0 - clampedTarget) < abs($1 - clampedTarget) }) ?? atlasBucketCounts.last ?? 512
    }

    /// Normalizes samples to have a peak of 1.0.
    ///
    /// - Parameter samples: Raw amplitude samples
    /// - Returns: Normalized samples (0.0 to 1.0)
    private nonisolated static func normalize(samples: [Float]) -> [Float] {
        guard let peak = samples.map({ abs($0) }).max(), peak > 0 else {
            return samples.map { abs($0) }
        }
        let scale = 1.0 / peak
        return samples.map { abs($0) * scale }
    }

    /// Applies track timing offset and pads samples to expected length.
    ///
    /// Handles cases where audio tracks start after video start (e.g., delayed audio).
    ///
    /// - Parameters:
    ///   - samples: Raw samples from the track
    ///   - expectedSamples: Target sample count
    ///   - trackStartSeconds: When the track starts relative to asset start
    ///   - durationSeconds: Total duration of the asset
    /// - Returns: Padded/trimmed samples matching expected length
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

    /// Builds multiple resolution levels from normalized samples.
    ///
    /// - Parameters:
    ///   - samples: Normalized amplitude samples
    ///   - bucketCounts: Array of target bucket counts for each level
    /// - Returns: Dictionary mapping bucket count to WaveformLevel
    private nonisolated static func buildLevels(
        from samples: [Float],
        bucketCounts: [Int]
    ) throws -> [Int: WaveformLevel] {
        var levels: [Int: WaveformLevel] = [:]
        for bucketCount in bucketCounts {
            try Task.checkCancellation()
            levels[bucketCount] = try buildLevel(samples: samples, bucketCount: bucketCount)
        }
        return levels
    }

    /// Builds a single resolution level by downsampling.
    ///
    /// Divides samples into buckets and computes min, max, and RMS for each.
    ///
    /// - Parameters:
    ///   - samples: Normalized amplitude samples
    ///   - bucketCount: Target number of buckets (output samples)
    /// - Returns: WaveformLevel with min/max/rms arrays
    private nonisolated static func buildLevel(
        samples: [Float],
        bucketCount: Int
    ) throws -> WaveformLevel {
        let safeBucketCount = max(1, bucketCount)
        var minValues = Array(repeating: Float(0), count: safeBucketCount)
        var maxValues = Array(repeating: Float(0), count: safeBucketCount)
        var rmsValues = Array(repeating: Float(0), count: safeBucketCount)

        guard !samples.isEmpty else {
            return WaveformLevel(min: minValues, max: maxValues, rms: rmsValues)
        }

        let bucketSize = Double(samples.count) / Double(safeBucketCount)
        for bucketIndex in 0..<safeBucketCount {
            if bucketIndex.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
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

/// Errors that can occur during waveform generation.
enum WaveformCacheError: LocalizedError {
    /// AVAssetReader failed to start reading the audio track.
    case failedToStartReading

    /// The media file contains no audio tracks.
    case noAudioTracks

    /// The requested track index is out of bounds.
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
