import Foundation
import Accelerate

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
    /// Waveform levels keyed by bucket count, summed to one trace.
    let levels: [Int: WaveformLevel]

    /// Per-channel levels, outer index being the channel.
    ///
    /// Empty for mono sources and for anything generated before stereo
    /// analysis existed, so a renderer must treat it as an enhancement and
    /// fall back to `levels`.
    let channelLevels: [[Int: WaveformLevel]]

    init(
        duration: Double,
        levels: [Int: WaveformLevel],
        channelLevels: [[Int: WaveformLevel]] = []
    ) {
        self.duration = duration
        self.levels = levels
        self.channelLevels = channelLevels
    }
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

        let scaling = Self.scaling(for: rms)
        rmsFloor = scaling.floor
        rmsPeak = scaling.peak
    }

    /// Build a level with a scale taken from somewhere other than its own data.
    ///
    /// Needed for multi-channel display. A level normally derives its floor and
    /// peak from its own samples, which is right for a lone trace but wrong for
    /// a pair: normalized separately, a hard-panned file draws both sides at
    /// full height and the panning it is meant to reveal disappears. Channels
    /// drawn together must share one scale.
    init(min: [Float], max: [Float], rms: [Float], rmsFloor: Float, rmsPeak: Float) {
        self.min = min
        self.max = max
        self.rms = rms
        self.rmsFloor = rmsFloor
        self.rmsPeak = rmsPeak
    }

    /// Floor and peak that would be derived from a set of RMS values.
    ///
    /// The floor is the 10th percentile rather than the minimum, so a moment of
    /// digital silence does not drag the whole trace's contrast down.
    ///
    /// ## Why this does not sort
    ///
    /// This runs on the render path: every clip re-derives it for the slice of
    /// waveform it is currently showing, on every view update, and a stereo clip
    /// does it once per channel. Fully sorting up to 16384 values to read a
    /// single element out of the result was the most expensive thing a waveform
    /// did while scrolling or zooming.
    ///
    /// Only two of the sorted values are ever wanted, so only those are
    /// computed - the percentile by partial selection and the peak by a
    /// vectorized maximum. The results are identical to sorting.
    static func scaling(for rms: [Float]) -> (floor: Float, peak: Float) {
        guard !rms.isEmpty else { return (0, 0) }

        let floorIndex = Swift.max(
            0,
            Swift.min(rms.count - 1, Int(Double(rms.count - 1) * 0.1))
        )

        var scratch = rms
        let floor = scratch.withUnsafeMutableBufferPointer { buffer in
            Self.selectInPlace(buffer, index: floorIndex)
        }

        var peak: Float = 0
        rms.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            vDSP_maxv(base, 1, &peak, vDSP_Length(buffer.count))
        }

        return (floor, peak)
    }

    /// The value that would sit at `index` if `buffer` were sorted ascending.
    ///
    /// Quickselect. Reorders `buffer` as a side effect, so it is only ever
    /// handed a scratch copy.
    ///
    /// - Parameters:
    ///   - buffer: Values to select from. Must not be empty.
    ///   - index: Position in the sorted ordering. Must be in bounds.
    /// - Returns: The element at that position.
    private static func selectInPlace(
        _ buffer: UnsafeMutableBufferPointer<Float>,
        index: Int
    ) -> Float {
        var low = 0
        var high = buffer.count - 1

        while low < high {
            let pivot = buffer[(low + high) / 2]
            var i = low
            var j = high

            while i <= j {
                while buffer[i] < pivot { i += 1 }
                while buffer[j] > pivot { j -= 1 }
                if i <= j {
                    buffer.swapAt(i, j)
                    i += 1
                    j -= 1
                }
            }

            // The wanted index has been narrowed to one side of the partition,
            // or landed in the middle where it is already final.
            if index <= j {
                high = j
            } else if index >= i {
                low = i
            } else {
                return buffer[index]
            }
        }

        return buffer[index]
    }

    /// Copy of this level rescaled against a shared floor and peak.
    func rescaled(floor: Float, peak: Float) -> WaveformLevel {
        WaveformLevel(min: min, max: max, rms: rms, rmsFloor: floor, rmsPeak: peak)
    }

    /// Bucket count for this level.
    var count: Int {
        min.count
    }
}

/// Render-time waveform payload.
struct WaveformRenderData: Sendable {
    let duration: Double

    /// The summed trace, always present.
    let level: WaveformLevel

    /// One level per channel, already sharing a scale so their heights are
    /// comparable. Empty when the source is mono.
    let channelLevels: [WaveformLevel]

    init(duration: Double, level: WaveformLevel, channelLevels: [WaveformLevel] = []) {
        self.duration = duration
        self.level = level
        self.channelLevels = channelLevels
    }

    /// Whether there are distinct channels worth drawing separately.
    var isStereo: Bool { channelLevels.count >= 2 }
}
