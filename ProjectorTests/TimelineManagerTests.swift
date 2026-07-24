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

        let startTC = Timecode(.components(h: 0, m: 0, s: 0, f: 0), at: .fps24, by: .clamping)
        let endTC = Timecode(.components(h: 0, m: 6, s: 56, f: 16), at: .fps24, by: .clamping) // 10000 frames at 24fps
        let config = TimelineConfig(
            startTimecode: startTC,
            endTimecode: endTC,
            frameRate: .fps24
        )
        let timeline = Timeline(config: config, videoReels: [], audioLanes: [])
        manager = TimelineManager(timeline: timeline)
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
    }

    // MARK: - Audio Lane CRUD Tests

    func testCreateAudioLane() {
        // When: Create audio lane
        let lane = manager.addAudioLane(name: "Dialog")

        // Then: Lane created
        XCTAssertEqual(manager.timeline.audioLanes.count, 1, "Should have 1 audio lane")
        XCTAssertEqual(lane.name, "Dialog", "Lane name should be 'Dialog'")
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
    }

    func testSetLaneVolume() {
        // Given: Audio lane
        let lane = manager.addAudioLane(name: "SFX")

        // When: Set volume to 75%
        manager.setLaneVolume(id: lane.id, volume: 0.75)

        // Then: Volume updated
        XCTAssertEqual(manager.timeline.audioLanes[0].volume, 0.75, accuracy: 0.01, "Volume should be 75%")
    }

    // MARK: - Timeline Configuration Tests

    func testUpdateFrameRate() {
        // When: Change frame rate to 30fps
        let startTC = Timecode(.components(h: 0, m: 0, s: 0, f: 0), at: .fps30, by: .clamping)
        let endTC = Timecode(.components(h: 0, m: 5, s: 33, f: 10), at: .fps30, by: .clamping) // ~10000 frames at 30fps
        let newConfig = TimelineConfig(
            startTimecode: startTC,
            endTimecode: endTC,
            frameRate: .fps30
        )
        manager.updateConfig(newConfig)

        // Then: Frame rate updated
        XCTAssertEqual(manager.timeline.config.frameRate, .fps30, "Frame rate should be 30fps")
    }

    func testPrimaryCallbackAndAdditionalObserverBothReceiveChanges() {
        var primaryCallbackCount = 0
        var observerCallbackCount = 0

        manager.onTimelineChanged = {
            primaryCallbackCount += 1
        }
        let observerID = manager.addTimelineChangeObserver {
            observerCallbackCount += 1
        }

        _ = manager.addAudioLane(name: "Dialog")

        XCTAssertEqual(primaryCallbackCount, 1)
        XCTAssertEqual(observerCallbackCount, 1)

        manager.removeTimelineChangeObserver(id: observerID)
        _ = manager.addAudioLane(name: "Music")

        XCTAssertEqual(primaryCallbackCount, 2)
        XCTAssertEqual(observerCallbackCount, 1)
    }

    // MARK: - Timeline Duration Calculation Tests

    func testCalculateTotalDuration() {
        // Given: Multiple audio lanes with clips would have different end points
        // For now just verify the config-based duration
        XCTAssertEqual(manager.timeline.config.durationFrames, 10000, "Duration should be 10000 frames")
    }
}
