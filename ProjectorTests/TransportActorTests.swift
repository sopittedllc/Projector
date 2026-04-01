//
//  TransportActorTests.swift
//  ProjectorTests
//
//  Tests for TransportActor - Transport state management and commands
//

import XCTest
@testable import Projector
import SwiftTimecodeCore

final class TransportActorTests: XCTestCase {

    var actor: TransportActor!
    var mockPlaybackEngine: MockPlaybackEngine!
    var mockTimelineActor: MockTimelineActor!
    var mockMIDISync: MockMIDISyncService!

    @MainActor
    override func setUp() async throws {
        try await super.setUp()

        mockPlaybackEngine = MockPlaybackEngine()
        mockTimelineActor = MockTimelineActor()
        mockMIDISync = MockMIDISyncService()

        actor = TransportActor(
            playbackEngine: mockPlaybackEngine,
            timelineActor: mockTimelineActor,
            midiSyncService: mockMIDISync
        )

        await actor.start()
    }

    override func tearDown() async throws {
        actor = nil
        mockPlaybackEngine = nil
        mockTimelineActor = nil
        mockMIDISync = nil

        try await super.tearDown()
    }

    // MARK: - State Transition Tests

    func testInitialState() async throws {
        // When: Actor is created
        // Then: Initial state is idle
        let state = await collectFirstState()

        XCTAssertFalse(state.isPlaying, "Should not be playing initially")
        XCTAssertEqual(state.currentFrame, 0, "Should start at frame 0")
        XCTAssertEqual(state.loadingState, .idle, "Loading state should be idle")
    }

    func testPlayTransition() async throws {
        // Given: Actor in idle state
        var states: [TransportState] = []
        let expectation = expectation(description: "Collect states")

        let task = Task {
            for await state in actor.transportStateStream {
                states.append(state)
                if states.count >= 2 {
                    expectation.fulfill()
                    break
                }
            }
        }

        // When: Play command issued
        await actor.play()

        // Then: State transitions to playing
        await fulfillment(of: [expectation], timeout: 1.0)
        task.cancel()

        XCTAssertGreaterThanOrEqual(states.count, 2, "Should receive at least 2 states")
        XCTAssertTrue(states.last!.isPlaying, "Final state should be playing")
        XCTAssertEqual(mockPlaybackEngine.playCallCount, 1, "PlaybackEngine.play() should be called once")
    }

    func testPauseTransition() async throws {
        // Given: Actor is playing
        await actor.play()

        // When: Pause command issued
        await actor.pause()

        // Then: isPlaying = false
        let state = await collectFirstState()
        XCTAssertFalse(state.isPlaying, "Should not be playing after pause")
        XCTAssertEqual(mockPlaybackEngine.pauseCallCount, 1, "PlaybackEngine.pause() should be called once")
    }

    func testTogglePlayback() async throws {
        // Given: Not playing
        var initialState = await collectFirstState()
        XCTAssertFalse(initialState.isPlaying)

        // When: Toggle playback
        await actor.togglePlayback()

        // Then: Should be playing
        var newState = await collectFirstState()
        XCTAssertTrue(newState.isPlaying, "Should be playing after toggle")

        // When: Toggle again
        await actor.togglePlayback()

        // Then: Should be paused
        newState = await collectFirstState()
        XCTAssertFalse(newState.isPlaying, "Should be paused after second toggle")
    }

    func testStopCommand() async throws {
        // Given: Playing at frame 1000
        await actor.seekToFrame(1000)
        await actor.play()

        // When: Stop command issued
        await actor.stop()

        // Then: Paused and back at frame 0
        let state = await collectFirstState()
        XCTAssertFalse(state.isPlaying, "Should not be playing after stop")
        XCTAssertEqual(state.currentFrame, 0, "Should be at frame 0 after stop")
    }

    // MARK: - Seek Tests

    func testSeekToFrame() async throws {
        // Given: At frame 0

        // When: Seek to frame 1000
        await actor.seekToFrame(1000)

        // Then: currentFrame = 1000
        let state = await collectFirstState()
        XCTAssertEqual(state.currentFrame, 1000, "Should be at frame 1000")
        XCTAssertEqual(mockPlaybackEngine.lastSeekFrame, 1000, "PlaybackEngine should seek to 1000")
    }

    func testSeekToTimecode() async throws {
        // Given: Timeline at 24fps
        let timecode = try Timecode(.components(h: 0, m: 0, s: 10, f: 0), at: .fps24, by: .clamping)

        // When: Seek to timecode 00:00:10:00
        await actor.seekToTimecode(timecode)

        // Then: Frame position matches timecode
        let expectedFrame = 10 * 24 // 10 seconds at 24fps = 240 frames
        let state = await collectFirstState()
        XCTAssertEqual(state.currentFrame, expectedFrame, "Should be at frame \(expectedFrame)")
    }

    func testStepForward() async throws {
        // Given: At frame 100
        await actor.seekToFrame(100)

        // When: Step forward
        await actor.stepForward()

        // Then: At frame 101
        let state = await collectFirstState()
        XCTAssertEqual(state.currentFrame, 101, "Should advance by 1 frame")
    }

    func testStepBackward() async throws {
        // Given: At frame 100
        await actor.seekToFrame(100)

        // When: Step backward
        await actor.stepBackward()

        // Then: At frame 99
        let state = await collectFirstState()
        XCTAssertEqual(state.currentFrame, 99, "Should move back by 1 frame")
    }

    // MARK: - AsyncStream Tests

    func testTransportStateStreamEmitsOnPlay() async throws {
        // Given: Listening to state stream
        var receivedPlayingState: TransportState?
        let expectation = expectation(description: "Receive playing state")

        let task = Task {
            for await state in actor.transportStateStream {
                if state.isPlaying {
                    receivedPlayingState = state
                    expectation.fulfill()
                    break
                }
            }
        }

        // When: Play command issued
        try await Task.sleep(for: .milliseconds(100)) // Allow stream to set up
        await actor.play()

        // Then: Stream emits playing state
        await fulfillment(of: [expectation], timeout: 1.0)
        task.cancel()

        XCTAssertNotNil(receivedPlayingState, "Should receive playing state")
        XCTAssertTrue(receivedPlayingState!.isPlaying, "Received state should show playing")
    }

    // MARK: - MIDI Integration Tests

    func testSelectMIDIInput() async throws {
        // When: Select MIDI input
        await actor.selectMIDIInput("Test MIDI Device")

        // Then: MIDISyncService.selectInput called
        XCTAssertEqual(mockMIDISync.selectedInputName, "Test MIDI Device")
    }

    func testRefreshMIDIInputs() async throws {
        // When: Refresh MIDI inputs
        await actor.refreshMIDIInputs()

        // Then: MIDISyncService.refreshAvailableInputs called
        XCTAssertTrue(mockMIDISync.refreshCalled, "Should call refresh on MIDI service")
    }

    func testSetMTCFrameRate() async throws {
        // When: Set MTC frame rate
        await actor.setMTCFrameRate(.fps30)

        // Then: MIDISyncService updated
        XCTAssertEqual(mockMIDISync.localFrameRate, .fps30)
    }

    // MARK: - Audio Configuration Tests

    func testSetAudioOutputDevice() async throws {
        // When: Set audio output device
        await actor.setAudioOutputDevice("Test Audio Device")

        // Then: PlaybackEngine updated
        await MainActor.run {
            XCTAssertEqual(mockPlaybackEngine.audioOutputDeviceUID, "Test Audio Device")
        }
    }

    // MARK: - Frame Update Tests

    func testUpdateCurrentFrame() async throws {
        // When: Frame position updated (from PlaybackEngine callback)
        await actor.updateCurrentFrame(500)

        // Then: Current frame reflects update
        let state = await collectFirstState()
        XCTAssertEqual(state.currentFrame, 500, "Frame should be updated")

        // And: MIDI sync notified
        XCTAssertEqual(mockMIDISync.lastPlaybackFrame, 500, "MIDI sync should receive frame update")
    }

    // MARK: - Helper Methods

    private func collectFirstState() async -> TransportState {
        var capturedState: TransportState?

        for await state in actor.transportStateStream {
            capturedState = state
            break
        }

        return capturedState!
    }
}

// MARK: - Mock Classes

/// Mock PlaybackEngine for testing
@MainActor
final class MockPlaybackEngine: ObservableObject {
    var playCallCount = 0
    var pauseCallCount = 0
    var seekCallCount = 0
    var stopCallCount = 0
    var lastSeekFrame: Int?
    var audioOutputDeviceUID: String?
    var onFrameUpdate: ((Int) async -> Void)?

    func play() {
        playCallCount += 1
    }

    func pause() {
        pauseCallCount += 1
    }

    func stop() {
        stopCallCount += 1
    }

    func seekToFrame(_ frame: Int) {
        seekCallCount += 1
        lastSeekFrame = frame
    }

    func setAudioOutputDevice(_ deviceUID: String?) {
        audioOutputDeviceUID = deviceUID
    }
}

/// Mock TimelineActor for testing
actor MockTimelineActor: TimelineServiceProtocol {
    var timelineStateStream: AsyncStream<TimelineState> {
        AsyncStream { continuation in
            let state = TimelineState(
                videoReels: [],
                audioLanes: [],
                durationFrames: 10000,
                frameRate: .fps24,
                isDirty: false,
                config: TimelineConfig(
                    frameRate: .fps24,
                    startTimecode: try! Timecode(.zero, at: .fps24, by: .allowingInvalid),
                    durationFrames: 10000
                )
            )
            continuation.yield(state)
            continuation.finish()
        }
    }

    func addVideoReel(_ reel: VideoReel, at frame: Int) async throws {}
    func removeVideoReel(id: UUID) async {}
    func reorderVideoReels(fromIndex: Int, toIndex: Int) async throws {}
    func updateVideoReel(id: UUID, reel: VideoReel) async throws {}

    func addAudioClip(_ clip: AudioClip, toLane laneId: UUID) async throws {}
    func removeAudioClip(id: UUID) async {}
    func createAudioLane(name: String) async -> AudioLane {
        AudioLane(id: UUID(), name: name, clips: [])
    }
    func removeAudioLane(id: UUID) async throws {}
    func updateAudioLane(id: UUID, lane: AudioLane) async throws {}

    func updateConfiguration(_ config: TimelineConfig) async {}

    func getCurrentState() async -> TimelineState {
        TimelineState(
            videoReels: [],
            audioLanes: [],
            durationFrames: 10000,
            frameRate: .fps24,
            isDirty: false,
            config: TimelineConfig(
                frameRate: .fps24,
                startTimecode: try! Timecode(.zero, at: .fps24, by: .allowingInvalid),
                durationFrames: 10000
            )
        )
    }

    func checkReelOverlap(startFrame: Int, durationFrames: Int, excludingReelId: UUID?) async -> Bool {
        return false
    }

    func checkClipOverlap(startFrame: Int, durationFrames: Int, laneId: UUID, excludingClipId: UUID?) async throws -> Bool {
        return false
    }
}

/// Mock MIDISyncService for testing
actor MockMIDISyncService: MIDISyncServiceProtocol {
    var syncStateStream: AsyncStream<MIDISyncState> {
        AsyncStream { continuation in
            continuation.yield(.empty)
            continuation.finish()
        }
    }

    var selectedInputName: String?
    var refreshCalled = false
    var localFrameRate: TimecodeFrameRate = .fps24
    var lastPlaybackFrame: Int?

    func selectInput(_ name: String?) async {
        selectedInputName = name
    }

    func refreshAvailableInputs() async {
        refreshCalled = true
    }

    func setLocalFrameRate(_ frameRate: TimecodeFrameRate) async {
        localFrameRate = frameRate
    }

    func updateLocalPlaybackFrame(_ frame: Int) async {
        lastPlaybackFrame = frame
    }
}
