//
//  TimelineConfigFrameRateTests.swift
//  ProjectorTests
//
//  Tests for re-expressing a timeline at another frame rate.
//
//  A 25 fps reel imported into a fresh project landed 2:23:15 early. The
//  timeline adopted the reel's rate by carrying its bounds across as frame
//  counts, so the default start - 86160 frames, 00:59:50:00 at 24 fps - became
//  00:57:26:10 when those same frames were counted at 25. Every timecode the
//  timeline reported was then wrong by that difference, for the whole reel.
//

import XCTest
import SwiftTimecodeCore
@testable import Projector

final class TimelineConfigFrameRateTests: XCTestCase {

    // MARK: - Bounds survive the rate change

    /// The regression: the start of the timeline keeps its clock, not its count.
    func testDefaultStartKeepsItsTimecodeAt25() {
        var config = TimelineConfig.default
        XCTAssertEqual(config.startTimecode.stringValue(), "00:59:50:00")

        config.setFrameRate(.fps25)

        XCTAssertEqual(config.frameRate, .fps25)
        XCTAssertEqual(config.startTimecode.stringValue(), "00:59:50:00")
        XCTAssertEqual(config.endTimecode.stringValue(), "02:59:50:00")
    }

    /// Frame counts are expected to change - that is the point.
    func testFrameCountIsRecountedAtTheNewRate() {
        var config = TimelineConfig.default
        XCTAssertEqual(config.startTimecode.frameCount.wholeFrames, 3590 * 24)

        config.setFrameRate(.fps25)

        XCTAssertEqual(config.startTimecode.frameCount.wholeFrames, 3590 * 25)
    }

    /// Every rate the timeline offers, in both directions, keeps the clock.
    func testBoundsSurviveEveryRate() {
        let rates: [TimecodeFrameRate] = [.fps23_976, .fps24, .fps25, .fps29_97, .fps30, .fps48, .fps50, .fps60]

        for rate in rates {
            var config = TimelineConfig.default
            config.setFrameRate(rate)
            XCTAssertEqual(
                config.startTimecode.stringValue(),
                "00:59:50:00",
                "start moved when changing to \(rate.stringValueVerbose)"
            )

            config.setFrameRate(.fps24)
            XCTAssertEqual(
                config.startTimecode.stringValue(),
                "00:59:50:00",
                "start moved coming back from \(rate.stringValueVerbose)"
            )
        }
    }

    /// A frames field with nowhere to go at the slower rate rolls into the next
    /// second - under a frame of real time, and only for a bound sitting on the
    /// last frame of a second.
    func testFramesFieldRollsOverGoingToASlowerRate() {
        var config = TimelineConfig(
            startTimecode: Timecode(.components(h: 0, m: 59, s: 50, f: 24), at: .fps25, by: .clamping),
            endTimecode: Timecode(.components(h: 2, m: 59, s: 50, f: 0), at: .fps25, by: .clamping),
            frameRate: .fps25
        )

        config.setFrameRate(.fps24)

        XCTAssertEqual(config.startTimecode.stringValue(), "00:59:51:00")
    }

    /// Changing to the rate already in force does nothing.
    func testSameRateIsANoOp() {
        var config = TimelineConfig.default
        let before = config
        config.setFrameRate(.fps24)
        XCTAssertEqual(config, before)
    }

    // MARK: - What the reel is then addressed against

    /// A reel at 00:59:52:00 lands 50 frames into a 25 fps timeline starting
    /// at 00:59:50:00 - the two seconds between them, counted at 25.
    ///
    /// The frame-count conversion put it at 48 frames past a start that had
    /// itself slipped to 00:57:26:10, reading 00:57:28:08.
    func testReelPlacementAgainstTheRetimedStart() {
        var config = TimelineConfig.default
        config.setFrameRate(.fps25)

        let reelStart = Timecode(.components(h: 0, m: 59, s: 52, f: 0), at: .fps25, by: .clamping)
        let placement = config.frame(for: reelStart)

        XCTAssertEqual(placement, 50)
        XCTAssertEqual(config.timecode(at: placement).stringValue(), "00:59:52:00")
    }
}
