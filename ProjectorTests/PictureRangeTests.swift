//
//  PictureRangeTests.swift
//  ProjectorTests
//
//  Where the timeline has picture, for the MTC IN "NO PICTURE" state.
//

import XCTest
@testable import Projector

final class PictureRangeTests: XCTestCase {

    private let url = URL(fileURLWithPath: "/tmp/Reel_1.mov")

    private func reel(at start: Int, _ duration: Int) -> VideoReel {
        VideoReel(sourceURL: url, timelineStartFrame: start, durationFrames: duration)
    }

    /// Two reels, 100..<200 and 300..<400, with a gap between.
    private var twoReels: Timeline {
        Timeline(videoReels: [reel(at: 300, 100), reel(at: 100, 100)])
    }

    func testNoReelsHasNoRangeAndNothingIsOutside() {
        let timeline = Timeline.empty
        XCTAssertNil(timeline.pictureFrameRange)
        XCTAssertFalse(timeline.isOutsidePicture(frame: 0))
        XCTAssertFalse(timeline.isOutsidePicture(frame: 5_000))
    }

    func testRangeSpansFirstStartToLastEnd() {
        XCTAssertEqual(twoReels.pictureFrameRange, 100..<400)
    }

    func testFrameBeforeFirstReelIsOutside() {
        XCTAssertTrue(twoReels.isOutsidePicture(frame: 99))
        XCTAssertTrue(twoReels.isOutsidePicture(frame: -10))
    }

    func testFramesInsideReelsAreNotOutside() {
        XCTAssertFalse(twoReels.isOutsidePicture(frame: 100))
        XCTAssertFalse(twoReels.isOutsidePicture(frame: 199))
        XCTAssertFalse(twoReels.isOutsidePicture(frame: 399))
    }

    func testGapBetweenReelsIsNotOutside() {
        XCTAssertFalse(twoReels.isOutsidePicture(frame: 200))
        XCTAssertFalse(twoReels.isOutsidePicture(frame: 299))
    }

    func testLastReelEndFrameAndBeyondAreOutside() {
        XCTAssertTrue(twoReels.isOutsidePicture(frame: 400))
        XCTAssertTrue(twoReels.isOutsidePicture(frame: 10_000))
    }

    /// A zero-length reel has no picture, so it neither starts nor extends the range.
    func testZeroDurationReelsAreIgnored() {
        let timeline = Timeline(videoReels: [reel(at: 50, 0), reel(at: 100, 100), reel(at: 500, 0)])
        XCTAssertEqual(timeline.pictureFrameRange, 100..<200)
        XCTAssertNil(Timeline(videoReels: [reel(at: 50, 0)]).pictureFrameRange)
    }
}
