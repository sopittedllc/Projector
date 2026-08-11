import Foundation
import AVFoundation
import Accelerate
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
    private var generationTasks: [UUID: Task<Void, Never>] = [:]

    /// Requests deferred until the current SwiftUI update has completed.
    ///
    /// `renderData` is called while SwiftUI evaluates a view. Starting generation
    /// synchronously from there publishes state during the view update, which is
    /// undefined behavior. This set prevents duplicate deferred requests.
    private var queuedGenerationIDs: Set<UUID> = []

    /// Clips holding a ticket for a decode slot, oldest first.
    ///
    /// A batch import asks for every clip's waveform at once - one drop of a
    /// feature's reels is a dozen requests in the same frame. Starting them all
    /// is what saturated the machine; these wait their turn instead.
    private var waitingClips: [AudioClip] = []

    /// Membership of `waitingClips`, for the lookups that would otherwise be a
    /// linear scan of it on every view evaluation.
    private var waitingClipIDs: Set<UUID> = []

    /// How many clips may decode at once.
    ///
    /// A quarter of the machine, never fewer than two. Decoding is bound by the
    /// disk as much as the CPU, so more readers past this point mostly queue
    /// against each other - and the whole point of the cap is to leave the
    /// machine with capacity for everything else the import is doing.
    private let maxConcurrentGenerations = max(2, ProcessInfo.processInfo.activeProcessorCount / 4)

    /// Where the blocking sample read runs.
    ///
    /// Not the cooperative pool. `copyNextSampleBuffer` has no suspension point
    /// in it, so a decode running as an ordinary `async` function holds its pool
    /// thread from the first sample to the last. Swift sizes that pool to the
    /// core count, so a batch import of more clips than cores took every thread
    /// in it and nothing else asynchronous in the app could run - audio clips
    /// could not load, thumbnails could not draw, extraction could not start -
    /// until the last waveform finished.
    ///
    /// A queue of its own keeps blocking work where blocking work belongs.
    private nonisolated static let decodeQueue = DispatchQueue(
        label: "com.projector.waveform-decode",
        qos: .utility,
        attributes: .concurrent
    )

    /// DSWaveformImage analyzer for legacy track-based mode.
    private let analyzer = WaveformAnalyzer()

    /// Predefined bucket counts for atlas resolution levels.
    ///
    /// These values represent the number of samples at each resolution level.
    /// Higher counts provide more detail for zoomed-in views.
    private let atlasBucketCounts: [Int] = [256, 512, 1024, 2048, 4096, 8192, 16384]

    /// A target width the atlas can actually satisfy.
    ///
    /// Callers size their request from a clip's zoomed width, which is unbounded: a reel
    /// at full zoom is hundreds of thousands of points across. Anything past the widest
    /// bucket resolves to that bucket regardless, so the excess buys nothing - and
    /// converting an unbounded `CGFloat` to `Int` traps outright if it is ever
    /// non-finite, which is a crash rather than a coarse waveform.
    ///
    /// - Parameter pointWidth: Width the caller would like, in points.
    /// - Returns: A usable bucket-sized target width, never below 1.
    func clampedTargetWidth(_ pointWidth: CGFloat) -> Int {
        guard pointWidth.isFinite, pointWidth > 1 else { return 1 }
        let ceiling = CGFloat(atlasBucketCounts.max() ?? 16384)
        return Int(min(pointWidth, ceiling))
    }

    /// Channel count that gets its sides drawn apart rather than summed.
    ///
    /// Only stereo. Beyond two channels there is no settled way to stack traces
    /// in a lane, so wider sources keep the single summed trace.
    fileprivate static let stereoChannelCount = 2

    /// Rate assumed when a track's format description cannot be read.
    fileprivate static let defaultSampleRate: Double = 48000

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
    /// Give a split clip the side of the stereo trace already drawn for it.
    ///
    /// A stereo clip's atlas holds each channel separately - it is what draws the
    /// two stacked traces on an unsplit video's lane - at every resolution and
    /// already normalized on a scale shared with the other side. That is exactly
    /// the trace the split clip needs, so splitting can hand it over rather than
    /// decode the audio again to arrive back at the same numbers.
    ///
    /// Without this a split costs two extra full decodes per reel to redraw what
    /// was on screen a moment earlier, which is most of the wait after answering
    /// the split question.
    ///
    /// - Parameters:
    ///   - sourceClipId: The stereo clip being split.
    ///   - channel: Side the new clip carries.
    ///   - newClipId: The split clip that should show that side.
    /// - Returns: `true` if per-channel data existed and was handed over. `false`
    ///   means the caller must let the clip generate its own, which happens when
    ///   the stereo trace had not finished drawing yet.
    @discardableResult
    func adoptChannel(from sourceClipId: UUID, channel: SplitChannel, as newClipId: UUID) -> Bool {
        guard let source = clipAtlases[sourceClipId],
              source.channelLevels.indices.contains(channel.channelIndex) else {
            return false
        }

        // The side becomes the clip's whole trace: a mono clip has no channels
        // of its own to keep apart.
        clipAtlases[newClipId] = WaveformAtlas(
            duration: source.duration,
            levels: source.channelLevels[channel.channelIndex]
        )
        return true
    }

    /// Store an atlas for a clip directly.
    ///
    /// Production code gets an atlas by generating one or by `adoptChannel`; this
    /// exists so tests can set up a clip that already has a trace without
    /// decoding audio to produce one.
    ///
    /// - Parameters:
    ///   - atlas: The atlas to store.
    ///   - clipId: Clip it belongs to.
    func setAtlasForTesting(_ atlas: WaveformAtlas, for clipId: UUID) {
        clipAtlases[clipId] = atlas
    }

    func renderData(for clip: AudioClip, targetWidth: Int) -> WaveformRenderData? {
        if let atlas = clipAtlases[clip.id] {
            let bucketCount = closestBucketCount(for: targetWidth)
            if let level = atlas.levels[bucketCount] {
                // Only offer channels when every one of them has this
                // resolution, so a partial atlas cannot draw one side.
                let channelLevels = atlas.channelLevels.compactMap { $0[bucketCount] }
                return WaveformRenderData(
                    duration: atlas.duration,
                    level: level,
                    channelLevels: channelLevels.count == atlas.channelLevels.count ? channelLevels : []
                )
            }
        }

        if generationTasks[clip.id] == nil,
           !queuedGenerationIDs.contains(clip.id),
           !waitingClipIDs.contains(clip.id) {
            queuedGenerationIDs.insert(clip.id)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.queuedGenerationIDs.remove(clip.id)
                guard self.clipAtlases[clip.id] == nil,
                      self.generationTasks[clip.id] == nil,
                      !self.waitingClipIDs.contains(clip.id) else { return }
                self.requestGeneration(for: clip)
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
    private func requestGeneration(for clip: AudioClip) {
        guard generationTasks.count < maxConcurrentGenerations else {
            guard waitingClipIDs.insert(clip.id).inserted else { return }
            waitingClips.append(clip)
            updateGeneratingState()
            return
        }
        startGeneration(for: clip)
    }

    /// Promotes the longest-waiting clip, if there is room and one is waiting.
    private func startNextWaitingGeneration() {
        guard generationTasks.count < maxConcurrentGenerations,
              !waitingClips.isEmpty else { return }
        let next = waitingClips.removeFirst()
        waitingClipIDs.remove(next.id)
        startGeneration(for: next)
    }

    private func startGeneration(for clip: AudioClip) {
        let clipId = clip.id
        let sps = samplesPerSecond
        let bucketCounts = atlasBucketCounts

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
                self.finishGeneration(for: clipId)
            }

            do {
                let atlas = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                try Task.checkCancellation()

                self.clipAtlases[clipId] = atlas
            } catch is CancellationError {
                // Cancellation is expected when clips are removed or caches reset.
            } catch {
                debugPrint("WaveformCache: Failed to generate waveform for clip \(clipId): \(error)")
            }
        }

        generationTasks[clipId] = task
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
        // A split clip must draw only its own side, never the stereo sum - that
        // is the whole point of splitting it.
        //
        // Its extracted mono file is the cheap way to get that, but the waveform
        // does not depend on it: if the file is not attached yet, or a reopened
        // project found it cleaned out of the temp directory, the channel is
        // isolated from the original source instead. Requiring the temp file
        // meant a split lane whose extraction had not landed drew nothing, and
        // nothing ever asked again.
        let url: URL
        let channelToIsolate: SplitChannel?
        if let channel = clip.sourceChannel {
            if let extracted = clip.extractedAudioURL,
               FileManager.default.fileExists(atPath: extracted.path) {
                url = extracted
                channelToIsolate = nil      // already a mono file of that side
            } else {
                url = clip.sourceURL
                channelToIsolate = channel
            }
        } else {
            url = clip.sourceURL
            channelToIsolate = nil
        }
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

        // Stereo sources are read a channel at a time so the sides can be drawn
        // apart; everything else takes the downmix it always did.
        let format = try await audioFormat(of: track)
        let channelsToRead = format.channels == stereoChannelCount ? stereoChannelCount : 1

        let rawChannels = try await samplesPerChannelUsingAssetReader(
            asset: asset,
            track: track,
            samplesPerSecond: effectiveSamplesPerSecond,
            durationSeconds: durationSeconds,
            channelCount: channelsToRead,
            sourceSampleRate: format.sampleRate
        )

        let alignedChannels = rawChannels.map {
            applyTrackOffset(
                samples: $0,
                expectedSamples: sampleCount,
                trackStartSeconds: trackStartSeconds,
                durationSeconds: durationSeconds
            )
        }

        // Isolating one side of a stereo source: keep that channel and drop the
        // other, so what remains is the same single trace the extracted mono
        // file would have produced.
        if let channelToIsolate,
           alignedChannels.indices.contains(channelToIsolate.channelIndex) {
            let isolated = normalize(samples: alignedChannels[channelToIsolate.channelIndex])
            let levels = buildLevels(from: isolated, bucketCounts: bucketCounts)
            return WaveformAtlas(duration: durationSeconds, levels: levels)
        }

        // One scale across every channel, so a quiet side stays visibly quieter.
        let normalizedChannels = normalize(channels: alignedChannels)

        guard normalizedChannels.count == stereoChannelCount else {
            let levels = buildLevels(from: normalizedChannels.first ?? [], bucketCounts: bucketCounts)
            return WaveformAtlas(duration: durationSeconds, levels: levels)
        }

        // The summed trace stays the fallback for short lanes and for any
        // renderer that does not know about channels.
        let summed = zip(normalizedChannels[0], normalizedChannels[1]).map { ($0 + $1) * 0.5 }
        let levels = buildLevels(from: summed, bucketCounts: bucketCounts)

        let channelLevels = sharedScaleLevels(
            channels: normalizedChannels,
            bucketCounts: bucketCounts
        )

        return WaveformAtlas(
            duration: durationSeconds,
            levels: levels,
            channelLevels: channelLevels
        )
    }

    /// Channel count and sample rate of a track.
    ///
    /// Loaded once and passed down: the reader needs the rate and the atlas
    /// needs the channel count, and `load(.formatDescriptions)` is an async
    /// round trip worth not doing twice per clip.
    ///
    /// - Returns: The track's format, or a zero channel count and a 48 kHz
    ///   assumption when the description cannot be read.
    private nonisolated static func audioFormat(
        of track: AVAssetTrack
    ) async throws -> (channels: Int, sampleRate: Double) {
        guard let description = try await track.load(.formatDescriptions).first,
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description) else {
            return (0, defaultSampleRate)
        }
        return (Int(basic.pointee.mChannelsPerFrame), basic.pointee.mSampleRate)
    }

    /// Build per-channel levels that share one floor and peak per resolution.
    ///
    /// Without this each channel would be normalized against itself, which
    /// makes every channel fill its half of the lane no matter how quiet it
    /// really is - and a hard-panned file, the case this display exists to
    /// reveal, would look exactly like a centred one.
    private nonisolated static func sharedScaleLevels(
        channels: [[Float]],
        bucketCounts: [Int]
    ) -> [[Int: WaveformLevel]] {
        var perChannel = channels.map { buildLevels(from: $0, bucketCounts: bucketCounts) }

        for bucketCount in bucketCounts {
            let levels = perChannel.compactMap { $0[bucketCount] }
            guard levels.count == perChannel.count else { continue }

            let floor = levels.map(\.rmsFloor).min() ?? 0
            let peak = levels.map(\.rmsPeak).max() ?? 0

            for index in perChannel.indices {
                perChannel[index][bucketCount] = perChannel[index][bucketCount]?
                    .rescaled(floor: floor, peak: peak)
            }
        }

        return perChannel
    }

    /// Reads peak samples for each channel of a track.
    ///
    /// Asking for one channel lets CoreAudio downmix, which is what a single
    /// summed trace wants. Asking for two keeps the sides apart, which is the
    /// only way a waveform can show that a file is hard panned - a downmix adds
    /// the two together and the distinction is gone before drawing starts.
    ///
    /// ## Why this is vectorized
    ///
    /// This loop sees every sample in the file: a 90-minute reel read at 8 kHz
    /// stereo is ~86 million of them. Walking that a frame at a time, tracking
    /// each channel's peak in an array, made reading two channels several times
    /// the cost of the old one-channel scalar loop rather than twice it - the
    /// per-element bounds and uniqueness checks dominated the actual work.
    ///
    /// Instead each block is converted to float once (`vDSP_vflt16`) and each
    /// bucket's peak is taken with a strided `vDSP_maxmgv`, one call per channel
    /// per bucket. The stride is what keeps the channels apart without
    /// deinterleaving into scratch buffers first.
    ///
    /// - Parameters:
    ///   - asset: The asset to read from
    ///   - track: The audio track to process
    ///   - samplesPerSecond: Target output sample density
    ///   - durationSeconds: Duration, for capacity estimation
    ///   - channelCount: Channels to keep separate
    ///   - sourceSampleRate: The track's own rate, already loaded by the caller
    /// - Returns: One array of normalized peaks per channel
    /// - Throws: `WaveformCacheError.failedToStartReading` if the reader fails
    private nonisolated static func samplesPerChannelUsingAssetReader(
        asset: AVAsset,
        track: AVAssetTrack,
        samplesPerSecond: Int,
        durationSeconds: Double,
        channelCount: Int,
        sourceSampleRate: Double
    ) async throws -> [[Float]] {
        // Onto `decodeQueue`, and cancellable once it is there. The read itself
        // never suspends, so leaving it on the caller's cooperative thread holds
        // that thread from the first sample to the last - see `decodeQueue`.
        let cancellation = DecodeCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                decodeQueue.async {
                    do {
                        continuation.resume(returning: try readSamplesPerChannel(
                            asset: asset,
                            track: track,
                            samplesPerSecond: samplesPerSecond,
                            durationSeconds: durationSeconds,
                            channelCount: channelCount,
                            sourceSampleRate: sourceSampleRate,
                            cancellation: cancellation
                        ))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// The blocking read itself. Runs on `decodeQueue`, never on the pool.
    ///
    /// - Parameter cancellation: Polled between blocks, so a clip removed from
    ///   the timeline stops decoding rather than reading a whole reel into a
    ///   cache nothing will look at.
    /// - Throws: `CancellationError` if cancelled part way through the file.
    private nonisolated static func readSamplesPerChannel(
        asset: AVAsset,
        track: AVAssetTrack,
        samplesPerSecond: Int,
        durationSeconds: Double,
        channelCount: Int,
        sourceSampleRate: Double,
        cancellation: DecodeCancellation
    ) throws -> [[Float]] {
        let channels = max(1, channelCount)
        let reader = try AVAssetReader(asset: asset)
        let expectedSamples = Int(durationSeconds * Double(samplesPerSecond))
        var samples = [[Float]](repeating: [], count: channels)
        for index in samples.indices {
            samples[index].reserveCapacity(expectedSamples)
        }

        let targetSampleRate = min(sourceSampleRate, max(8000, Double(samplesPerSecond) * 20))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: channels,
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

        let framesPerBucket = max(1, Int(targetSampleRate) / samplesPerSecond)
        let int16Scale: Float = 1.0 / 32768.0

        /// Float copy of the current block. Reused across blocks, which are
        /// uniformly sized in practice, so this allocates once.
        var scratch: [Float] = []

        /// Peak so far for the bucket in progress. Buckets straddle block
        /// boundaries, so this has to outlive one iteration.
        var bucketPeaks = [Float](repeating: 0, count: channels)
        var framesInBucket = 0

        while let sampleBuffer = output.copyNextSampleBuffer() {
            // Once per block, which on a feature-length reel is often enough to
            // stop within a few milliseconds of the ask and rare enough that the
            // lock never shows up in the profile.
            if cancellation.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }

            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }

            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &length,
                dataPointerOut: &dataPointer
            ) == kCMBlockBufferNoErr, let data = dataPointer else { continue }

            let sampleCount = length / MemoryLayout<Int16>.size
            let frameCount = sampleCount / channels
            guard frameCount > 0 else { continue }

            if scratch.count < sampleCount {
                scratch = [Float](repeating: 0, count: sampleCount)
            }

            data.withMemoryRebound(to: Int16.self, capacity: sampleCount) { source in
                scratch.withUnsafeMutableBufferPointer { floats in
                    guard let base = floats.baseAddress else { return }
                    vDSP_vflt16(source, 1, base, 1, vDSP_Length(sampleCount))

                    var frameIndex = 0
                    while frameIndex < frameCount {
                        // Never crosses a bucket boundary, so one vDSP call
                        // covers a whole run and the boundary work stays cold.
                        let framesTaken = min(
                            framesPerBucket - framesInBucket,
                            frameCount - frameIndex
                        )

                        for channel in 0..<channels {
                            var peak: Float = 0
                            vDSP_maxmgv(
                                base + frameIndex * channels + channel,
                                channels,
                                &peak,
                                vDSP_Length(framesTaken)
                            )
                            bucketPeaks[channel] = Swift.max(bucketPeaks[channel], peak)
                        }

                        frameIndex += framesTaken
                        framesInBucket += framesTaken

                        if framesInBucket >= framesPerBucket {
                            for channel in 0..<channels {
                                samples[channel].append(min(1.0, bucketPeaks[channel] * int16Scale))
                                bucketPeaks[channel] = 0
                            }
                            framesInBucket = 0
                        }
                    }
                }
            }
        }

        if framesInBucket > 0 {
            for channel in 0..<channels {
                samples[channel].append(min(1.0, bucketPeaks[channel] * int16Scale))
            }
        }

        reader.cancelReading()

        return samples
    }

    /// Returns whether waveform generation is in progress for a clip.
    ///
    /// - Parameter clip: The audio clip to check
    /// - Returns: `true` if a generation task is running, `false` otherwise
    func isLoading(for clip: AudioClip) -> Bool {
        generationTasks[clip.id] != nil
            || queuedGenerationIDs.contains(clip.id)
            || waitingClipIDs.contains(clip.id)
    }

    /// Cancels any pending waveform generation for a clip.
    ///
    /// - Parameter clipId: The UUID of the clip to cancel
    func cancelGeneration(for clipId: UUID) {
        queuedGenerationIDs.remove(clipId)
        if waitingClipIDs.remove(clipId) != nil {
            waitingClips.removeAll { $0.id == clipId }
            updateGeneratingState()
        }
        if let task = generationTasks[clipId] {
            task.cancel()
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

    /// Republishes the pending count and the generating flag from the work
    /// actually outstanding, decoding and waiting alike.
    ///
    /// Derived rather than counted up and down by hand: a clip that is promoted
    /// from waiting to decoding moves between the two collections without the
    /// total changing, and a hand-kept tally has to know that.
    private func updateGeneratingState() {
        pendingCount = generationTasks.count + waitingClips.count
        isGenerating = pendingCount > 0
    }

    /// Completes one tracked generation exactly once, and starts the next.
    private func finishGeneration(for clipId: UUID) {
        guard generationTasks.removeValue(forKey: clipId) != nil else { return }
        startNextWaitingGeneration()
        updateGeneratingState()
    }

    /// Clears all cached waveforms and cancels pending tasks.
    ///
    /// Removes both clip-based and legacy track-based waveforms.
    func clearAll() {
        // Cancel all pending tasks
        for task in generationTasks.values {
            task.cancel()
        }
        generationTasks.removeAll()
        queuedGenerationIDs.removeAll()
        waitingClips.removeAll()
        waitingClipIDs.removeAll()
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
        for task in generationTasks.values {
            task.cancel()
        }
        generationTasks.removeAll()
        queuedGenerationIDs.removeAll()
        waitingClips.removeAll()
        waitingClipIDs.removeAll()

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
        scaled(samples, by: peakMagnitude(of: samples))
    }

    /// Normalize several channels against their common peak.
    ///
    /// Scaling each channel by its own peak would erase the level difference
    /// between them, which is the whole point of drawing them separately.
    private nonisolated static func normalize(channels: [[Float]]) -> [[Float]] {
        let peak = channels.map { peakMagnitude(of: $0) }.max() ?? 0
        return channels.map { scaled($0, by: peak) }
    }

    /// Largest absolute value in a buffer, without copying it first.
    ///
    /// The obvious `samples.map(abs).max()` allocates a second copy of every
    /// channel purely to throw it away, on arrays that run to six figures.
    private nonisolated static func peakMagnitude(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var peak: Float = 0
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            vDSP_maxmgv(base, 1, &peak, vDSP_Length(buffer.count))
        }
        return peak
    }

    /// Absolute values of `samples` scaled so `peak` maps to 1.
    ///
    /// A peak of zero means silence, which stays silent rather than being
    /// divided by nothing.
    private nonisolated static func scaled(_ samples: [Float], by peak: Float) -> [Float] {
        guard !samples.isEmpty else { return samples }
        var output = [Float](repeating: 0, count: samples.count)
        output.withUnsafeMutableBufferPointer { destination in
            guard let target = destination.baseAddress else { return }
            samples.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                vDSP_vabs(base, 1, target, 1, vDSP_Length(buffer.count))
            }
            guard peak > 0 else { return }
            var scale = 1.0 / peak
            vDSP_vsmul(target, 1, &scale, target, 1, vDSP_Length(destination.count))
        }
        return output
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
    private nonisolated static func buildLevels(from samples: [Float], bucketCounts: [Int]) -> [Int: WaveformLevel] {
        var levels: [Int: WaveformLevel] = [:]
        for bucketCount in bucketCounts {
            levels[bucketCount] = buildLevel(samples: samples, bucketCount: bucketCount)
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

// MARK: - Decode Cancellation

/// A cancellation signal that can be read from the decode queue.
///
/// `Task.isCancelled` is a property of the task, and the read it guards has been
/// handed to a dispatch queue precisely so that it is not running as a task any
/// more. This carries the signal across that boundary.
private final class DecodeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
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
