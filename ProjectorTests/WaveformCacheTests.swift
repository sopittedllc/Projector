import AVFoundation
import XCTest
@testable import Projector

@MainActor
final class WaveformCacheTests: XCTestCase {
    func testWaveformCacheGeneratesSamples() async throws {
        let url = try TestAudioFileFactory.makeSineWaveFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let clip = AudioClip(
            sourceURL: url,
            timelineStartFrame: 0,
            durationFrames: 2400,
            sourceStartFrame: 0,
            sourceType: .audioFile
        )

        let cache = WaveformCache()
        XCTAssertNil(cache.renderData(for: clip, targetWidth: 512))

        let expectation = XCTestExpectation(description: "Waveform atlas generated")

        let pollTask = Task { @MainActor in
            for _ in 0..<50 {
                if let renderData = cache.renderData(for: clip, targetWidth: 512),
                   !renderData.level.max.isEmpty {
                    expectation.fulfill()
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        await fulfillment(of: [expectation], timeout: 10)
        pollTask.cancel()
    }
}

extension WaveformCacheTests {
    func testFailedWaveformDoesNotRetryOnEveryRedraw() async throws {
        let clip = AudioClip(sourceURL: URL(fileURLWithPath: "/missing/\(UUID()).wav"),
                             timelineStartFrame: 0, durationFrames: 240,
                             sourceStartFrame: 0, sourceType: .audioFile)
        let cache = WaveformCache()
        _ = cache.renderData(for: clip, targetWidth: 512)
        for _ in 0..<100 {
            if cache.hasFailed(for: clip) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(cache.hasFailed(for: clip))
        for _ in 0..<10 {
            XCTAssertNil(cache.renderData(for: clip, targetWidth: 512))
            XCTAssertFalse(cache.isLoading(for: clip))
            await Task.yield()
        }
        cache.clearAll()
        XCTAssertFalse(cache.hasFailed(for: clip))
    }
}

// MARK: - Peak time base

extension WaveformCacheTests {
    private static let timeBaseDurations: [Double] = [600, 1200, 2818, 3600, 7200]
    private static let timeBaseSamplesPerSecond = 200
    private static let timeBaseSourceRate: Double = 48000
    private static let timeBaseMaxPeaks = 16384 * 8

    /// Peak index `i` must mean time `i / peaksPerSecond`, and the array must
    /// span the asset exactly - for durations either side of the memory cap.
    func testPeakTimeBaseIsExactAcrossDurations() {
        for duration in Self.timeBaseDurations {
            let base = PeakTimeBase(
                samplesPerSecond: Self.timeBaseSamplesPerSecond,
                sourceSampleRate: Self.timeBaseSourceRate,
                durationSeconds: duration,
                maxPeakCount: Self.timeBaseMaxPeaks
            )
            let rate = base.peaksPerSecond
            XCTAssertLessThanOrEqual(duration * rate, Double(Self.timeBaseMaxPeaks) + 1, "cap at \(duration)s")

            let startSeconds = 12.5
            let events: [Double] = [0, 1, duration / 2, duration - 1]
            for time in events {
                // A peak produced for audio at `time`, after a track offset.
                let produced = Int((time * rate).rounded())
                var raw = [Float](repeating: 0, count: produced + 1)
                raw[produced] = 1
                let aligned = WaveformCache.applyTrackOffset(
                    samples: raw,
                    trackStartSeconds: startSeconds,
                    durationSeconds: duration,
                    peaksPerSecond: rate
                )
                let expectedLength = duration * rate
                XCTAssertLessThanOrEqual(abs(Double(aligned.count) - expectedLength), 1, "length at \(duration)s")

                guard let landed = aligned.firstIndex(of: 1) else {
                    // Trimmed off the end only if it is past the duration.
                    XCTAssertGreaterThan(time + startSeconds, duration - 1, "lost peak at \(time)s of \(duration)s")
                    continue
                }
                let want = (time + startSeconds) * rate
                XCTAssertLessThanOrEqual(abs(Double(landed) - want), 1, "peak for \(time)s of \(duration)s")
            }
        }
    }

    /// A loud burst late in a long, low-rate file must be drawn at its real time.
    func testGeneratedWaveformPlacesLateBurstAtItsTime() async throws {
        let duration: Double = 2700
        let burstTime: Double = 2400
        let sampleRate: Double = 8000
        let url = try Self.makeSilenceWithBurst(duration: duration, burstTime: burstTime, sampleRate: sampleRate)
        defer { try? FileManager.default.removeItem(at: url) }

        let clip = AudioClip(sourceURL: url, timelineStartFrame: 0, durationFrames: 1,
                             sourceStartFrame: 0, sourceType: .audioFile)
        let cache = WaveformCache()
        var data: WaveformRenderData?
        for _ in 0..<600 {
            data = cache.renderData(for: clip, targetWidth: 16384)
            if data != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let level = try XCTUnwrap(data).level
        let loudest = try XCTUnwrap(level.max.indices.max { level.max[$0] < level.max[$1] })
        let bucketSeconds = try XCTUnwrap(data).duration / Double(level.max.count)
        let loudestTime = Double(loudest) * bucketSeconds
        XCTAssertLessThanOrEqual(abs(loudestTime - burstTime), bucketSeconds * 2)
        cache.clearAll()
    }

    private static func makeSilenceWithBurst(duration: Double, burstTime: Double, sampleRate: Double) throws -> URL {
        let burstSeconds = 1.0
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectorTest-\(UUID().uuidString).wav")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let secondFrames = AVAudioFrameCount(sampleRate)
        let silence = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: secondFrames))
        silence.frameLength = secondFrames
        let loud = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: secondFrames))
        loud.frameLength = secondFrames
        if let channel = loud.floatChannelData?[0] {
            for frame in 0..<Int(secondFrames) { channel[frame] = frame % 2 == 0 ? 0.9 : -0.9 }
        }
        for second in 0..<Int(duration) {
            let time = Double(second)
            try file.write(from: (time >= burstTime && time < burstTime + burstSeconds) ? loud : silence)
        }
        return url
    }
}
