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
}
