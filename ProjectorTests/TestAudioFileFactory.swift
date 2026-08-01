import AVFoundation
import Foundation

/// Utility for generating short audio files for tests.
enum TestAudioFileFactory {
    static func makeSineWaveFile(
        duration: TimeInterval = 1.0,
        sampleRate: Double = 44100,
        frequency: Double = 440
    ) throws -> URL {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        guard let format else {
            throw NSError(domain: "ProjectorTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio format."])
        }

        let frameCount = AVAudioFrameCount(duration * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        guard let buffer else {
            throw NSError(domain: "ProjectorTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio buffer."])
        }
        buffer.frameLength = frameCount

        let theta = 2.0 * Double.pi * frequency / sampleRate
        if let channel = buffer.floatChannelData?[0] {
            for frame in 0..<Int(frameCount) {
                channel[frame] = Float(sin(theta * Double(frame)))
            }
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectorTest-\(UUID().uuidString).wav")

        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)

        return url
    }

    /// Generates a stereo file whose two channels are filled independently.
    ///
    /// Written as real audio rather than synthesised in memory so that a test
    /// exercises the reader and deinterleave as well as whatever it is really
    /// measuring.
    ///
    /// - Parameters:
    ///   - duration: Length in seconds.
    ///   - sampleRate: Sample rate of the written file.
    ///   - sample: Value for a given channel index (0 left, 1 right) and frame.
    /// - Returns: URL of the written file.
    static func makeStereoFile(
        duration: TimeInterval = 8.0,
        sampleRate: Double = 48000,
        sample: (Int, Int) -> Float
    ) throws -> URL {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)
        guard let format else {
            throw NSError(domain: "ProjectorTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio format."])
        }

        let frameCount = AVAudioFrameCount(duration * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        guard let buffer, let channels = buffer.floatChannelData else {
            throw NSError(domain: "ProjectorTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio buffer."])
        }
        buffer.frameLength = frameCount

        for channel in 0..<2 {
            for frame in 0..<Int(frameCount) {
                channels[channel][frame] = sample(channel, frame)
            }
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectorTest-\(UUID().uuidString).wav")

        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)

        return url
    }
}
