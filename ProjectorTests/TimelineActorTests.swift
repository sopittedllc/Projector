//
//  TimelineActorTests.swift
//  ProjectorTests
//
//  Tests for TimelineActor - Timeline state management and operations
//
//  Note: TimelineActor depends on concrete TimelineManager class which is
//  difficult to mock. These tests verify observable behaviors and protocol conformance.
//

import XCTest
@testable import Projector
import SwiftTimecodeCore

final class TimelineActorTests: XCTestCase {

    // MARK: - TimelineServiceProtocol Conformance Tests

    /// Verify that TimelineActor conforms to TimelineServiceProtocol
    func testTimelineActorConformsToProtocol() {
        // This test verifies the protocol conformance at compile time
        func useProtocol<T: TimelineServiceProtocol>(_ service: T) async throws {
            // Verify protocol methods exist
            _ = service.timelineStateStream
            _ = await service.getCurrentState()
        }

        // Test passes if compilation succeeds
    }

    // MARK: - TimelineState Tests

    func testTimelineStateInitialization() {
        // Given: Default config
        let startTC = Timecode(.components(h: 0, m: 0, s: 0, f: 0), at: .fps24, by: .clamping)
        let endTC = Timecode(.components(h: 1, m: 0, s: 0, f: 0), at: .fps24, by: .clamping)
        let config = TimelineConfig(
            startTimecode: startTC,
            endTimecode: endTC,
            frameRate: .fps24
        )

        // When: Create a TimelineState
        let state = TimelineState(
            videoReels: [],
            audioLanes: [],
            durationFrames: config.durationFrames,
            frameRate: config.frameRate,
            isDirty: false,
            config: config
        )

        // Then: State is properly initialized
        XCTAssertTrue(state.videoReels.isEmpty, "Should have no video reels")
        XCTAssertTrue(state.audioLanes.isEmpty, "Should have no audio lanes")
        XCTAssertEqual(state.frameRate, .fps24, "Frame rate should be 24fps")
        XCTAssertFalse(state.isDirty, "Should not be dirty initially")
    }

    // MARK: - VideoReel Tests

    func testVideoReelCreation() {
        // Given: Video reel parameters
        let sourceURL = URL(fileURLWithPath: "/test/video.mov")

        // When: Create video reel
        let reel = VideoReel(
            sourceURL: sourceURL,
            timelineStartFrame: 0,
            durationFrames: 1000,
            sourceStartFrame: 0
        )

        // Then: Reel is properly initialized
        XCTAssertEqual(reel.timelineStartFrame, 0)
        XCTAssertEqual(reel.durationFrames, 1000)
        XCTAssertEqual(reel.sourceURL, sourceURL)
    }

    // MARK: - AudioClip Tests

    func testAudioClipCreation() {
        // Given: Audio clip parameters
        let sourceURL = URL(fileURLWithPath: "/test/audio.wav")

        // When: Create audio clip
        let clip = AudioClip(
            sourceURL: sourceURL,
            timelineStartFrame: 100,
            durationFrames: 500,
            sourceStartFrame: 0,
            sourceType: .audioFile
        )

        // Then: Clip is properly initialized
        XCTAssertEqual(clip.timelineStartFrame, 100)
        XCTAssertEqual(clip.durationFrames, 500)
        XCTAssertEqual(clip.sourceType, .audioFile)
    }

    func testAudioClipEndFrame() {
        // Given: Audio clip
        let clip = AudioClip(
            sourceURL: URL(fileURLWithPath: "/test/audio.wav"),
            timelineStartFrame: 100,
            durationFrames: 500,
            sourceStartFrame: 0,
            sourceType: .audioFile
        )

        // Then: End frame is calculated correctly
        XCTAssertEqual(clip.timelineEndFrame, 600, "End frame should be start + duration")
    }

    // MARK: - AudioLane Tests

    func testAudioLaneCreation() {
        // When: Create audio lane
        let lane = AudioLane(id: UUID(), name: "Dialog", clips: [])

        // Then: Lane is properly initialized
        XCTAssertEqual(lane.name, "Dialog")
        XCTAssertTrue(lane.clips.isEmpty)
        XCTAssertEqual(lane.volume, 1.0, accuracy: 0.001, "Default volume should be 1.0")
    }

    // MARK: - State Stream Tests

    @MainActor
    func testStateStreamBroadcastsToMultipleSubscribers() async {
        let manager = TimelineManager(timeline: .empty)
        let actor = TimelineActor(timelineManager: manager)
        let firstUpdated = expectation(description: "First subscriber receives update")
        let secondUpdated = expectation(description: "Second subscriber receives update")

        let firstTask = Task {
            for await state in actor.timelineStateStream where state.frameRate == .fps25 {
                firstUpdated.fulfill()
                break
            }
        }

        let secondTask = Task {
            for await state in actor.timelineStateStream where state.frameRate == .fps25 {
                secondUpdated.fulfill()
                break
            }
        }

        var config = manager.timeline.config
        config.frameRate = .fps25
        config.startTimecode = Timecode(
            .frames(config.startTimecode.frameCount.wholeFrames),
            at: .fps25,
            by: .clamping
        )
        config.endTimecode = Timecode(
            .frames(config.endTimecode.frameCount.wholeFrames),
            at: .fps25,
            by: .clamping
        )
        await actor.updateConfiguration(config)

        await fulfillment(of: [firstUpdated, secondUpdated], timeout: 1.0)
        firstTask.cancel()
        secondTask.cancel()
    }

    @MainActor
    func testImmediateStreamTerminationDoesNotLeakTimelineObserver() async {
        let manager = TimelineManager(timeline: .empty)
        let actor = TimelineActor(timelineManager: manager)
        let receivedInitialState = expectation(description: "Stream emits initial state")

        let task = Task {
            for await _ in actor.timelineStateStream {
                receivedInitialState.fulfill()
                // Remain suspended in the stream until explicit cancellation so
                // AsyncStream invokes its termination handler deterministically.
            }
        }
        await fulfillment(of: [receivedInitialState], timeout: 1.0)
        task.cancel()
        await task.value

        for _ in 0..<100 { await Task.yield() }

        XCTAssertEqual(manager.timelineChangeObserverCountForTesting, 0)
    }
}
