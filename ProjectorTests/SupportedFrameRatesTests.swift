//
//  SupportedFrameRatesTests.swift
//  ProjectorTests
//
//  The three rates picture is actually delivered at - 23.976, 24 and 25 - walked
//  through every conversion between a file arriving and a position being
//  reported: rate detection, timeline adoption, timecode placement, and what the
//  MTC readout says about an incoming stream.
//
//  Written to answer "do we support these three", after 25 fps was found landing
//  2:23:15 early. It found a second answer of no: a correctly configured 23.976
//  session accused itself of a frame rate mismatch, because MTC transmits 23.976
//  and 24 identically and the readout named the family as if it were the rate.
//

import XCTest
import MIDIKitSync
import SwiftTimecodeCore
@testable import Projector

final class SupportedFrameRatesTests: XCTestCase {

    /// The rates under test, with the frame rate a file at that rate measures as.
    private let rates: [(rate: TimecodeFrameRate, measured: Double)] = [
        (.fps23_976, 24000.0 / 1001.0),
        (.fps24, 24.0),
        (.fps25, 25.0)
    ]

    // MARK: - Detection

    /// A file's measured rate resolves to the rate it was shot at.
    func testMeasuredRateResolvesToItself() {
        for (rate, measured) in rates {
            XCTAssertEqual(
                TimecodeFrameRate.nearest(to: measured),
                rate,
                "\(rate.rawValue) measured as \(measured)"
            )
        }
    }

    /// `nominalFrameRate` is a `Float`, so it arrives with less precision than
    /// the rate it stands for.
    func testFloatPrecisionStillResolves() {
        for (rate, measured) in rates {
            let asFloat = Double(Float(measured))
            XCTAssertEqual(
                TimecodeFrameRate.nearest(to: asFloat),
                rate,
                "\(rate.rawValue) as Float: \(asFloat)"
            )
        }
    }

    // MARK: - Adoption

    /// The timeline keeps its start when it adopts an imported reel's rate.
    func testTimelineKeepsItsStartAdoptingEachRate() {
        for (rate, _) in rates {
            var config = TimelineConfig.default
            config.setFrameRate(rate)
            XCTAssertEqual(config.frameRate, rate)
            XCTAssertEqual(
                config.startTimecode.stringValue(),
                "00:59:50:00",
                "start moved adopting \(rate.rawValue)"
            )
        }
    }

    // MARK: - Placement

    /// A reel lands at its own timecode, at every rate.
    ///
    /// The gap is two seconds of programme, so the frame count differs by rate
    /// while the address does not - 48 frames at 23.976 and 24, 50 at 25.
    func testReelLandsAtItsOwnTimecode() {
        let expectedFrames: [TimecodeFrameRate: Int] = [.fps23_976: 48, .fps24: 48, .fps25: 50]

        for (rate, _) in rates {
            var config = TimelineConfig.default
            config.setFrameRate(rate)

            let reelStart = Timecode(.components(h: 0, m: 59, s: 52, f: 0), at: rate, by: .clamping)
            let placement = config.frame(for: reelStart)

            XCTAssertEqual(placement, expectedFrames[rate], "placement at \(rate.rawValue)")
            XCTAssertEqual(
                config.timecode(at: placement).stringValue(),
                "00:59:52:00",
                "reel head reads wrong at \(rate.rawValue)"
            )
        }
    }

    /// A file's embedded timecode crosses onto the timeline's grid intact.
    ///
    /// 23.976 and 24 share a grid, so the count is untouched between them. Only
    /// 25 is a different grid, and only there does the count change.
    func testEmbeddedTimecodeCrossesGridsCorrectly() {
        // 00:59:52:00 on the 24-label grid.
        let at23_976 = EmbeddedTimecodeResult(
            timecodeFrames: 3592 * 24,
            formattedTimecode: "00:59:52:00",
            source: .quickTimeTrack,
            frameRate: 24000.0 / 1001.0,
            isDropFrame: false
        )

        XCTAssertEqual(at23_976.convertedFrames(to: 24000.0 / 1001.0), 3592 * 24)
        XCTAssertEqual(at23_976.convertedFrames(to: 24.0), 3592 * 24, "23.976 and 24 share a grid")
        XCTAssertEqual(at23_976.convertedFrames(to: 25.0), 3592 * 25, "24 grid to 25 grid")

        // 00:59:52:00 on the 25-label grid, going the other way.
        let at25 = EmbeddedTimecodeResult(
            timecodeFrames: 3592 * 25,
            formattedTimecode: "00:59:52:00",
            source: .quickTimeTrack,
            frameRate: 25.0,
            isDropFrame: false
        )

        XCTAssertEqual(at25.convertedFrames(to: 24.0), 3592 * 24)
        XCTAssertEqual(at25.convertedFrames(to: 24000.0 / 1001.0), 3592 * 24)
    }

    // MARK: - What the reel's own timecode reads as

    /// The label a frame count spells is counted, not measured.
    ///
    /// A 90-minute reel at 23.976 is 129600 frames and reads 01:30:00:00. Divide
    /// by the real rate instead and it reads 01:30:05:11.
    func testDurationsCountLabelsNotSeconds() {
        XCTAssertEqual(TimecodeFrameRate.fps23_976.timecodeString(forFrameCount: 129_600, forceHours: true), "1:30:00:00")
        XCTAssertEqual(TimecodeFrameRate.fps24.timecodeString(forFrameCount: 129_600, forceHours: true), "1:30:00:00")
        XCTAssertEqual(TimecodeFrameRate.fps25.timecodeString(forFrameCount: 135_000, forceHours: true), "1:30:00:00")
    }

    // MARK: - MTC

    /// Each rate transmits on the MTC base its family uses.
    func testEachRateTransmitsOnItsFamily() {
        XCTAssertEqual(TimecodeFrameRate.fps23_976.mtcFrameRate, .mtc24)
        XCTAssertEqual(TimecodeFrameRate.fps24.mtcFrameRate, .mtc24)
        XCTAssertEqual(TimecodeFrameRate.fps25.mtcFrameRate, .mtc25)
    }

    /// The regression: a session in sync with itself must not report a mismatch.
    ///
    /// MTC cannot tell 23.976 from 24 - both go out as MTC 24 - so naming the
    /// family's integer member as the incoming rate turned the readout red on a
    /// correctly configured 23.976 session and told the user to change to 24.
    func testCompatibleRatesReportNoMismatch() {
        for (rate, _) in rates {
            let reported = rate.mtcFrameRate.reportedRate(forProject: rate)
            XCTAssertEqual(
                reported,
                rate,
                "\(rate.rawValue) project receiving its own MTC reported as \(reported.rawValue)"
            )
        }
    }

    /// 29.97 against 30 is the same trap, on the other NTSC family.
    func testNTSC30FamilyAlsoReportsNoMismatch() {
        XCTAssertEqual(MTCFrameRate.mtc30.reportedRate(forProject: .fps29_97), .fps29_97)
        XCTAssertEqual(MTCFrameRate.mtc30.reportedRate(forProject: .fps30), .fps30)
    }

    /// A genuine mismatch still resolves to a different rate, so it still shows.
    func testGenuineMismatchStillReports() {
        // 25 fps project, sender on a 24 family.
        XCTAssertEqual(MTCFrameRate.mtc24.reportedRate(forProject: .fps25), .fps24)
        XCTAssertNotEqual(MTCFrameRate.mtc24.reportedRate(forProject: .fps25), .fps25)

        // 24 fps project, sender on 25.
        XCTAssertEqual(MTCFrameRate.mtc25.reportedRate(forProject: .fps24), .fps25)
        XCTAssertEqual(MTCFrameRate.mtc25.reportedRate(forProject: .fps23_976), .fps25)

        // 24 fps project, sender on 30.
        XCTAssertEqual(MTCFrameRate.mtc30.reportedRate(forProject: .fps24), .fps30)
    }
}
