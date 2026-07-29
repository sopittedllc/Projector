//
//  CueListExportService.swift
//  Projector
//
//  Actor-based service for detecting audio cues and exporting to CSV.
//  Logic Layer - NO SwiftUI imports allowed.
//

import Foundation
import AVFoundation

// MARK: - Cue List Export Service

/// Actor that detects audio cues from silence gaps and exports to CSV.
///
/// Uses high-resolution RMS analysis to identify silence regions in audio clips,
/// then inverts those to find cue regions (audio activity between silences).
///
/// ## Usage
///
/// ```swift
/// let service = CueListExportService()
/// let cues = try await service.detectCues(
///     in: timelineManager.timeline.audioLanes,
///     frameRate: timelineManager.timeline.config.frameRate.fps,
///     startTimecodeFrames: timelineManager.timeline.config.startTimecode.frameCount.wholeFrames,
///     config: .default
/// )
/// try await service.exportToCSV(cues: cues, to: saveURL)
/// ```
public actor CueListExportService: CueListExportServiceProtocol {

    // MARK: - Constants

    /// Number of RMS samples to analyze per second of audio.
    /// Higher values provide finer silence detection but use more memory.
    private let samplesPerSecond: Int = 100

    // MARK: - Initialization

    public init() {}

    // MARK: - Protocol Methods

    public func detectCues(
        in lanes: [AudioLane],
        frameRate: Double,
        startTimecodeFrames: Int,
        config: SilenceDetectionConfig
    ) async throws -> [DetectedCue] {
        // Find MX lane (case-insensitive)
        guard let mxLane = lanes.first(where: { $0.name.lowercased() == "mx" }) else {
            throw CueListExportError.noMXLane
        }

        guard !mxLane.clips.isEmpty else {
            throw CueListExportError.emptyMXLane
        }

        // Collect cues from all clips in the MX lane
        var allCues: [DetectedCue] = []
        var cueNumber = 1

        for clip in mxLane.clips.sorted(by: { $0.timelineStartFrame < $1.timelineStartFrame }) {
            let clipCues = try await detectCuesInClip(
                clip,
                frameRate: frameRate,
                startTimecodeFrames: startTimecodeFrames,
                config: config,
                startingCueNumber: cueNumber
            )
            allCues.append(contentsOf: clipCues)
            cueNumber += clipCues.count
        }

        guard !allCues.isEmpty else {
            throw CueListExportError.noCuesDetected
        }

        return allCues
    }

    public func exportToCSV(
        cues: [DetectedCue],
        to destinationURL: URL
    ) async throws {
        var csvContent = "Title,TC In,TC Out\n"

        for cue in cues {
            // Escape titles that might contain commas
            let escapedTitle = cue.title.contains(",") ? "\"\(cue.title)\"" : cue.title
            csvContent += "\(escapedTitle),\(cue.timecodeIn),\(cue.timecodeOut)\n"
        }

        do {
            try csvContent.write(to: destinationURL, atomically: true, encoding: .utf8)
        } catch {
            throw CueListExportError.writeFailed(error.localizedDescription)
        }
    }

    // MARK: - Private Methods

    /// Detects cues within a single audio clip.
    private func detectCuesInClip(
        _ clip: AudioClip,
        frameRate: Double,
        startTimecodeFrames: Int,
        config: SilenceDetectionConfig,
        startingCueNumber: Int
    ) async throws -> [DetectedCue] {
        // Determine which URL to use for audio reading
        let audioURL = clip.extractedAudioURL ?? clip.sourceURL

        // Read RMS samples from the audio file
        let rmsData = try await readRMSSamples(from: audioURL, trackIndex: clip.sourceTrackIndex)

        guard !rmsData.samples.isEmpty else {
            return []
        }

        // Find silence regions
        let silenceRegions = findSilenceRegions(
            in: rmsData.samples,
            threshold: config.silenceThresholdRMS,
            sampleRate: rmsData.sampleRate,
            minimumDuration: config.minimumSilenceDuration
        )

        // Invert to get audio regions (cues)
        let audioRegions = invertToAudioRegions(
            silenceRegions: silenceRegions,
            totalSamples: rmsData.samples.count,
            sampleRate: rmsData.sampleRate,
            minimumDuration: config.minimumCueDuration
        )

        // Convert to detected cues with timecodes
        var cues: [DetectedCue] = []
        let clipName = clip.displayName

        for (index, region) in audioRegions.enumerated() {
            let cueNumber = startingCueNumber + index

            // Convert sample positions to timeline frames
            let regionStartSeconds = Double(region.startSample) / rmsData.sampleRate
            let regionEndSeconds = Double(region.endSample) / rmsData.sampleRate

            // Convert to frames relative to clip start, then add clip's timeline position
            let frameIn = clip.timelineStartFrame + Int(regionStartSeconds * frameRate)
            let frameOut = clip.timelineStartFrame + Int(regionEndSeconds * frameRate)

            // Convert to absolute timecode
            let timecodeIn = formatTimecode(frame: frameIn + startTimecodeFrames, frameRate: frameRate)
            let timecodeOut = formatTimecode(frame: frameOut + startTimecodeFrames, frameRate: frameRate)

            cues.append(DetectedCue(
                title: "\(clipName) Cue \(cueNumber)",
                timecodeIn: timecodeIn,
                timecodeOut: timecodeOut,
                frameIn: frameIn,
                frameOut: frameOut
            ))
        }

        return cues
    }

    /// Reads RMS samples from an audio file.
    private func readRMSSamples(
        from url: URL,
        trackIndex: Int?
    ) async throws -> RMSData {
        let accessGranted = url.startAccessingSecurityScopedResource()
        defer {
            if accessGranted {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let asset = AVAsset(url: url)
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
            throw CueListExportError.audioReadFailed("No audio tracks found")
        }

        let track = audioTracks[min(trackIndex ?? 0, audioTracks.count - 1)]

        // Get sample rate from format description
        var sampleRate: Double = 48000
        if let formatDesc = try await track.load(.formatDescriptions).first,
           let basicDesc = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) {
            sampleRate = basicDesc.pointee.mSampleRate
        }

        // Calculate expected output sample count
        let outputSampleCount = max(1, Int(durationSeconds * Double(samplesPerSecond)))

        // Set up asset reader
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)

        guard reader.startReading() else {
            throw CueListExportError.audioReadFailed(reader.error?.localizedDescription ?? "Unknown error")
        }

        // Read samples and compute RMS per bucket
        let samplesPerBucket = max(1, Int(sampleRate) / samplesPerSecond)
        var rmsValues: [Float] = []
        rmsValues.reserveCapacity(outputSampleCount)

        var bucketSamples: [Int16] = []
        bucketSamples.reserveCapacity(samplesPerBucket)

        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }

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
            data.withMemoryRebound(to: Int16.self, capacity: sampleCount) { samplePointer in
                for i in 0..<sampleCount {
                    bucketSamples.append(samplePointer[i])

                    if bucketSamples.count >= samplesPerBucket {
                        rmsValues.append(computeRMS(bucketSamples))
                        bucketSamples.removeAll(keepingCapacity: true)
                    }
                }
            }
        }

        // Process any remaining samples
        if !bucketSamples.isEmpty {
            rmsValues.append(computeRMS(bucketSamples))
        }

        reader.cancelReading()

        // The effective sample rate for our RMS data
        let rmsSampleRate = Double(samplesPerSecond)

        return RMSData(samples: rmsValues, sampleRate: rmsSampleRate)
    }

    /// Computes RMS (root mean square) of a sample buffer.
    private func computeRMS(_ samples: [Int16]) -> Float {
        guard !samples.isEmpty else { return 0 }

        var sumSquares: Double = 0
        for sample in samples {
            let normalized = Double(sample) / 32768.0
            sumSquares += normalized * normalized
        }

        return Float(sqrt(sumSquares / Double(samples.count)))
    }

    /// Finds regions of silence in RMS data.
    private func findSilenceRegions(
        in samples: [Float],
        threshold: Float,
        sampleRate: Double,
        minimumDuration: Double
    ) -> [AudioRegion] {
        var regions: [AudioRegion] = []
        var silenceStart: Int?

        for (index, rms) in samples.enumerated() {
            if rms < threshold {
                // In silence
                if silenceStart == nil {
                    silenceStart = index
                }
            } else {
                // Not in silence
                if let start = silenceStart {
                    let duration = Double(index - start) / sampleRate
                    if duration >= minimumDuration {
                        regions.append(AudioRegion(startSample: start, endSample: index))
                    }
                    silenceStart = nil
                }
            }
        }

        // Handle trailing silence
        if let start = silenceStart {
            let duration = Double(samples.count - start) / sampleRate
            if duration >= minimumDuration {
                regions.append(AudioRegion(startSample: start, endSample: samples.count))
            }
        }

        return regions
    }

    /// Inverts silence regions to get audio (cue) regions.
    private func invertToAudioRegions(
        silenceRegions: [AudioRegion],
        totalSamples: Int,
        sampleRate: Double,
        minimumDuration: Double
    ) -> [AudioRegion] {
        var audioRegions: [AudioRegion] = []
        var currentStart = 0

        for silence in silenceRegions {
            if silence.startSample > currentStart {
                let duration = Double(silence.startSample - currentStart) / sampleRate
                if duration >= minimumDuration {
                    audioRegions.append(AudioRegion(startSample: currentStart, endSample: silence.startSample))
                }
            }
            currentStart = silence.endSample
        }

        // Handle trailing audio
        if currentStart < totalSamples {
            let duration = Double(totalSamples - currentStart) / sampleRate
            if duration >= minimumDuration {
                audioRegions.append(AudioRegion(startSample: currentStart, endSample: totalSamples))
            }
        }

        return audioRegions
    }

    /// Formats a frame number as a timecode string (HH:MM:SS:FF).
    private func formatTimecode(frame: Int, frameRate: Double) -> String {
        let totalSeconds = Int(Double(frame) / frameRate)
        let frames = frame - Int(Double(totalSeconds) * frameRate)

        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        return String(format: "%02d:%02d:%02d:%02d", hours, minutes, seconds, frames)
    }
}

// MARK: - Private Types

/// RMS data extracted from an audio file.
private struct RMSData {
    let samples: [Float]
    let sampleRate: Double
}

/// A region of audio defined by start and end sample indices.
private struct AudioRegion {
    let startSample: Int
    let endSample: Int
}
