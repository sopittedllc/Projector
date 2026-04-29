//
//  PlaybackEngineTests.swift
//  ProjectorTests
//
//  Tests for PlaybackEngine - Video/audio playback control
//
//  Note: PlaybackEngine has complex dependencies on AVFoundation
//  and requires actual media files. These tests focus on verifying
//  public API and observable behaviors.
//

import XCTest
@testable import Projector
import SwiftTimecodeCore

@MainActor
final class PlaybackEngineTests: XCTestCase {

    // MARK: - Initialization Tests

    func testPlaybackEngineInitialization() {
        // Given: Empty timeline
        let timeline = Timeline.empty

        // When: Create playback engine
        let engine = PlaybackEngine(timeline: timeline)

        // Then: Engine initializes with correct defaults
        XCTAssertNotNil(engine)
        XCTAssertFalse(engine.isPlaying, "Should not be playing initially")
    }

    func testPlaybackEngineTimeline() {
        // Given: Timeline
        let timeline = Timeline.empty

        // When: Create engine and check timeline
        let engine = PlaybackEngine(timeline: timeline)

        // Then: Timeline is set
        XCTAssertEqual(engine.timeline.config.frameRate, .fps24)
    }

    // MARK: - Frame Rate Tests

    func testTimelineFrameRateDefault() {
        // Given: Engine with default timeline
        let engine = PlaybackEngine(timeline: .empty)

        // Then: Timeline frame rate is 24fps
        XCTAssertEqual(engine.timeline.config.frameRate, .fps24, "Should default to 24fps")
    }

    // MARK: - Playback State Tests

    func testInitialPlaybackState() {
        // Given: New engine
        let engine = PlaybackEngine(timeline: .empty)

        // Then: Should not be playing
        XCTAssertFalse(engine.isPlaying)
    }

    // MARK: - Current Frame Tests

    func testInitialCurrentFrame() {
        // Given: New engine
        let engine = PlaybackEngine(timeline: .empty)

        // Then: Should start at frame 0
        XCTAssertEqual(engine.currentFrame, 0)
    }
}
