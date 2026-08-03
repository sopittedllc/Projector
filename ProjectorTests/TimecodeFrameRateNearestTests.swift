//
//  TimecodeFrameRateNearestTests.swift
//  ProjectorTests
//
//  Tests for matching a measured frame rate to a timecode rate.
//
//  A true 24 fps reel shipped as 23.976 because the import searched for the
//  first rate within half a frame instead of the nearest one, and `allCases`
//  leads with 23.976. Nothing caught it because nothing tested it: the error is
//  1000/1001, so picture and timecode agree at the head of a reel and only pull
//  apart as it runs.
//

import XCTest
import SwiftTimecodeCore
@testable import Projector

final class TimecodeFrameRateNearestTests: XCTestCase {

    // MARK: - Exact rates

    /// Every rate the app offers must match itself exactly.
    ///
    /// This is the regression: each integer rate is preceded in `allCases` by
    /// its NTSC cousin, close enough to win a first-match search.
    func testExactRatesMatchThemselves() {
        for rate in TimecodeFrameRate.allCases {
            let matched = TimecodeFrameRate.nearest(to: rate.fps)
            XCTAssertNotNil(matched, "no match for \(rate.rawValue)")
            XCTAssertEqual(
                matched?.fps,
                rate.fps,
                "\(rate.rawValue) (\(rate.fps) fps) matched \(matched?.rawValue ?? "nil")"
            )
        }
    }

    /// The specific pairs the first-match search got wrong.
    func testIntegerRatesDoNotCollapseToTheirNTSCCousins() {
        XCTAssertEqual(TimecodeFrameRate.nearest(to: 24.0), .fps24)
        XCTAssertEqual(TimecodeFrameRate.nearest(to: 25.0), .fps25)
        XCTAssertEqual(TimecodeFrameRate.nearest(to: 30.0), .fps30)
        XCTAssertEqual(TimecodeFrameRate.nearest(to: 48.0), .fps48)
        XCTAssertEqual(TimecodeFrameRate.nearest(to: 50.0), .fps50)
    }

    /// And the NTSC rates still resolve to themselves, not up to the integer.
    ///
    /// Compared as cases, not as `fps` values: the library reports the exact
    /// ratio (30000/1001 = 29.97002997...), so an equality against the rounded
    /// literal fails for reasons that have nothing to do with matching.
    func testNTSCRatesStillMatch() {
        XCTAssertEqual(TimecodeFrameRate.nearest(to: 23.976), .fps23_976)
        XCTAssertEqual(TimecodeFrameRate.nearest(to: 29.97), .fps29_97)
        XCTAssertEqual(TimecodeFrameRate.nearest(to: 47.952), .fps47_952)
    }

    // MARK: - Measurement noise

    /// `nominalFrameRate` is a `Float`, so it arrives slightly off.
    func testNearbyMeasurementsSnapToTheIntendedRate() {
        XCTAssertEqual(TimecodeFrameRate.nearest(to: 23.9760017), .fps23_976)
        XCTAssertEqual(TimecodeFrameRate.nearest(to: 24.000002), .fps24)
        XCTAssertEqual(TimecodeFrameRate.nearest(to: 29.969999), .fps29_97)
    }

    /// The midpoint between two rates has to resolve, not crash or return nil.
    func testMidpointResolvesToOneSide() {
        let midpoint = (23.976 + 24.0) / 2
        XCTAssertNotNil(TimecodeFrameRate.nearest(to: midpoint))
    }

    // MARK: - Ties

    /// Drop frame cannot be inferred from a rate, so a tie takes non-drop.
    ///
    /// 29.97 and 29.97d are the same speed; only the file's timecode track says
    /// which counting scheme it uses.
    func testDropFrameTiesGoToNonDrop() {
        XCTAssertEqual(TimecodeFrameRate.nearest(to: 29.97)?.isDrop, false)
        XCTAssertEqual(TimecodeFrameRate.nearest(to: 30.0)?.isDrop, false)
        XCTAssertEqual(TimecodeFrameRate.nearest(to: 59.94)?.isDrop, false)
    }

    // MARK: - Out of range

    /// A rate the app has no case for falls back rather than guessing.
    func testRatesOutsideToleranceDoNotMatch() {
        XCTAssertNil(TimecodeFrameRate.nearest(to: 15.0))
        XCTAssertNil(TimecodeFrameRate.nearest(to: 0.0))
        XCTAssertNil(TimecodeFrameRate.nearest(to: 240.0))
    }

    // MARK: - Consequence

    /// The drift the mismatch caused, stated as the thing the user saw.
    ///
    /// A 24 fps reel read as 23.976 converts frames to seconds 1000/1001 too
    /// slowly, so the picture runs ahead of the position readout by a frame
    /// roughly every second of programme.
    func testCorrectRateKeepsSourceTimeAlignedAcrossALongReel() throws {
        let rate = try XCTUnwrap(TimecodeFrameRate.nearest(to: 24.0))
        let fps = rate.fps
        XCTAssertEqual(fps, 24.0)

        // 14:48 into the reel - where the drift was first reported.
        let elapsedSeconds = 888.0
        let frames = elapsedSeconds * 24.0
        XCTAssertEqual(frames / fps, elapsedSeconds, accuracy: 0.0001)

        // The same conversion at 23.976 is what put the picture 21 frames out.
        let wrong = frames / 23.976
        XCTAssertEqual((wrong - elapsedSeconds) * 24.0, 21.33, accuracy: 0.05)
    }
}
