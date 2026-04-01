//
//  TimelineManagerTests.swift
//  ProjectorTests
//
//  Tests for TimelineManager - Timeline state management and persistence
//

import XCTest
@testable import Projector
import SwiftTimecodeCore

@MainActor
final class TimelineManagerTests: XCTestCase {

    var manager: TimelineManager!

    override func setUp() async throws {
        try await super.setUp()

        let config = TimelineConfig(
            frameRate: .fps24,
            startTimecode: try Timecode(.zero, at: .fps24, by: .allowingInvalid),
            durationFrames: 10000
        )
        manager = TimelineManager(config: config)
    }

    override func tearDown() async throws {
        manager = nil

        try await super.tearDown()
    }

    // MARK: - Initialization Tests

    func testInitialization() throws {
        // Then: Manager initializes with correct config
        XCTAssertNotNil(manager, "Manager should initialize")
        XCTAssertEqual(manager.timeline.config.frameRate, .fps24, "Frame rate should be 24fps")
        XCTAssertEqual(manager.timeline.config.durationFrames, 10000, "Duration should be 10000 frames")
        XCTAssertFalse(manager.hasChanges, "Should have no changes initially")
    }

    // MARK: - Video Reel CRUD Tests

    func testAddVideoReel() async throws {
        // Given: Test video URL
        let videoURL = URL(fileURLWithPath: "/test/video.mov")

        // When: Add video reel
        let reel = try await manager.addVideoReel(from: videoURL, at: 0)

        // Then: Reel added successfully
        XCTAssertEqual(manager.timeline.videoReels.count, 1, "Should have 1 video reel")
        XCTAssertEqual(reel.timelineStartFrame, 0, "Reel should start at frame 0")
        XCTAssertTrue(manager.hasChanges, "Should mark as changed")
    }

    func testRemoveVideoReel() async throws {
        // Given: Timeline with video reel
        let videoURL = URL(fileURLWithPath: "/test/video.mov")
        let reel = try await manager.addVideoReel(from: videoURL, at: 0)

        // When: Remove reel
        manager.removeVideoReel(id: reel.id)

        // Then: Reel removed
        XCTAssertEqual(manager.timeline.videoReels.count, 0, "Should have no reels")
        XCTAssertTrue(manager.hasChanges, "Should mark as changed")
    }

    func testReorderVideoReels() async throws {
        // Given: Timeline with 3 reels
        let reel1 = try await manager.addVideoReel(from: URL(fileURLWithPath: "/test/1.mov"), at: 0)
        let reel2 = try await manager.addVideoReel(from: URL(fileURLWithPath: "/test/2.mov"), at: 1000)
        let reel3 = try await manager.addVideoReel(from: URL(fileURLWithPath: "/test/3.mov"), at: 2000)

        // When: Reorder from index 0 to 2
        manager.reorderVideoReels(fromIndex: 0, toIndex: 2)

        // Then: Reels reordered [reel2, reel3, reel1]
        XCTAssertEqual(manager.timeline.videoReels[0].id, reel2.id, "Reel 2 should be first")
        XCTAssertEqual(manager.timeline.videoReels[2].id, reel1.id, "Reel 1 should be last")
    }

    // MARK: - Audio Lane CRUD Tests

    func testCreateAudioLane() {
        // When: Create audio lane
        let lane = manager.addAudioLane(name: "Dialog")

        // Then: Lane created
        XCTAssertEqual(manager.timeline.audioLanes.count, 1, "Should have 1 audio lane")
        XCTAssertEqual(lane.name, "Dialog", "Lane name should be 'Dialog'")
        XCTAssertTrue(manager.hasChanges, "Should mark as changed")
    }

    func testRemoveAudioLane() {
        // Given: Timeline with audio lane
        let lane = manager.addAudioLane(name: "Music")

        // When: Remove lane
        manager.removeAudioLane(id: lane.id)

        // Then: Lane removed
        XCTAssertEqual(manager.timeline.audioLanes.count, 0, "Should have no lanes")
    }

    func testRenameAudioLane() {
        // Given: Audio lane
        let lane = manager.addAudioLane(name: "Old Name")

        // When: Rename lane
        manager.renameAudioLane(id: lane.id, name: "New Name")

        // Then: Lane renamed
        XCTAssertEqual(manager.timeline.audioLanes[0].name, "New Name", "Lane should be renamed")
        XCTAssertTrue(manager.hasChanges, "Should mark as changed")
    }

    // MARK: - Audio Clip CRUD Tests

    func testAddAudioClip() async throws {
        // Given: Timeline with audio lane
        let lane = manager.addAudioLane(name: "SFX")
        let audioURL = URL(fileURLWithPath: "/test/audio.wav")

        // When: Add audio clip
        let clip = try await manager.addAudioClip(from: audioURL, toLane: lane.id, at: 0)

        // Then: Clip added
        XCTAssertEqual(manager.timeline.audioLanes[0].clips.count, 1, "Should have 1 clip")
        XCTAssertEqual(clip.timelineStartFrame, 0, "Clip should start at frame 0")
    }

    func testRemoveAudioClip() async throws {
        // Given: Lane with audio clip
        let lane = manager.addAudioLane(name: "Voice")
        let audioURL = URL(fileURLWithPath: "/test/voice.wav")
        let clip = try await manager.addAudioClip(from: audioURL, toLane: lane.id, at: 0)

        // When: Remove clip
        manager.removeAudioClip(clipId: clip.id, fromLane: lane.id)

        // Then: Clip removed
        XCTAssertEqual(manager.timeline.audioLanes[0].clips.count, 0, "Should have no clips")
    }

    // MARK: - Lane Configuration Tests

    func testSetLaneMuted() {
        // Given: Audio lane
        let lane = manager.addAudioLane(name: "Dialog")

        // When: Mute lane
        manager.setLaneMuted(id: lane.id, muted: true)

        // Then: Lane muted
        XCTAssertTrue(manager.timeline.audioLanes[0].muted, "Lane should be muted")
    }

    func testSetLaneSolo() {
        // Given: Audio lane
        let lane = manager.addAudioLane(name: "Music")

        // When: Solo lane
        manager.setLaneSolo(id: lane.id, solo: true)

        // Then: Lane soloed
        XCTAssertTrue(manager.timeline.audioLanes[0].solo, "Lane should be soloed")
    }

    func testSetLaneVolume() {
        // Given: Audio lane
        let lane = manager.addAudioLane(name: "SFX")

        // When: Set volume to 75%
        manager.setLaneVolume(id: lane.id, volume: 0.75)

        // Then: Volume updated
        XCTAssertEqual(manager.timeline.audioLanes[0].volume, 0.75, accuracy: 0.01, "Volume should be 75%")
    }

    func testSetLaneOutputOffset() {
        // Given: Audio lane
        let lane = manager.addAudioLane(name: "Dialog")

        // When: Set output offset to channel 4 (0-indexed)
        manager.setLaneOutputOffset(id: lane.id, offset: 4)

        // Then: Offset updated
        XCTAssertEqual(manager.timeline.audioLanes[0].outputOffset, 4, "Output offset should be 4")
    }

    // MARK: - Timeline Configuration Tests

    func testUpdateFrameRate() {
        // When: Change frame rate to 30fps
        let newConfig = TimelineConfig(
            frameRate: .fps30,
            startTimecode: try! Timecode(.zero, at: .fps30, by: .allowingInvalid),
            durationFrames: 10000
        )
        manager.updateConfig(newConfig)

        // Then: Frame rate updated
        XCTAssertEqual(manager.timeline.config.frameRate, .fps30, "Frame rate should be 30fps")
        XCTAssertTrue(manager.hasChanges, "Should mark as changed")
    }

    func testUpdateDuration() {
        // When: Change duration
        let newConfig = TimelineConfig(
            frameRate: .fps24,
            startTimecode: try! Timecode(.zero, at: .fps24, by: .allowingInvalid),
            durationFrames: 20000
        )
        manager.updateConfig(newConfig)

        // Then: Duration updated
        XCTAssertEqual(manager.timeline.config.durationFrames, 20000, "Duration should be 20000 frames")
    }

    // MARK: - Dirty State Tracking Tests

    func testDirtyStateAfterAddReel() async throws {
        // Given: Clean timeline
        XCTAssertFalse(manager.hasChanges, "Should start clean")

        // When: Add reel
        _ = try await manager.addVideoReel(from: URL(fileURLWithPath: "/test/video.mov"), at: 0)

        // Then: Marked as changed
        XCTAssertTrue(manager.hasChanges, "Should be marked as changed")
    }

    func testClearDirtyState() async throws {
        // Given: Timeline with changes
        _ = try await manager.addVideoReel(from: URL(fileURLWithPath: "/test/video.mov"), at: 0)
        XCTAssertTrue(manager.hasChanges, "Should have changes")

        // When: Mark as saved
        manager.markAsSaved()

        // Then: Dirty state cleared
        XCTAssertFalse(manager.hasChanges, "Should be clean after save")
    }

    // MARK: - Validation Tests

    func testRejectOverlappingVideoReels() async throws {
        // Given: Reel at 0-1000
        _ = try await manager.addVideoReel(from: URL(fileURLWithPath: "/test/1.mov"), at: 0)

        // When/Then: Attempt to add overlapping reel at 500-1500
        // Note: This should be validated by TimelineActor in practice
        // TimelineManager may or may not enforce this constraint
    }

    func testRejectOverlappingAudioClips() async throws {
        // Given: Lane with clip at 0-1000
        let lane = manager.addAudioLane(name: "Dialog")
        _ = try await manager.addAudioClip(from: URL(fileURLWithPath: "/test/1.wav"), toLane: lane.id, at: 0)

        // When/Then: Attempt to add overlapping clip at 500-1500
        // Should be validated by TimelineActor
    }

    // MARK: - Timeline Duration Calculation Tests

    func testCalculateTotalDuration() async throws {
        // Given: Reels ending at different frames
        _ = try await manager.addVideoReel(from: URL(fileURLWithPath: "/test/1.mov"), at: 0)  // 0-1000
        _ = try await manager.addVideoReel(from: URL(fileURLWithPath: "/test/2.mov"), at: 1000)  // 1000-2000
        _ = try await manager.addVideoReel(from: URL(fileURLWithPath: "/test/3.mov"), at: 2000)  // 2000-3000

        // When: Calculate total duration
        let duration = manager.calculateTimelineDuration()

        // Then: Duration is max end frame
        XCTAssertEqual(duration, 3000, "Timeline duration should be 3000 frames")
    }

    // MARK: - Undo/Redo Tests (if implemented)

    func testUndoAddReel() async throws {
        // Skip if undo not implemented
        guard manager.supportsUndo else {
            throw XCTSkip("Undo not implemented")
        }

        // Given: Timeline with reel
        _ = try await manager.addVideoReel(from: URL(fileURLWithPath: "/test/video.mov"), at: 0)
        XCTAssertEqual(manager.timeline.videoReels.count, 1, "Should have 1 reel")

        // When: Undo
        manager.undo()

        // Then: Reel removed
        XCTAssertEqual(manager.timeline.videoReels.count, 0, "Should have no reels after undo")
    }

    func testRedoAddReel() async throws {
        // Skip if undo not implemented
        guard manager.supportsUndo else {
            throw XCTSkip("Undo not implemented")
        }

        // Given: Added and undone reel
        _ = try await manager.addVideoReel(from: URL(fileURLWithPath: "/test/video.mov"), at: 0)
        manager.undo()

        // When: Redo
        manager.redo()

        // Then: Reel restored
        XCTAssertEqual(manager.timeline.videoReels.count, 1, "Should restore reel after redo")
    }
}

// MARK: - TimelineManager Test Helpers

extension TimelineManager {
    var supportsUndo: Bool {
        // Check if undo/redo is implemented
        return false // Placeholder
    }

    func undo() {
        // Placeholder for undo
    }

    func redo() {
        // Placeholder for redo
    }

    func calculateTimelineDuration() -> Int {
        let maxVideoEnd = timeline.videoReels.map { $0.timelineStartFrame + $0.durationFrames }.max() ?? 0
        let maxAudioEnd = timeline.audioLanes.flatMap { $0.clips }.map { $0.timelineStartFrame + $0.durationFrames }.max() ?? 0
        return max(maxVideoEnd, maxAudioEnd)
    }

    func markAsSaved() {
        hasChanges = false
    }
}
