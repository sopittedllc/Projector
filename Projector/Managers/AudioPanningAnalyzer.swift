import Foundation
import AVFoundation
import Accelerate

// MARK: - Split Channel

/// One side of a hard-panned stereo pair.
///
/// Stored on lanes and clips so a split survives a save, and so extraction and
/// waveform analysis both know which half of the source they are looking at.
public enum SplitChannel: String, Codable, Sendable, Hashable, CaseIterable {
    case left
    case right

    /// Zero-based index into an interleaved stereo frame.
    public var channelIndex: Int {
        switch self {
        case .left:  return 0
        case .right: return 1
        }
    }

    /// How the side is described to the user.
    public var displayName: String {
        switch self {
        case .left:  return "Left"
        case .right: return "Right"
        }
    }

    /// The role this side conventionally carries in a split track.
    ///
    /// The post convention is dialogue and effects left, music right. This is
    /// only a default for naming and routing - the user can re-point either
    /// lane afterwards.
    public var conventionalRoleName: String {
        switch self {
        case .left:  return "DX/SFX"
        case .right: return "MX"
        }
    }

    /// Identifier of the output role this side belongs on.
    ///
    /// Must match `OutputRole.id` in the settings UI. Duplicated as a literal
    /// rather than shared, because that type lives in the presentation layer and
    /// this one may not reach into it.
    ///
    /// Used to send each half of a split to the output configured for its role,
    /// so the two do not both land on whichever output happened to match first.
    public var conventionalRoleId: String {
        switch self {
        case .left:  return "dx-sfx"
        case .right: return "mx"
        }
    }
}

// MARK: - Panning Analysis

/// What the analyzer concluded about a file's stereo content.
public struct PanningAnalysis: Sendable, Equatable {
    /// Pearson correlation between the two channels, -1...1.
    ///
    /// Near 1 means the channels carry the same signal (mono in stereo), the
    /// mid range means an ordinary stereo image, and near 0 means the two sides
    /// are unrelated - which is what a split track is.
    public let correlation: Float

    /// RMS level of each channel, 0...1.
    public let leftRMS: Float
    public let rightRMS: Float

    /// Whether this looks like two unrelated mono signals sharing a file.
    public let isHardPanned: Bool
}

// MARK: - AudioPanningAnalyzer

/// Decides whether a stereo file is really two unrelated mono signals.
///
/// A "split track" is a common post deliverable: dialogue and effects hard
/// panned left, music hard panned right, so a single stereo file carries two
/// stems. Played normally it sounds broken - everything is on one side or the
/// other - and a single summed waveform hides the fact entirely.
///
/// ## How the decision is made
///
/// The test is the correlation between the two channels, not their difference.
/// Difference alone is useless: every stereo mix ever made has L != R. What
/// separates a split track is that the two sides are *unrelated* - a dialogue
/// stem and a music cue share no waveform - where a stereo mix of one
/// performance keeps the channels strongly correlated.
///
/// | Content                | Correlation | Verdict     |
/// |------------------------|-------------|-------------|
/// | Mono in a stereo file  | ~1.0        | not split   |
/// | Ordinary stereo mix    | ~0.4 - 0.95 | not split   |
/// | Hard-panned split      | ~0.0        | **split**   |
/// | One side silent        | ~0.0        | **split**   |
///
/// A reel with one dead side counts as a split. It is not a deliverable anyone
/// intended - it means the edit was exported wrong - and splitting it is how
/// the user finds out, because the empty lane draws as a flat line beside a
/// full one. Declining to offer would hide the defect behind a reel that just
/// sounds one-sided for no visible reason.
///
/// A file silent on *both* sides is rejected: it correlates with nothing and
/// would read as a perfect split, but there is nothing there to separate.
///
/// ## Why the verdict is acted on, and why it is still cautious
///
/// A hard-panned reel plays with everything on one side or the other, which is
/// broken however it got that way, so a split is applied on import rather than
/// offered. The question only ever had one sensible answer, and asking it put a
/// dialog between the user and a timeline that already worked.
///
/// A heavily decorrelated wide stereo mix can nonetheless measure like a split
/// track, and no threshold makes that ambiguity go away. Two things keep acting
/// on it safe: the correlation bar stays deliberately low, so the test is biased
/// towards saying no, and the caller registers the whole import as one undo - a
/// reel split against the user's wishes costs a Cmd-Z, not a rebuilt timeline.
///
/// ## Thread Safety
///
/// Stateless and `nonisolated`; call it from any context. Analysis runs off the
/// main thread.
enum AudioPanningAnalyzer {

    // MARK: - Constants

    private enum Thresholds {
        /// Below this correlation the channels count as unrelated.
        ///
        /// Deliberately low. A false positive restructures the timeline, a
        /// false negative just leaves the file as one stereo lane, so the test
        /// is biased towards saying no.
        static let maximumSplitCorrelation: Float = 0.2

        /// A channel at or above this RMS carries signal, ~-60 dBFS.
        ///
        /// Only one side has to clear it. The bar exists to reject a file that
        /// is silent throughout, not to veto a legitimate split that happens to
        /// have a dead channel - see the type's documentation for why a
        /// one-sided reel is worth surfacing rather than hiding.
        static let minimumChannelRMS: Float = 0.001
    }

    private enum Analysis {
        /// Sample rate used for the read. Correlation is a gross statistic and
        /// does not need full bandwidth; this keeps a long reel quick.
        static let sampleRate: Double = 22050

        /// Channels required before a split is even possible.
        static let stereoChannelCount = 2

        /// Most audio to read before deciding, in seconds.
        ///
        /// Correlation between two stems is a property of the whole reel, not of
        /// any moment in it, so a few minutes answers the question as well as
        /// twelve do. Reading everything meant a full decode of the source on
        /// every video import - the single slowest thing the import did.
        static let maximumAnalysisSeconds: Double = 180

        /// Where a bounded read starts, as a fraction of the file.
        ///
        /// Taken from the middle rather than the head: reels commonly open on
        /// black with silence or room tone, which correlates with nothing and
        /// would read as a split.
        static let analysisStartFraction = 0.25
    }

    // MARK: - API

    /// Analyze the first audio track of an asset for hard panning.
    ///
    /// - Parameter url: File to inspect. May be a video container.
    /// - Returns: The analysis, or `nil` when the file has no audio track or
    ///   the track is not stereo - neither is an error, just nothing to split.
    /// - Throws: `PanningAnalyzerError.readerFailed` if the asset cannot be read.
    static func analyze(url: URL) async throws -> PanningAnalysis? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            return nil
        }
        return try await analyze(asset: asset, track: track)
    }

    /// Analyze a specific audio track.
    ///
    /// - Parameters:
    ///   - asset: Asset owning the track.
    ///   - track: The audio track to inspect.
    /// - Returns: The analysis, or `nil` if the track is not stereo.
    /// - Throws: `PanningAnalyzerError.readerFailed` if reading cannot start.
    static func analyze(asset: AVAsset, track: AVAssetTrack) async throws -> PanningAnalysis? {
        guard try await channelCount(of: track) == Analysis.stereoChannelCount else {
            return nil
        }

        let reader = try AVAssetReader(asset: asset)

        // Bound the read to a representative slice from the middle of the reel.
        let assetDuration = CMTimeGetSeconds(try await asset.load(.duration))
        if assetDuration > Analysis.maximumAnalysisSeconds {
            let start = (assetDuration - Analysis.maximumAnalysisSeconds) * Analysis.analysisStartFraction
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600),
                duration: CMTime(seconds: Analysis.maximumAnalysisSeconds, preferredTimescale: 600)
            )
        }

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Analysis.sampleRate,
            AVNumberOfChannelsKey: Analysis.stereoChannelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)

        guard reader.startReading() else {
            throw PanningAnalyzerError.readerFailed(reader.error)
        }

        // Accumulated in double precision: a feature-length reel is hundreds of
        // millions of samples, and Float sums drift badly at that length.
        var sumLeftSquared = 0.0
        var sumRightSquared = 0.0
        var sumProduct = 0.0
        var frameCount = 0.0

        while let buffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(buffer) else { continue }

            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &length,
                dataPointerOut: &pointer
            ) == kCMBlockBufferNoErr, let pointer else { continue }

            pointer.withMemoryRebound(to: Float.self, capacity: length / MemoryLayout<Float>.size) { samples in
                let frames = (length / MemoryLayout<Float>.size) / Analysis.stereoChannelCount
                guard frames > 0 else { return }

                // Deinterleave into planar buffers so vDSP can work on each
                // side. An interleaved L/R pair has the same memory layout as a
                // complex real/imaginary pair, which is what `vDSP_ctoz` splits.
                var left = [Float](repeating: 0, count: frames)
                var right = [Float](repeating: 0, count: frames)
                var leftEnergy: Float = 0
                var rightEnergy: Float = 0
                var product: Float = 0

                left.withUnsafeMutableBufferPointer { leftBuffer in
                    right.withUnsafeMutableBufferPointer { rightBuffer in
                        var split = DSPSplitComplex(
                            realp: leftBuffer.baseAddress!,
                            imagp: rightBuffer.baseAddress!
                        )
                        samples.withMemoryRebound(to: DSPComplex.self, capacity: frames) { pairs in
                            vDSP_ctoz(pairs, 2, &split, 1, vDSP_Length(frames))
                        }

                        vDSP_dotpr(split.realp, 1, split.realp, 1, &leftEnergy, vDSP_Length(frames))
                        vDSP_dotpr(split.imagp, 1, split.imagp, 1, &rightEnergy, vDSP_Length(frames))
                        vDSP_dotpr(split.realp, 1, split.imagp, 1, &product, vDSP_Length(frames))
                    }
                }

                sumLeftSquared += Double(leftEnergy)
                sumRightSquared += Double(rightEnergy)
                sumProduct += Double(product)
                frameCount += Double(frames)
            }
        }

        if reader.status == .failed {
            throw PanningAnalyzerError.readerFailed(reader.error)
        }
        guard frameCount > 0 else { return nil }

        let leftRMS = Float((sumLeftSquared / frameCount).squareRoot())
        let rightRMS = Float((sumRightSquared / frameCount).squareRoot())

        // Audio is zero-mean, so the dot product over sqrt of the energies is
        // the Pearson correlation without a separate mean-removal pass.
        let denominator = (sumLeftSquared * sumRightSquared).squareRoot()
        let correlation = denominator > 0 ? Float(sumProduct / denominator) : 0

        // One live side is enough. A dead channel still splits, because the
        // resulting flat lane is the point - it shows the user the reel was
        // exported wrong. Only a file silent on both sides is rejected.
        let hasSignal = leftRMS >= Thresholds.minimumChannelRMS
            || rightRMS >= Thresholds.minimumChannelRMS

        return PanningAnalysis(
            correlation: correlation,
            leftRMS: leftRMS,
            rightRMS: rightRMS,
            isHardPanned: hasSignal && abs(correlation) < Thresholds.maximumSplitCorrelation
        )
    }

    // MARK: - Helpers

    private static func channelCount(of track: AVAssetTrack) async throws -> Int {
        guard let description = try await track.load(.formatDescriptions).first,
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description) else {
            return 0
        }
        return Int(basic.pointee.mChannelsPerFrame)
    }
}

// MARK: - Errors

enum PanningAnalyzerError: LocalizedError {
    case readerFailed(Error?)

    var errorDescription: String? {
        switch self {
        case .readerFailed(let underlying):
            return "Couldn't read the audio track to check for hard panning."
                + (underlying.map { " \($0.localizedDescription)" } ?? "")
        }
    }
}
