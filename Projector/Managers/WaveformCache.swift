import Foundation
import AVFoundation
import DSWaveformImage

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
    /// 200 samples/sec provides good visual detail for typical zoom levels
    var samplesPerSecond: Int = 200

    // MARK: - Private State

    /// Generation tasks in progress
    private var generationTasks: [UUID: Task<Void, Never>] = [:]

    /// Shared waveform analyzer instance
    private let analyzer = WaveformAnalyzer()

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
        let sps = samplesPerSecond

        pendingCount += 1

        let task = Task {
            do {
                let waveform = try await Self.generateWaveformForClip(
                    url: url,
                    clipId: clipId,
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

    /// Generate waveform for a specific clip using DSWaveformImage
    private nonisolated static func generateWaveformForClip(
        url: URL,
        clipId: UUID,
        samplesPerSecond: Int
    ) async throws -> WaveformData {
        let asset = AVAsset(url: url)
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)

        // Calculate number of samples based on duration
        let sampleCount = max(10, Int(durationSeconds * Double(samplesPerSecond)))

        // Use DSWaveformImage's analyzer to get samples
        let analyzer = WaveformAnalyzer()
        let samples = try await analyzer.samples(fromAudioAt: url, count: sampleCount)

        return WaveformData(
            trackIndex: clipId.hashValue,
            samples: samples,
            samplesPerSecond: samplesPerSecond,
            duration: durationSeconds
        )
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
