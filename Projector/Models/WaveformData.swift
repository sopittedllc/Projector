import Foundation

/// Cached waveform samples for visualization
struct WaveformData {
    /// Track index this waveform belongs to
    let trackIndex: Int

    /// Normalized amplitude samples (0...1 range)
    let samples: [Float]

    /// Number of samples per second (resolution)
    let samplesPerSecond: Int

    /// Duration of the audio in seconds
    let duration: Double

    /// Total number of samples
    var sampleCount: Int {
        samples.count
    }

    init(
        trackIndex: Int,
        samples: [Float],
        samplesPerSecond: Int = 100,
        duration: Double
    ) {
        self.trackIndex = trackIndex
        self.samples = samples
        self.samplesPerSecond = samplesPerSecond
        self.duration = duration
    }

    /// Get the sample index for a given time in seconds
    func sampleIndex(at time: Double) -> Int {
        let index = Int(time * Double(samplesPerSecond))
        return max(0, min(index, samples.count - 1))
    }

    /// Get samples for a time range
    func samples(from startTime: Double, to endTime: Double) -> ArraySlice<Float> {
        let startIndex = sampleIndex(at: startTime)
        let endIndex = sampleIndex(at: endTime)
        return samples[startIndex...endIndex]
    }
}

// MARK: - Empty Waveform

extension WaveformData {
    /// Create an empty waveform placeholder
    static func empty(trackIndex: Int, duration: Double) -> WaveformData {
        WaveformData(
            trackIndex: trackIndex,
            samples: [],
            samplesPerSecond: 100,
            duration: duration
        )
    }
}

// MARK: - Waveform Atlas

/// Multi-resolution waveform data for fast rendering.
struct WaveformAtlas: Sendable {
    /// Duration of the source audio in seconds.
    let duration: Double
    /// Waveform levels keyed by bucket count.
    let levels: [Int: WaveformLevel]
}

/// A single resolution level of waveform data.
struct WaveformLevel: Sendable {
    /// Minimum sample per bucket.
    let min: [Float]
    /// Maximum sample per bucket.
    let max: [Float]
    /// RMS sample per bucket.
    let rms: [Float]

    /// Bucket count for this level.
    var count: Int {
        min.count
    }
}

/// Render-time waveform payload.
struct WaveformRenderData: Sendable {
    let duration: Double
    let level: WaveformLevel
}
