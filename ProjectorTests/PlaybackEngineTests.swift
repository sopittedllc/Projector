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

    func testMTCPreSyncThenSyncStartsTransport() {
        let engine = PlaybackEngine(timeline: .empty)

        engine.setMTCSynced(true, controlPlayback: false)
        XCTAssertTrue(engine.isMTCSynced)
        XCTAssertFalse(engine.isPlaying)

        engine.setMTCSynced(true, controlPlayback: true)
        XCTAssertTrue(engine.isPlaying)
    }

    func testMTCUsesAbsoluteTimelineStartTimecode() {
        let frameRate = TimecodeFrameRate.fps24
        let start = Timecode(.components(h: 1, m: 0, s: 0, f: 0), at: frameRate, by: .clamping)
        let end = Timecode(.components(h: 1, m: 1, s: 0, f: 0), at: frameRate, by: .clamping)
        let timeline = Timeline(
            config: TimelineConfig(startTimecode: start, endTimecode: end, frameRate: frameRate)
        )
        let engine = PlaybackEngine(timeline: timeline)
        let target = timeline.config.timecode(at: 240)

        engine.syncToMTC(target, direction: .forwards)

        XCTAssertEqual(engine.currentFrame, 240)
        XCTAssertEqual(engine.currentTimecode, target)
    }

    func testMTCChaseHardSeeksAtTwoFramesOfPhaseError() {
        let action = MTCChaseController.action(
            targetFrame: 102,
            actualFrame: 100,
            direction: .forwards,
            isPlaying: true,
            isDiscontinuous: false,
            canSeek: true
        )

        XCTAssertEqual(action, .seek(frame: 102, resume: true))
    }

    func testMTCChaseUsesBoundedRateCorrectionInsideOneFrame() {
        XCTAssertEqual(
            MTCChaseController.action(
                targetFrame: 101,
                actualFrame: 100,
                direction: .forwards,
                isPlaying: true,
                isDiscontinuous: false,
                canSeek: true
            ),
            .play(rate: 1.02)
        )

        XCTAssertEqual(
            MTCChaseController.action(
                targetFrame: 90,
                actualFrame: 100,
                direction: .forwards,
                isPlaying: true,
                isDiscontinuous: false,
                canSeek: false
            ),
            .play(rate: 0.96)
        )
    }

    func testReverseMTCUsesExactNonResumingSeek() {
        let action = MTCChaseController.action(
            targetFrame: 99,
            actualFrame: 100,
            direction: .backwards,
            isPlaying: true,
            isDiscontinuous: false,
            canSeek: true
        )

        XCTAssertEqual(action, .seek(frame: 99, resume: false))
    }

    func testMTCAudioReconcilesAtClipBoundariesWithoutReelChange() {
        let firstClip = UUID()
        let secondClip = UUID()

        XCTAssertTrue(MTCAudioReconciliationPolicy.shouldReconcile(
            previousActiveIDs: [firstClip],
            activeIDs: [secondClip],
            lastSyncFrame: 100,
            currentFrame: 101,
            framesPerCorrection: 24,
            force: false,
            resumedFromReverse: false
        ))

        XCTAssertFalse(MTCAudioReconciliationPolicy.shouldReconcile(
            previousActiveIDs: [firstClip],
            activeIDs: [firstClip],
            lastSyncFrame: 100,
            currentFrame: 101,
            framesPerCorrection: 24,
            force: false,
            resumedFromReverse: false
        ))
    }

    func testMTCAudioPeriodicallyCorrectsAndResumesAfterReverse() {
        let clip = UUID()

        XCTAssertTrue(MTCAudioReconciliationPolicy.shouldReconcile(
            previousActiveIDs: [clip],
            activeIDs: [clip],
            lastSyncFrame: 100,
            currentFrame: 124,
            framesPerCorrection: 24,
            force: false,
            resumedFromReverse: false
        ))

        XCTAssertTrue(MTCAudioReconciliationPolicy.shouldReconcile(
            previousActiveIDs: [clip],
            activeIDs: [clip],
            lastSyncFrame: 124,
            currentFrame: 123,
            framesPerCorrection: 24,
            force: false,
            resumedFromReverse: true
        ))
    }
}
