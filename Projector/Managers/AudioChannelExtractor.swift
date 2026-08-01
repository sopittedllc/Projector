import Foundation
import AVFoundation
import Accelerate

/// Writes one side of a stereo track out as its own mono file.
///
/// Splitting a hard-panned video needs each lane to hold only its half of the
/// source. Doing that at playback time would mean muting a channel on every
/// buffer; doing it once at import gives each lane an ordinary mono file, which
/// then plays, scrubs and draws its waveform like any other clip - including
/// through the mixer path that sends a mono lane to both sides of its output.
///
/// ## Why not a passthrough export
///
/// `AVAssetExportSession` copies a track whole and has no notion of dropping a
/// channel, so the usual fast path cannot do this. The file is read as PCM and
/// rewritten instead, which costs a pass over the audio but is the only way to
/// get a genuinely single-channel result.
///
/// ## Thread Safety
///
/// `nonisolated` and stateless. Call it from a detached task; it does not touch
/// the main actor.
enum AudioChannelExtractor {

    private enum Extraction {
        /// Reading and writing at the source rate keeps the split sample-accurate
        /// against the video it came from.
        static let bitDepth = 32
        static let stereoChannelCount = 2
        static let monoChannelCount = 1

        /// Frames per read. Large enough that the loop is not syscall-bound,
        /// small enough that a feature-length reel does not balloon memory.
        static let bufferFrames = 16384
    }

    /// Extract both sides of an asset's audio track to mono files, in one pass.
    ///
    /// A split needs both halves, and reading the source once for each meant
    /// decoding a feature-length reel twice over - the bulk of the wait between
    /// answering the split question and seeing the waveforms appear. One read
    /// feeds both writers instead.
    ///
    /// - Parameters:
    ///   - url: Source file, which may be a video container.
    ///   - trackIndex: Audio track to read from.
    ///   - destinations: Where to write each side. Overwritten if they exist.
    /// - Returns: The written file for each side.
    /// - Throws: `ChannelExtractionError` if the source cannot be read, is not
    ///   stereo, or a destination cannot be written.
    static func extractChannels(
        from url: URL,
        trackIndex: Int = 0,
        to destinations: [SplitChannel: URL]
    ) async throws -> [SplitChannel: URL] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard tracks.indices.contains(trackIndex) else {
            throw ChannelExtractionError.noAudioTrack
        }
        let track = tracks[trackIndex]

        guard let description = try await track.load(.formatDescriptions).first,
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description) else {
            throw ChannelExtractionError.unreadableFormat
        }
        let sourceChannelCount = Int(basic.pointee.mChannelsPerFrame)
        let sampleRate = basic.pointee.mSampleRate

        guard sourceChannelCount >= Extraction.stereoChannelCount else {
            throw ChannelExtractionError.notStereo(channels: sourceChannelCount)
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Extraction.stereoChannelCount,
            AVLinearPCMBitDepthKey: Extraction.bitDepth,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)

        guard let monoFormat = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: AVAudioChannelCount(Extraction.monoChannelCount)
        ) else {
            throw ChannelExtractionError.unreadableFormat
        }

        // Both sides are required. `vDSP_ctoz` writes the pair together, and a
        // split needs both halves anyway, so there is no one-sided case to serve.
        let ordered = SplitChannel.allCases
        guard ordered.allSatisfy({ destinations[$0] != nil }) else {
            throw ChannelExtractionError.writeFailed(nil)
        }

        var files: [AVAudioFile] = []
        for channel in ordered {
            guard let destination = destinations[channel] else { continue }
            try? FileManager.default.removeItem(at: destination)
            files.append(try AVAudioFile(
                forWriting: destination,
                settings: monoFormat.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            ))
        }

        guard reader.startReading() else {
            throw ChannelExtractionError.readFailed(reader.error)
        }

        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }

            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &length,
                dataPointerOut: &pointer
            ) == kCMBlockBufferNoErr, let pointer else { continue }

            let totalSamples = length / MemoryLayout<Float>.size
            let frameCount = totalSamples / Extraction.stereoChannelCount
            guard frameCount > 0 else { continue }

            var buffers: [AVAudioPCMBuffer] = []
            for _ in ordered {
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: monoFormat,
                    frameCapacity: AVAudioFrameCount(frameCount)
                ) else {
                    throw ChannelExtractionError.writeFailed(nil)
                }
                buffer.frameLength = AVAudioFrameCount(frameCount)
                buffers.append(buffer)
            }

            // Deinterleave straight into the output buffers. An interleaved L/R
            // pair has the same layout as a complex real/imaginary pair, which
            // is what `vDSP_ctoz` splits - one vectorised call in place of a
            // scalar copy per frame, per side.
            guard let left = buffers[0].floatChannelData?[0],
                  let right = buffers[1].floatChannelData?[0] else {
                throw ChannelExtractionError.writeFailed(nil)
            }

            var split = DSPSplitComplex(realp: left, imagp: right)
            pointer.withMemoryRebound(to: DSPComplex.self, capacity: frameCount) { pairs in
                vDSP_ctoz(pairs, 2, &split, 1, vDSP_Length(frameCount))
            }

            for (index, file) in files.enumerated() {
                do {
                    try file.write(from: buffers[index])
                } catch {
                    reader.cancelReading()
                    throw ChannelExtractionError.writeFailed(error)
                }
            }
        }

        if reader.status == .failed {
            throw ChannelExtractionError.readFailed(reader.error)
        }

        return destinations
    }

    /// Extract a single channel of an asset's audio track to a mono file.
    ///
    /// - Parameters:
    ///   - url: Source file, which may be a video container.
    ///   - channel: Which side to keep.
    ///   - trackIndex: Audio track to read from.
    ///   - destination: Where to write. Overwritten if it exists.
    /// - Returns: The written file's URL.
    /// - Throws: `ChannelExtractionError` if the source cannot be read, is not
    ///   stereo, or the destination cannot be written.
    static func extractChannel(
        from url: URL,
        channel: SplitChannel,
        trackIndex: Int = 0,
        to destination: URL
    ) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard tracks.indices.contains(trackIndex) else {
            throw ChannelExtractionError.noAudioTrack
        }
        let track = tracks[trackIndex]

        guard let description = try await track.load(.formatDescriptions).first,
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description) else {
            throw ChannelExtractionError.unreadableFormat
        }
        let sourceChannelCount = Int(basic.pointee.mChannelsPerFrame)
        let sampleRate = basic.pointee.mSampleRate

        guard sourceChannelCount >= Extraction.stereoChannelCount else {
            throw ChannelExtractionError.notStereo(channels: sourceChannelCount)
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Extraction.stereoChannelCount,
            AVLinearPCMBitDepthKey: Extraction.bitDepth,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)

        guard let monoFormat = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: AVAudioChannelCount(Extraction.monoChannelCount)
        ) else {
            throw ChannelExtractionError.unreadableFormat
        }

        try? FileManager.default.removeItem(at: destination)
        let file = try AVAudioFile(
            forWriting: destination,
            settings: monoFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        guard reader.startReading() else {
            throw ChannelExtractionError.readFailed(reader.error)
        }

        let wantedChannel = channel.channelIndex

        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }

            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &length,
                dataPointerOut: &pointer
            ) == kCMBlockBufferNoErr, let pointer else { continue }

            let totalSamples = length / MemoryLayout<Float>.size
            let frameCount = totalSamples / Extraction.stereoChannelCount
            guard frameCount > 0 else { continue }

            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: monoFormat,
                frameCapacity: AVAudioFrameCount(frameCount)
            ), let destinationChannel = buffer.floatChannelData?[0] else {
                throw ChannelExtractionError.writeFailed(nil)
            }
            buffer.frameLength = AVAudioFrameCount(frameCount)

            pointer.withMemoryRebound(to: Float.self, capacity: totalSamples) { samples in
                for frame in 0..<frameCount {
                    destinationChannel[frame] = samples[frame * Extraction.stereoChannelCount + wantedChannel]
                }
            }

            do {
                try file.write(from: buffer)
            } catch {
                reader.cancelReading()
                throw ChannelExtractionError.writeFailed(error)
            }
        }

        if reader.status == .failed {
            throw ChannelExtractionError.readFailed(reader.error)
        }

        return destination
    }

    /// A temp-directory URL for one side of a source file.
    ///
    /// Stable for a given source and side, so re-splitting a reel overwrites the
    /// file it wrote last time. It used to append a UUID, which meant every
    /// split left another pair of several-hundred-megabyte files behind that
    /// nothing would ever read again.
    static func temporaryURL(for sourceURL: URL, channel: SplitChannel) -> URL {
        TemporaryAudioFiles.url(
            for: sourceURL,
            role: channel.rawValue,
            fileExtension: "caf"
        )
    }
}

// MARK: - Errors

enum ChannelExtractionError: LocalizedError {
    case noAudioTrack
    case unreadableFormat
    case notStereo(channels: Int)
    case readFailed(Error?)
    case writeFailed(Error?)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack:
            return "The file has no audio track to split."
        case .unreadableFormat:
            return "The audio format could not be read."
        case .notStereo(let channels):
            return "Splitting needs a stereo track; this one has \(channels) channel(s)."
        case .readFailed(let underlying):
            return "Couldn't read the audio while splitting it."
                + (underlying.map { " \($0.localizedDescription)" } ?? "")
        case .writeFailed(let underlying):
            return "Couldn't write the split audio."
                + (underlying.map { " \($0.localizedDescription)" } ?? "")
        }
    }
}
