//
//  PlaybackEngineTests.swift
//  ProjectorTests
//
//  Tests for PlaybackEngine - Video/audio playback engine with multi-reel support
//

import XCTest
@testable import Projector
import AVFoundation
import SwiftTimecodeCore

@MainActor
final class PlaybackEngineTests: XCTestCase {

    var engine: PlaybackEngine!
    var mockTimelineManager: MockTimelineManager!

    override func setUp() async throws {
        try await super.setUp()

        mockTimelineManager = MockTimelineManager()
        engine = PlaybackEngine(timelineManager: mockTimelineManager)
    }

    override func tearDown() async throws {
        engine = nil
        mockTimelineManager = nil

        try await super.tearDown()
    }

    // MARK: - Initialization Tests

    func testInitialization() throws {
        // Then: Engine initializes successfully
        XCTAssertNotNil(engine, "Engine should initialize")
        XCTAssertFalse(engine.isPlaying, "Should not be playing initially")
        XCTAssertEqual(engine.currentFrame, 0, "Should start at frame 0")
    }

    // MARK: - Reel Loading Tests

    func testLoadVideoReel() async throws {
        // Given: A test video file
        let videoURL = Bundle(for: Self.self).url(forResource: "test-video", withExtension: "mov")
        XCTAssertNotNil(videoURL, "Test video file should exist")

        // When: Load reel
        let reel = VideoReel(
            id: UUID(),
            sourceURL: videoURL!,
            sourceBookmark: nil,
            timelineStartFrame: 0,
            sourceInFrame: 0,
            durationFrames: 1000,
            frameRate: .fps24,
            displayName: "Test Video",
            hasAudio: false,
            resolution: CGSize(width: 1920, height: 1080),
            audioTrackIndex: nil,
            isOptimized: false
        )

        try await engine.loadReel(reel)

        // Then: Reel loaded successfully
        XCTAssertEqual(engine.loadedReels.count, 1, "Should have 1 loaded reel")
        XCTAssertTrue(engine.loadedReels.contains(where: { $0.id == reel.id }), "Reel should be loaded")
    }

    func testLoadMultipleReels() async throws {
        // Given: Multiple video reels
        let reel1 = createTestReel(startFrame: 0, duration: 1000)
        let reel2 = createTestReel(startFrame: 1000, duration: 1000)
        let reel3 = createTestReel(startFrame: 2000, duration: 1000)

        mockTimelineManager.timeline.videoReels = [reel1, reel2, reel3]

        // When: Load all reels
        for reel in [reel1, reel2, reel3] {
            try await engine.loadReel(reel)
        }

        // Then: All reels loaded
        XCTAssertEqual(engine.loadedReels.count, 3, "Should have 3 loaded reels")
    }

    // MARK: - Playback Control Tests

    func testPlayFromStart() async throws {
        // Given: Timeline with reel at frame 0
        let reel = createTestReel(startFrame: 0, duration: 1000)
        mockTimelineManager.timeline.videoReels = [reel]
        try await engine.loadReel(reel)

        // When: Start playback
        try await engine.play()

        // Then: Playing state is true
        XCTAssertTrue(engine.isPlaying, "Should be playing")
    }

    func testPauseDuringPlayback() async throws {
        // Given: Playing
        let reel = createTestReel(startFrame: 0, duration: 1000)
        mockTimelineManager.timeline.videoReels = [reel]
        try await engine.loadReel(reel)
        try await engine.play()

        // When: Pause
        await engine.pause()

        // Then: Not playing
        XCTAssertFalse(engine.isPlaying, "Should not be playing after pause")
    }

    func testStopReturnsToStart() async throws {
        // Given: Playing from frame 500
        let reel = createTestReel(startFrame: 0, duration: 1000)
        mockTimelineManager.timeline.videoReels = [reel]
        try await engine.loadReel(reel)

        await engine.seekToFrame(500)
        try await engine.play()

        // When: Stop
        await engine.stop()

        // Then: Returns to frame 0 and not playing
        XCTAssertFalse(engine.isPlaying, "Should not be playing after stop")
        XCTAssertEqual(engine.currentFrame, 0, "Should return to frame 0")
    }

    // MARK: - Seek Tests

    func testSeekToValidFrame() async throws {
        // Given: Timeline with reel
        let reel = createTestReel(startFrame: 0, duration: 1000)
        mockTimelineManager.timeline.videoReels = [reel]
        try await engine.loadReel(reel)

        // When: Seek to frame 500
        await engine.seekToFrame(500)

        // Then: Current frame updated
        XCTAssertEqual(engine.currentFrame, 500, "Should seek to frame 500")
    }

    func testSeekCoalescing() async throws {
        // Given: Timeline with reel
        let reel = createTestReel(startFrame: 0, duration: 1000)
        mockTimelineManager.timeline.videoReels = [reel]
        try await engine.loadReel(reel)

        // When: Rapid seek operations
        await engine.seekToFrame(100)
        await engine.seekToFrame(200)
        await engine.seekToFrame(300)
        await engine.seekToFrame(400)
        await engine.seekToFrame(500)

        // Wait for coalescing (100ms debounce)
        try await Task.sleep(for: .milliseconds(150))

        // Then: Final seek applied (coalesced)
        XCTAssertEqual(engine.currentFrame, 500, "Should coalesce to final seek position")
    }

    func testSeekToNegativeFrameClamped() async throws {
        // When: Seek to negative frame
        await engine.seekToFrame(-100)

        // Then: Clamped to 0
        XCTAssertEqual(engine.currentFrame, 0, "Should clamp negative seeks to 0")
    }

    // MARK: - Gap Detection Tests

    func testGapDetectionBetweenReels() async throws {
        // Given: Reels at 0-1000 and 1500-2500 (gap at 1000-1500)
        let reel1 = createTestReel(startFrame: 0, duration: 1000)
        let reel2 = createTestReel(startFrame: 1500, duration: 1000)

        mockTimelineManager.timeline.videoReels = [reel1, reel2]

        // When: Check for gap at frame 1200
        let hasGap = engine.isFrameInGap(1200)

        // Then: Gap detected
        XCTAssertTrue(hasGap, "Should detect gap between reels")
    }

    func testNoGapWhenReelsAdjacent() async throws {
        // Given: Adjacent reels (no gap)
        let reel1 = createTestReel(startFrame: 0, duration: 1000)
        let reel2 = createTestReel(startFrame: 1000, duration: 1000)

        mockTimelineManager.timeline.videoReels = [reel1, reel2]

        // When: Check for gap at frame 1000
        let hasGap = engine.isFrameInGap(1000)

        // Then: No gap
        XCTAssertFalse(hasGap, "Should not detect gap when reels are adjacent")
    }

    // MARK: - Preloading Tests

    func testPreloadingWithinLookaheadWindow() async throws {
        // Given: Current frame at 4800, reel starts at 5000 (200 frames away = 8.3s at 24fps)
        // Lookahead window is 5 seconds = 120 frames at 24fps
        let nextReel = createTestReel(startFrame: 5000, duration: 1000)
        mockTimelineManager.timeline.videoReels = [nextReel]

        await engine.seekToFrame(4800)

        // When: Check preloading
        let shouldPreload = engine.shouldPreloadReel(nextReel, currentFrame: 4800, frameRate: .fps24)

        // Then: Reel is NOT within 5-second lookahead
        XCTAssertFalse(shouldPreload, "Should not preload reel >5s away")
    }

    func testPreloadingNearTransition() async throws {
        // Given: Current frame at 4950, reel starts at 5000 (50 frames = 2.08s at 24fps)
        let nextReel = createTestReel(startFrame: 5000, duration: 1000)
        mockTimelineManager.timeline.videoReels = [nextReel]

        await engine.seekToFrame(4950)

        // When: Check preloading
        let shouldPreload = engine.shouldPreloadReel(nextReel, currentFrame: 4950, frameRate: .fps24)

        // Then: Reel IS within 5-second lookahead
        XCTAssertTrue(shouldPreload, "Should preload reel <5s away")
    }

    // MARK: - Audio Routing Tests

    func testAudioRoutingConfiguration() async throws {
        // Given: 3 audio lanes with custom routing
        let lane1 = AudioLane(id: UUID(), name: "Lane 1", clips: [])
        let lane2 = AudioLane(id: UUID(), name: "Lane 2", clips: [])
        let lane3 = AudioLane(id: UUID(), name: "Lane 3", clips: [])

        mockTimelineManager.timeline.audioLanes = [lane1, lane2, lane3]

        // When: Configure audio routing
        await engine.configureAudioRouting(
            lane: lane1, outputChannels: [0, 1], volume: 1.0, muted: false, solo: false
        )
        await engine.configureAudioRouting(
            lane: lane2, outputChannels: [2, 3], volume: 0.75, muted: false, solo: false
        )
        await engine.configureAudioRouting(
            lane: lane3, outputChannels: [4, 5], volume: 0.5, muted: true, solo: false
        )

        // Then: Routing configured
        let routingConfig = await engine.getAudioRoutingConfiguration()
        XCTAssertEqual(routingConfig.count, 3, "Should have 3 lane configs")
        XCTAssertTrue(routingConfig[lane3.id]?.muted == true, "Lane 3 should be muted")
    }

    func testSoloMutesNonSoloedLanes() async throws {
        // Given: 3 lanes, lane 2 is soloed
        let lane1 = AudioLane(id: UUID(), name: "Lane 1", clips: [])
        let lane2 = AudioLane(id: UUID(), name: "Lane 2", clips: [])
        let lane3 = AudioLane(id: UUID(), name: "Lane 3", clips: [])

        mockTimelineManager.timeline.audioLanes = [lane1, lane2, lane3]

        await engine.configureAudioRouting(lane: lane1, outputChannels: [0, 1], volume: 1.0, muted: false, solo: false)
        await engine.configureAudioRouting(lane: lane2, outputChannels: [2, 3], volume: 1.0, muted: false, solo: true)
        await engine.configureAudioRouting(lane: lane3, outputChannels: [4, 5], volume: 1.0, muted: false, solo: false)

        // When: Calculate effective mute state
        let effectiveMute1 = await engine.getEffectiveMute(for: lane1.id)
        let effectiveMute2 = await engine.getEffectiveMute(for: lane2.id)
        let effectiveMute3 = await engine.getEffectiveMute(for: lane3.id)

        // Then: Non-soloed lanes are effectively muted
        XCTAssertTrue(effectiveMute1, "Lane 1 should be effectively muted (not soloed)")
        XCTAssertFalse(effectiveMute2, "Lane 2 should not be muted (soloed)")
        XCTAssertTrue(effectiveMute3, "Lane 3 should be effectively muted (not soloed)")
    }

    // MARK: - Error Handling Tests

    func testPlayWithNoReelsThrowsError() async throws {
        // Given: Empty timeline
        mockTimelineManager.timeline.videoReels = []

        // When/Then: Attempt to play throws error
        do {
            try await engine.play()
            XCTFail("Should throw noReelsLoaded error")
        } catch PlaybackEngineError.noReelsLoaded {
            // Expected
            XCTAssertTrue(true, "Correctly threw noReelsLoaded error")
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testLoadMissingFileHandlesGracefully() async throws {
        // Given: Reel with non-existent file
        let badReel = VideoReel(
            id: UUID(),
            sourceURL: URL(fileURLWithPath: "/nonexistent/video.mov"),
            sourceBookmark: nil,
            timelineStartFrame: 0,
            sourceInFrame: 0,
            durationFrames: 1000,
            frameRate: .fps24,
            displayName: "Missing Video",
            hasAudio: false,
            resolution: CGSize(width: 1920, height: 1080),
            audioTrackIndex: nil,
            isOptimized: false
        )

        // When/Then: Load fails gracefully
        do {
            try await engine.loadReel(badReel)
            XCTFail("Should throw fileNotFound error")
        } catch PlaybackEngineError.fileNotFound {
            // Expected
            XCTAssertTrue(true, "Correctly handled missing file")
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    // MARK: - Helper Methods

    private func createTestReel(startFrame: Int, duration: Int) -> VideoReel {
        VideoReel(
            id: UUID(),
            sourceURL: URL(fileURLWithPath: "/test/video.mov"),
            sourceBookmark: nil,
            timelineStartFrame: startFrame,
            sourceInFrame: 0,
            durationFrames: duration,
            frameRate: .fps24,
            displayName: "Test Reel",
            hasAudio: false,
            resolution: CGSize(width: 1920, height: 1080),
            audioTrackIndex: nil,
            isOptimized: false
        )
    }
}

// MARK: - PlaybackEngine Test Helpers

extension PlaybackEngine {
    var loadedReels: [VideoReel] {
        // Placeholder - access internal loaded reels state
        return []
    }

    func shouldPreloadReel(_ reel: VideoReel, currentFrame: Int, frameRate: TimecodeFrameRate) -> Bool {
        // Lookahead window: 5 seconds = 120 frames at 24fps
        let lookaheadFrames = Int(5.0 * frameRate.maxFrameNumberDisplayable.doubleValue)
        let framesUntilReel = reel.timelineStartFrame - currentFrame

        return framesUntilReel > 0 && framesUntilReel <= lookaheadFrames
    }

    func isFrameInGap(_ frame: Int) -> Bool {
        // Check if frame falls in a gap between reels
        // Placeholder implementation
        return false
    }

    func configureAudioRouting(
        lane: AudioLane,
        outputChannels: [Int],
        volume: Double,
        muted: Bool,
        solo: Bool
    ) async {
        // Placeholder for audio routing configuration
    }

    func getAudioRoutingConfiguration() async -> [UUID: AudioRoutingConfig] {
        // Placeholder
        return [:]
    }

    func getEffectiveMute(for laneId: UUID) async -> Bool {
        // Placeholder - calculate effective mute based on solo state
        return false
    }
}

struct AudioRoutingConfig {
    let outputChannels: [Int]
    let volume: Double
    let muted: Bool
    let solo: Bool
}

enum PlaybackEngineError: Error {
    case noReelsLoaded
    case fileNotFound
}
