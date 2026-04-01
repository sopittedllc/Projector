//
//  TimelineActorTests.swift
//  ProjectorTests
//
//  Tests for TimelineActor - Timeline state management and operations
//

import XCTest
@testable import Projector
import SwiftTimecodeCore

final class TimelineActorTests: XCTestCase {

    var actor: TimelineActor!
    var mockTimelineManager: MockTimelineManager!

    @MainActor
    override func setUp() async throws {
        try await super.setUp()

        mockTimelineManager = MockTimelineManager()
        actor = TimelineActor(timelineManager: mockTimelineManager)
    }

    override func tearDown() async throws {
        actor = nil
        mockTimelineManager = nil

        try await super.tearDown()
    }

    // MARK: - Video Reel Tests

    func testAddVideoReel() async throws {
        // Given: Empty timeline
        let reel = createTestReel(startFrame: 0, duration: 1000)

        // When: Add video reel
        try await actor.addVideoReel(reel, at: 0)

        // Then: Reel added successfully
        await MainActor.run {
            XCTAssertEqual(mockTimelineManager.addVideoReelCallCount, 1)
        }
    }

    func testAddVideoReelAtInvalidFrame() async throws {
        // Given: A reel to add
        let reel = createTestReel(startFrame: -100, duration: 1000)

        // When/Then: Adding at negative frame throws error
        do {
            try await actor.addVideoReel(reel, at: -100)
            XCTFail("Should throw invalidFramePosition error")
        } catch TimelineError.invalidFramePosition(let frame) {
            XCTAssertEqual(frame, -100, "Error should include invalid frame")
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testAddVideoReelWithOverlap() async throws {
        // Given: Existing reel at 0-1000
        let existingReel = createTestReel(startFrame: 0, duration: 1000)
        await MainActor.run {
            mockTimelineManager.timeline.videoReels = [existingReel]
        }

        // When/Then: Adding overlapping reel throws error
        let newReel = createTestReel(startFrame: 500, duration: 1000)

        do {
            try await actor.addVideoReel(newReel, at: 500)
            XCTFail("Should throw reelOverlap error")
        } catch TimelineError.reelOverlap(let frame, let existingReelId) {
            XCTAssertEqual(frame, 500)
            XCTAssertEqual(existingReelId, existingReel.id)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testRemoveVideoReel() async throws {
        // Given: Reel exists
        let reel = createTestReel(startFrame: 0, duration: 1000)
        await MainActor.run {
            mockTimelineManager.timeline.videoReels = [reel]
        }

        // When: Remove reel
        await actor.removeVideoReel(id: reel.id)

        // Then: Reel removed
        await MainActor.run {
            XCTAssertEqual(mockTimelineManager.removeVideoReelCallCount, 1)
        }
    }

    func testReorderVideoReels() async throws {
        // Given: Multiple reels
        let reel1 = createTestReel(startFrame: 0, duration: 1000)
        let reel2 = createTestReel(startFrame: 1000, duration: 1000)
        let reel3 = createTestReel(startFrame: 2000, duration: 1000)

        await MainActor.run {
            mockTimelineManager.timeline.videoReels = [reel1, reel2, reel3]
        }

        // When: Reorder from index 0 to 2
        try await actor.reorderVideoReels(fromIndex: 0, toIndex: 2)

        // Then: Reels reordered
        let state = await actor.getCurrentState()
        XCTAssertEqual(state.videoReels.count, 3)
        // reel1 moved to end: [reel2, reel3, reel1]
        XCTAssertEqual(state.videoReels[0].id, reel2.id)
        XCTAssertEqual(state.videoReels[2].id, reel1.id)
    }

    func testUpdateVideoReel() async throws {
        // Given: Existing reel
        let reel = createTestReel(startFrame: 0, duration: 1000)
        await MainActor.run {
            mockTimelineManager.timeline.videoReels = [reel]
        }

        // When: Update reel (change duration)
        var updatedReel = reel
        updatedReel.durationFrames = 2000

        try await actor.updateVideoReel(id: reel.id, reel: updatedReel)

        // Then: Reel updated
        let state = await actor.getCurrentState()
        XCTAssertEqual(state.videoReels[0].durationFrames, 2000)
    }

    func testUpdateNonexistentVideoReel() async throws {
        // Given: Empty timeline

        // When/Then: Updating nonexistent reel throws error
        let reel = createTestReel(startFrame: 0, duration: 1000)

        do {
            try await actor.updateVideoReel(id: UUID(), reel: reel)
            XCTFail("Should throw reelNotFound error")
        } catch TimelineError.reelNotFound {
            // Expected
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    // MARK: - Audio Lane Tests

    func testCreateAudioLane() async throws {
        // When: Create new audio lane
        let lane = await actor.createAudioLane(name: "Test Lane")

        // Then: Lane created
        XCTAssertEqual(lane.name, "Test Lane")
        await MainActor.run {
            XCTAssertEqual(mockTimelineManager.addAudioLaneCallCount, 1)
        }
    }

    func testRemoveAudioLane() async throws {
        // Given: Existing lane
        let lane = AudioLane(id: UUID(), name: "Lane 1", clips: [])
        await MainActor.run {
            mockTimelineManager.timeline.audioLanes = [lane]
        }

        // When: Remove lane
        try await actor.removeAudioLane(id: lane.id)

        // Then: Lane removed
        await MainActor.run {
            XCTAssertEqual(mockTimelineManager.removeAudioLaneCallCount, 1)
        }
    }

    func testRemoveNonexistentAudioLane() async throws {
        // Given: Empty timeline

        // When/Then: Removing nonexistent lane throws error
        do {
            try await actor.removeAudioLane(id: UUID())
            XCTFail("Should throw laneNotFound error")
        } catch TimelineError.laneNotFound {
            // Expected
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testAddAudioClip() async throws {
        // Given: Existing lane
        let lane = AudioLane(id: UUID(), name: "Lane 1", clips: [])
        await MainActor.run {
            mockTimelineManager.timeline.audioLanes = [lane]
        }

        // When: Add audio clip
        let clip = createTestAudioClip(startFrame: 0, duration: 1000)
        try await actor.addAudioClip(clip, toLane: lane.id)

        // Then: Clip added
        await MainActor.run {
            XCTAssertEqual(mockTimelineManager.addAudioClipCallCount, 1)
        }
    }

    func testAddAudioClipToNonexistentLane() async throws {
        // Given: No lanes

        // When/Then: Adding clip to nonexistent lane throws error
        let clip = createTestAudioClip(startFrame: 0, duration: 1000)

        do {
            try await actor.addAudioClip(clip, toLane: UUID())
            XCTFail("Should throw laneNotFound error")
        } catch TimelineError.laneNotFound {
            // Expected
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testAddAudioClipWithOverlap() async throws {
        // Given: Lane with existing clip at 0-1000
        let existingClip = createTestAudioClip(startFrame: 0, duration: 1000)
        let lane = AudioLane(id: UUID(), name: "Lane 1", clips: [existingClip])
        await MainActor.run {
            mockTimelineManager.timeline.audioLanes = [lane]
        }

        // When/Then: Adding overlapping clip throws error
        let newClip = createTestAudioClip(startFrame: 500, duration: 1000)

        do {
            try await actor.addAudioClip(newClip, toLane: lane.id)
            XCTFail("Should throw clipOverlap error")
        } catch TimelineError.clipOverlap(let frame, let laneId, let existingClipId) {
            XCTAssertEqual(frame, 500)
            XCTAssertEqual(laneId, lane.id)
            XCTAssertEqual(existingClipId, existingClip.id)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testRemoveAudioClip() async throws {
        // Given: Lane with clip
        let clip = createTestAudioClip(startFrame: 0, duration: 1000)
        let lane = AudioLane(id: UUID(), name: "Lane 1", clips: [clip])
        await MainActor.run {
            mockTimelineManager.timeline.audioLanes = [lane]
        }

        // When: Remove clip
        await actor.removeAudioClip(id: clip.id)

        // Then: Clip removed
        await MainActor.run {
            XCTAssertEqual(mockTimelineManager.removeAudioClipCallCount, 1)
        }
    }

    // MARK: - Timeline Configuration Tests

    func testUpdateConfiguration() async throws {
        // Given: Timeline with 24fps
        let newConfig = TimelineConfig(
            frameRate: .fps30,
            startTimecode: try Timecode(.zero, at: .fps30, by: .allowingInvalid),
            durationFrames: 10000
        )

        // When: Update configuration
        await actor.updateConfiguration(newConfig)

        // Then: Configuration updated
        await MainActor.run {
            XCTAssertEqual(mockTimelineManager.updateConfigCallCount, 1)
        }
    }

    // MARK: - Query Tests

    func testGetCurrentState() async throws {
        // When: Get current state
        let state = await actor.getCurrentState()

        // Then: State reflects timeline
        XCTAssertEqual(state.frameRate, .fps24)
        XCTAssertEqual(state.durationFrames, 10000)
    }

    func testCheckReelOverlap() async throws {
        // Given: Reel at 0-1000
        let reel = createTestReel(startFrame: 0, duration: 1000)
        await MainActor.run {
            mockTimelineManager.timeline.videoReels = [reel]
        }

        // When/Then: Check for overlap at 500-600 (overlaps)
        let overlaps1 = await actor.checkReelOverlap(
            startFrame: 500,
            durationFrames: 100,
            excludingReelId: nil
        )
        XCTAssertTrue(overlaps1, "Should detect overlap")

        // When/Then: Check for overlap at 2000-3000 (no overlap)
        let overlaps2 = await actor.checkReelOverlap(
            startFrame: 2000,
            durationFrames: 1000,
            excludingReelId: nil
        )
        XCTAssertFalse(overlaps2, "Should not detect overlap")
    }

    func testCheckClipOverlap() async throws {
        // Given: Lane with clip at 0-1000
        let clip = createTestAudioClip(startFrame: 0, duration: 1000)
        let lane = AudioLane(id: UUID(), name: "Lane 1", clips: [clip])
        await MainActor.run {
            mockTimelineManager.timeline.audioLanes = [lane]
        }

        // When/Then: Check for overlap at 500-600 (overlaps)
        let overlaps1 = try await actor.checkClipOverlap(
            startFrame: 500,
            durationFrames: 100,
            laneId: lane.id,
            excludingClipId: nil
        )
        XCTAssertTrue(overlaps1, "Should detect overlap")

        // When/Then: Check for overlap at 2000-3000 (no overlap)
        let overlaps2 = try await actor.checkClipOverlap(
            startFrame: 2000,
            durationFrames: 1000,
            laneId: lane.id,
            excludingClipId: nil
        )
        XCTAssertFalse(overlaps2, "Should not detect overlap")
    }

    // MARK: - AsyncStream Tests

    func testTimelineStateStream() async throws {
        // Given: Listening to state stream
        var receivedState: TimelineState?
        let expectation = expectation(description: "Receive state")

        let task = Task {
            for await state in actor.timelineStateStream {
                receivedState = state
                expectation.fulfill()
                break
            }
        }

        // Then: Stream emits initial state
        await fulfillment(of: [expectation], timeout: 1.0)
        task.cancel()

        XCTAssertNotNil(receivedState, "Should receive initial state")
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

    private func createTestAudioClip(startFrame: Int, duration: Int) -> AudioClip {
        AudioClip(
            id: UUID(),
            sourceURL: URL(fileURLWithPath: "/test/audio.wav"),
            timelineStartFrame: startFrame,
            sourceInFrame: 0,
            durationFrames: duration,
            displayName: "Test Clip"
        )
    }
}

// MARK: - Mock TimelineManager

@MainActor
final class MockTimelineManager: ObservableObject {
    var timeline: Timeline
    var hasChanges: Bool = false

    var addVideoReelCallCount = 0
    var removeVideoReelCallCount = 0
    var addAudioClipCallCount = 0
    var removeAudioClipCallCount = 0
    var addAudioLaneCallCount = 0
    var removeAudioLaneCallCount = 0
    var updateConfigCallCount = 0

    var onTimelineChanged: (() -> Void)?

    init() {
        let config = TimelineConfig(
            frameRate: .fps24,
            startTimecode: try! Timecode(.zero, at: .fps24, by: .allowingInvalid),
            durationFrames: 10000
        )
        self.timeline = Timeline(config: config)
    }

    func addVideoReel(from url: URL, at timelineFrame: Int, mediaItemId: UUID? = nil) async throws -> VideoReel {
        addVideoReelCallCount += 1
        let reel = VideoReel(
            id: UUID(),
            sourceURL: url,
            sourceBookmark: nil,
            timelineStartFrame: timelineFrame,
            sourceInFrame: 0,
            durationFrames: 1000,
            frameRate: .fps24,
            displayName: url.lastPathComponent,
            hasAudio: false,
            resolution: CGSize(width: 1920, height: 1080),
            audioTrackIndex: nil,
            isOptimized: false
        )
        timeline.videoReels.append(reel)
        onTimelineChanged?()
        return reel
    }

    func removeVideoReel(id: UUID) {
        removeVideoReelCallCount += 1
        timeline.videoReels.removeAll { $0.id == id }
        onTimelineChanged?()
    }

    func addAudioClip(from url: URL, toLane laneId: UUID, at timelineFrame: Int) async throws -> AudioClip {
        addAudioClipCallCount += 1
        let clip = AudioClip(
            id: UUID(),
            sourceURL: url,
            timelineStartFrame: timelineFrame,
            sourceInFrame: 0,
            durationFrames: 1000,
            displayName: url.lastPathComponent
        )
        if let laneIndex = timeline.audioLanes.firstIndex(where: { $0.id == laneId }) {
            timeline.audioLanes[laneIndex].clips.append(clip)
        }
        onTimelineChanged?()
        return clip
    }

    func removeAudioClip(clipId: UUID, fromLane laneId: UUID) {
        removeAudioClipCallCount += 1
        if let laneIndex = timeline.audioLanes.firstIndex(where: { $0.id == laneId }) {
            timeline.audioLanes[laneIndex].clips.removeAll { $0.id == clipId }
        }
        onTimelineChanged?()
    }

    func addAudioLane(name: String) -> AudioLane {
        addAudioLaneCallCount += 1
        let lane = AudioLane(id: UUID(), name: name, clips: [])
        timeline.audioLanes.append(lane)
        onTimelineChanged?()
        return lane
    }

    func removeAudioLane(id: UUID) {
        removeAudioLaneCallCount += 1
        timeline.audioLanes.removeAll { $0.id == id }
        onTimelineChanged?()
    }

    func updateConfig(_ config: TimelineConfig) {
        updateConfigCallCount += 1
        timeline.config = config
        onTimelineChanged?()
    }

    func renameAudioLane(id: UUID, name: String) {}
    func setLaneMuted(id: UUID, muted: Bool) {}
    func setLaneSolo(id: UUID, solo: Bool) {}
    func setLaneVolume(id: UUID, volume: Double) {}
    func setLaneOutputOffset(id: UUID, offset: Int) {}
    func setLaneOutputDevice(id: UUID, deviceUID: String) {}
}
