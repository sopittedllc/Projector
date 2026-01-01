import Foundation
import AVFoundation
import Accelerate

/// Generates waveform data from audio tracks for visualization
@MainActor
final class WaveformGenerator: ObservableObject {
    // MARK: - Published Properties

    /// Generated waveforms keyed by track index
    @Published private(set) var waveforms: [Int: WaveformData] = [:]

    /// Whether waveform generation is in progress
    @Published private(set) var isGenerating = false

    /// Progress of current generation (0...1)
    @Published private(set) var progress: Double = 0

    // MARK: - Configuration

    /// Samples per second for the waveform (higher = more detail, more memory)
    var samplesPerSecond: Int = 100

    // MARK: - Public Methods

    /// Generate waveforms for all audio tracks in an asset
    func generateWaveforms(from url: URL) async throws {
        isGenerating = true
        progress = 0
        waveforms.removeAll()

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
                // Run heavy waveform generation off the main thread
                let waveform = try await Task.detached(priority: .userInitiated) {
                    try await Self.generateWaveformOffMain(
                        for: asset,
                        track: track,
                        trackIndex: index,
                        samplesPerSecond: sps
                    )
                }.value
                waveforms[index] = waveform
            } catch {
                print("Failed to generate waveform for track \(index): \(error)")
            }

            progress = Double(index + 1) * trackProgress
        }

        isGenerating = false
        progress = 1.0
    }

    /// Generate waveform for a specific audio track (runs off main thread)
    private nonisolated static func generateWaveformOffMain(
        for asset: AVAsset,
        track: AVAssetTrack,
        trackIndex: Int,
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
            throw WaveformGeneratorError.failedToStartReading
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
                    // Calculate RMS or peak
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
            trackIndex: trackIndex,
            samples: samples,
            samplesPerSecond: samplesPerSecond,
            duration: durationSeconds
        )
    }

    /// Clear all cached waveforms
    func clearWaveforms() {
        waveforms.removeAll()
    }
}

// MARK: - Errors

enum WaveformGeneratorError: LocalizedError {
    case failedToStartReading
    case noAudioTracks

    var errorDescription: String? {
        switch self {
        case .failedToStartReading:
            return "Failed to start reading audio samples."
        case .noAudioTracks:
            return "No audio tracks found in the video."
        }
    }
}
