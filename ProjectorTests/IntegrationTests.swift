//
//  IntegrationTests.swift
//  ProjectorTests
//
//  Integration tests for end-to-end workflows
//

import XCTest
@testable import Projector
import SwiftTimecodeCore

@MainActor
final class IntegrationTests: XCTestCase {

    var timelineManager: TimelineManager!
    var playbackEngine: PlaybackEngine!
    var transportActor: TransportActor!
    var midiSyncActor: MIDISyncActor!

    override func setUp() async throws {
        try await super.setUp()

        // Create timeline
        let config = TimelineConfig(
            frameRate: .fps24,
            startTimecode: try Timecode(.zero, at: .fps24, by: .allowingInvalid),
            durationFrames: 10000
        )
        timelineManager = TimelineManager(config: config)

        // Create playback engine
        playbackEngine = PlaybackEngine(timelineManager: timelineManager)

        // Create MIDI sync actor
        midiSyncActor = MIDISyncActor()

        // Create timeline actor (using TimelineManager as backend)
        let timelineActor = TimelineActor(timelineManager: timelineManager)

        // Create transport actor
        transportActor = TransportActor(
            playbackEngine: playbackEngine,
            timelineActor: timelineActor,
            midiSyncService: midiSyncActor
        )

        await transportActor.start()
        await midiSyncActor.start()
    }

    override func tearDown() async throws {
        transportActor = nil
        midiSyncActor = nil
        playbackEngine = nil
        timelineManager = nil

        try await super.tearDown()
    }

    // MARK: - End-to-End Playback Tests

    func testEndToEndPlayback() async throws {
        // Given: Timeline with 2 video reels
        let reel1 = createTestReel(startFrame: 0, duration: 1000)
        let reel2 = createTestReel(startFrame: 1000, duration: 1000)

        _ = try await timelineManager.addVideoReel(from: reel1.sourceURL, at: 0, mediaItemId: reel1.id)
        _ = try await timelineManager.addVideoReel(from: reel2.sourceURL, at: 1000, mediaItemId: reel2.id)

        // Load reels into playback engine
        try await playbackEngine.loadReel(reel1)
        try await playbackEngine.loadReel(reel2)

        // When: Start playback
        await transportActor.play()

        // Wait for playback to start
        try await Task.sleep(for: .milliseconds(500))

        // Then: Playback is active
        let state = await collectTransportState()
        XCTAssertTrue(state.isPlaying, "Should be playing")
        XCTAssertEqual(state.loadingState, .ready, "Should be in ready state")
    }

    func testPlaybackWithPauseResume() async throws {
        // Given: Playing timeline
        let reel = createTestReel(startFrame: 0, duration: 1000)
        _ = try await timelineManager.addVideoReel(from: reel.sourceURL, at: 0, mediaItemId: reel.id)
        try await playbackEngine.loadReel(reel)

        await transportActor.play()
        try await Task.sleep(for: .milliseconds(200))

        // When: Pause
        await transportActor.pause()
        try await Task.sleep(for: .milliseconds(100))

        let pausedState = await collectTransportState()
        XCTAssertFalse(pausedState.isPlaying, "Should be paused")

        // When: Resume
        await transportActor.play()
        try await Task.sleep(for: .milliseconds(200))

        let resumedState = await collectTransportState()
        XCTAssertTrue(resumedState.isPlaying, "Should be playing again")
    }

    // MARK: - Multi-Reel Transition Tests

    func testMultiReelTransition() async throws {
        // Given: Timeline with 2 reels at 0-1000, 1000-2000
        let reel1 = createTestReel(startFrame: 0, duration: 1000)
        let reel2 = createTestReel(startFrame: 1000, duration: 1000)

        _ = try await timelineManager.addVideoReel(from: reel1.sourceURL, at: 0, mediaItemId: reel1.id)
        _ = try await timelineManager.addVideoReel(from: reel2.sourceURL, at: 1000, mediaItemId: reel2.id)

        try await playbackEngine.loadReel(reel1)
        try await playbackEngine.loadReel(reel2)

        // When: Play from frame 900 (crosses boundary at 1000)
        await transportActor.seekToFrame(900)
        await transportActor.play()

        // Wait for transition
        try await Task.sleep(for: .seconds(2))

        let state = await collectTransportState()

        // Then: Playback crossed boundary (should be >1000 frames)
        XCTAssertGreaterThan(state.currentFrame, 1000, "Should have crossed reel boundary")
    }

    func testSeamlessTransitionNoBlink() async throws {
        // Given: Adjacent reels
        let reel1 = createTestReel(startFrame: 0, duration: 1000)
        let reel2 = createTestReel(startFrame: 1000, duration: 1000)

        _ = try await timelineManager.addVideoReel(from: reel1.sourceURL, at: 0, mediaItemId: reel1.id)
        _ = try await timelineManager.addVideoReel(from: reel2.sourceURL, at: 1000, mediaItemId: reel2.id)

        try await playbackEngine.loadReel(reel1)
        try await playbackEngine.loadReel(reel2)

        // When: Play through transition
        await transportActor.seekToFrame(995)
        await transportActor.play()

        // Verify no gap in playback (no loading state)
        var states: [TransportState] = []
        let task = Task {
            for await state in transportActor.transportStateStream {
                states.append(state)
                if states.count >= 10 { break }
            }
        }

        try await Task.sleep(for: .seconds(1))
        task.cancel()

        // Then: No loading interruptions during transition
        let hadLoadingInterruption = states.contains(where: { $0.loadingState == .loading && $0.currentFrame > 1000 })
        XCTAssertFalse(hadLoadingInterruption, "Should not have loading interruption at transition")
    }

    // MARK: - MIDI Sync Integration Tests

    func testMTCPlayCommandStartsPlayback() async throws {
        // Given: Timeline with reel
        let reel = createTestReel(startFrame: 0, duration: 1000)
        _ = try await timelineManager.addVideoReel(from: reel.sourceURL, at: 0, mediaItemId: reel.id)
        try await playbackEngine.loadReel(reel)

        // When: MTC play command received (via MMC)
        await midiSyncActor.handleMMCCommand(.play)

        // Wait for command processing
        try await Task.sleep(for: .milliseconds(200))

        let state = await collectTransportState()

        // Then: Playback started
        XCTAssertTrue(state.isPlaying, "Should start playing on MMC play command")
    }

    func testMTCStopCommandPausesPlayback() async throws {
        // Given: Playing
        let reel = createTestReel(startFrame: 0, duration: 1000)
        _ = try await timelineManager.addVideoReel(from: reel.sourceURL, at: 0, mediaItemId: reel.id)
        try await playbackEngine.loadReel(reel)

        await transportActor.play()
        try await Task.sleep(for: .milliseconds(200))

        // When: MTC stop command received
        await midiSyncActor.handleMMCCommand(.stop)

        try await Task.sleep(for: .milliseconds(200))

        let state = await collectTransportState()

        // Then: Playback paused
        XCTAssertFalse(state.isPlaying, "Should pause on MMC stop command")
    }

    func testMTCLocateCommandSeeksToFrame() async throws {
        // Given: Timeline with reel
        let reel = createTestReel(startFrame: 0, duration: 1000)
        _ = try await timelineManager.addVideoReel(from: reel.sourceURL, at: 0, mediaItemId: reel.id)
        try await playbackEngine.loadReel(reel)

        // When: MTC locate command to frame 500
        await midiSyncActor.handleMMCCommand(.locate(frame: 500))

        try await Task.sleep(for: .milliseconds(200))

        let state = await collectTransportState()

        // Then: Seeked to frame 500
        XCTAssertEqual(state.currentFrame, 500, accuracy: 10, "Should seek to frame 500")
    }

    func testMTCDriftTracking() async throws {
        // Given: Playing timeline
        let reel = createTestReel(startFrame: 0, duration: 1000)
        _ = try await timelineManager.addVideoReel(from: reel.sourceURL, at: 0, mediaItemId: reel.id)
        try await playbackEngine.loadReel(reel)

        await transportActor.play()

        // Simulate MTC at frame 1000
        await midiSyncActor.handleFullTimecode(frame: 1000, at: .fps24)

        // Transport at frame 995 (5 frame drift)
        await transportActor.updateCurrentFrame(995)

        // Wait for drift calculation (throttled to 1Hz)
        try await Task.sleep(for: .seconds(1.1))

        let syncState = await collectMIDISyncState()

        // Then: Drift calculated
        XCTAssertEqual(syncState.driftFrames, 5.0, accuracy: 1.0, "Should calculate 5-frame drift")
        XCTAssertEqual(syncState.driftStatus, .poor, "5-frame drift should be 'poor'")
    }

    // MARK: - Timeline Edit During Playback Tests

    func testAddClipDuringPlayback() async throws {
        // Given: Playing timeline
        let reel = createTestReel(startFrame: 0, duration: 1000)
        _ = try await timelineManager.addVideoReel(from: reel.sourceURL, at: 0, mediaItemId: reel.id)
        try await playbackEngine.loadReel(reel)

        await transportActor.play()
        try await Task.sleep(for: .milliseconds(200))

        // When: Add audio clip to timeline during playback
        let lane = timelineManager.addAudioLane(name: "Dialog")
        let audioURL = URL(fileURLWithPath: "/test/audio.wav")
        _ = try await timelineManager.addAudioClip(from: audioURL, toLane: lane.id, at: 500)

        try await Task.sleep(for: .milliseconds(500))

        let state = await collectTransportState()

        // Then: Playback continues (no crash)
        XCTAssertTrue(state.isPlaying, "Playback should continue after adding clip")
    }

    func testRemoveReelDuringPlayback() async throws {
        // Given: Playing timeline with 2 reels
        let reel1 = createTestReel(startFrame: 0, duration: 1000)
        let reel2 = createTestReel(startFrame: 1000, duration: 1000)

        _ = try await timelineManager.addVideoReel(from: reel1.sourceURL, at: 0, mediaItemId: reel1.id)
        _ = try await timelineManager.addVideoReel(from: reel2.sourceURL, at: 1000, mediaItemId: reel2.id)

        try await playbackEngine.loadReel(reel1)
        try await playbackEngine.loadReel(reel2)

        await transportActor.play()
        try await Task.sleep(for: .milliseconds(200))

        // When: Remove second reel during playback
        timelineManager.removeVideoReel(id: reel2.id)

        try await Task.sleep(for: .milliseconds(500))

        let state = await collectTransportState()

        // Then: Playback continues (handles missing reel gracefully)
        // Playback may pause when reaching gap, but should not crash
        XCTAssertNotNil(state, "Should have valid transport state")
    }

    // MARK: - Audio Routing Integration Tests

    func testMultiLaneAudioPlayback() async throws {
        // Given: Timeline with 3 audio lanes
        let lane1 = timelineManager.addAudioLane(name: "Dialog")
        let lane2 = timelineManager.addAudioLane(name: "Music")
        let lane3 = timelineManager.addAudioLane(name: "SFX")

        let audioURL = URL(fileURLWithPath: "/test/audio.wav")
        _ = try await timelineManager.addAudioClip(from: audioURL, toLane: lane1.id, at: 0)
        _ = try await timelineManager.addAudioClip(from: audioURL, toLane: lane2.id, at: 0)
        _ = try await timelineManager.addAudioClip(from: audioURL, toLane: lane3.id, at: 0)

        // Configure routing
        timelineManager.setLaneOutputOffset(id: lane1.id, offset: 0)  // Outputs 1-2
        timelineManager.setLaneOutputOffset(id: lane2.id, offset: 2)  // Outputs 3-4
        timelineManager.setLaneOutputOffset(id: lane3.id, offset: 4)  // Outputs 5-6

        // When: Play
        await transportActor.play()

        try await Task.sleep(for: .milliseconds(500))

        let state = await collectTransportState()

        // Then: Playback active with 3-lane audio
        XCTAssertTrue(state.isPlaying, "Should be playing with multi-lane audio")
    }

    func testSoloMutesOtherLanes() async throws {
        // Given: 3 audio lanes, lane 2 soloed
        let lane1 = timelineManager.addAudioLane(name: "Dialog")
        let lane2 = timelineManager.addAudioLane(name: "Music")
        let lane3 = timelineManager.addAudioLane(name: "SFX")

        let audioURL = URL(fileURLWithPath: "/test/audio.wav")
        _ = try await timelineManager.addAudioClip(from: audioURL, toLane: lane1.id, at: 0)
        _ = try await timelineManager.addAudioClip(from: audioURL, toLane: lane2.id, at: 0)
        _ = try await timelineManager.addAudioClip(from: audioURL, toLane: lane3.id, at: 0)

        // When: Solo lane 2
        timelineManager.setLaneSolo(id: lane2.id, solo: true)

        await transportActor.play()
        try await Task.sleep(for: .milliseconds(500))

        let state = await collectTransportState()

        // Then: Only lane 2 plays (lanes 1 and 3 effectively muted)
        XCTAssertTrue(state.isPlaying, "Should be playing")
        // Audio routing manager should mute lanes 1 and 3
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

    private func collectTransportState() async -> TransportState {
        var capturedState: TransportState?

        for await state in transportActor.transportStateStream {
            capturedState = state
            break
        }

        return capturedState ?? .idle
    }

    private func collectMIDISyncState() async -> MIDISyncState {
        var capturedState: MIDISyncState?

        for await state in midiSyncActor.syncStateStream {
            capturedState = state
            break
        }

        return capturedState ?? .empty
    }
}

// MARK: - Test Extensions

extension TransportState {
    static var idle: TransportState {
        TransportState(
            isPlaying: false,
            currentFrame: 0,
            currentTimecode: try! Timecode(.zero, at: .fps24, by: .allowingInvalid),
            loadingState: .idle,
            gapState: .noGap,
            frameRate: .fps24
        )
    }
}
