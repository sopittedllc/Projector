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
