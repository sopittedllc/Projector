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
    /// RMS noise floor for this level (used to gate silence).
    let rmsFloor: Float
    /// RMS peak for this level (used for normalization).
    let rmsPeak: Float

    init(min: [Float], max: [Float], rms: [Float]) {
        self.min = min
        self.max = max
        self.rms = rms

        guard !rms.isEmpty else {
            rmsFloor = 0
            rmsPeak = 0
            return
        }

        var sortedValues = rms
        sortedValues.sort()
        let floorIndex = Swift.max(
            0,
            Swift.min(sortedValues.count - 1, Int(Double(sortedValues.count - 1) * 0.1))
        )
        rmsFloor = sortedValues[floorIndex]
        rmsPeak = sortedValues.last ?? 0
    }

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
