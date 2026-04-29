//
//  IntegrationTests.swift
//  ProjectorTests
//
//  Integration tests for Projector components
//
//  Note: Full integration tests require complex setup with real managers
//  and playback engines. These tests focus on verifying component
//  compatibility and basic integration scenarios.
//

import XCTest
@testable import Projector
import SwiftTimecodeCore

@MainActor
final class IntegrationTests: XCTestCase {

    // MARK: - Timeline Integration Tests

    func testTimelineManagerWithDefaultTimeline() {
        // Given: Default timeline
        let manager = TimelineManager(timeline: .empty)

        // Then: Manager works with default config
        XCTAssertTrue(manager.timeline.videoReels.isEmpty)
        XCTAssertTrue(manager.timeline.audioLanes.isEmpty)
        XCTAssertEqual(manager.timeline.config.frameRate, .fps24)
    }

    func testTimelineManagerAddAudioLane() {
        // Given: Manager with empty timeline
        let manager = TimelineManager(timeline: .empty)

        // When: Add audio lane
        let lane = manager.addAudioLane(name: "Dialog")

        // Then: Lane is added
        XCTAssertEqual(manager.timeline.audioLanes.count, 1)
        XCTAssertEqual(lane.name, "Dialog")
    }

    // MARK: - Model Type Tests

    func testVideoReelSendable() {
        // Verify VideoReel is Sendable by using in concurrent context
        let reel = VideoReel(
            sourceURL: URL(fileURLWithPath: "/test/video.mov"),
            timelineStartFrame: 0,
            durationFrames: 1000,
            sourceStartFrame: 0
        )

        Task.detached {
            // This should compile if VideoReel is Sendable
            _ = reel.timelineStartFrame
        }
    }

    func testAudioClipSendable() {
        // Verify AudioClip is Sendable by using in concurrent context
        let clip = AudioClip(
            sourceURL: URL(fileURLWithPath: "/test/audio.wav"),
            timelineStartFrame: 0,
            durationFrames: 500,
            sourceStartFrame: 0,
            sourceType: .audioFile
        )

        Task.detached {
            // This should compile if AudioClip is Sendable
            _ = clip.durationFrames
        }
    }

    func testTimelineConfigSendable() {
        // Verify TimelineConfig is Sendable
        let startTC = Timecode(.components(h: 0, m: 0, s: 0, f: 0), at: .fps24, by: .clamping)
        let endTC = Timecode(.components(h: 1, m: 0, s: 0, f: 0), at: .fps24, by: .clamping)
        let config = TimelineConfig(
            startTimecode: startTC,
            endTimecode: endTC,
            frameRate: .fps24
        )

        Task.detached {
            // This should compile if TimelineConfig is Sendable
            _ = config.frameRate
        }
    }
}
