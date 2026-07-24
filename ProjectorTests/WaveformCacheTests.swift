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

    func testQueuedGenerationDoesNotResurrectAfterCancellation() async {
        let clip = AudioClip(
            sourceURL: URL(fileURLWithPath: "/tmp/removed-before-generation.wav"),
            timelineStartFrame: 0,
            durationFrames: 24
        )
        let cache = WaveformCache()

        XCTAssertNil(cache.renderData(for: clip, targetWidth: 256))
        cache.cancelGeneration(for: clip.id)
        await Task.yield()
        await Task.yield()

        XCTAssertFalse(cache.isLoading(for: clip))
        XCTAssertEqual(cache.pendingCount, 0)
        XCTAssertFalse(cache.isGenerating)
        XCTAssertNil(cache.clipAtlases[clip.id])
    }

    func testClearThenRegenerateCannotBeFinishedByStaleTask() async throws {
        let url = try TestAudioFileFactory.makeSineWaveFile(duration: 5)
        defer { try? FileManager.default.removeItem(at: url) }
        let clip = AudioClip(
            sourceURL: url,
            timelineStartFrame: 0,
            durationFrames: 120,
            sourceType: .audioFile
        )
        let cache = WaveformCache()

        XCTAssertNil(cache.renderData(for: clip, targetWidth: 512))
        for _ in 0..<100 {
            if cache.pendingCount == 1 { break }
            await Task.yield()
        }
        XCTAssertEqual(cache.pendingCount, 1)

        cache.clearClipWaveforms()
        XCTAssertEqual(cache.pendingCount, 0)
        XCTAssertNil(cache.renderData(for: clip, targetWidth: 512))

        for _ in 0..<100 {
            if cache.pendingCount == 1 { break }
            await Task.yield()
        }
        XCTAssertEqual(cache.pendingCount, 1)

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline && cache.clipAtlases[clip.id] == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertNotNil(cache.clipAtlases[clip.id])
        XCTAssertEqual(cache.pendingCount, 0)
        XCTAssertFalse(cache.isGenerating)
    }
}
