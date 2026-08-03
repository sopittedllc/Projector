//
//  EmbeddedTimecodeResultTests.swift
//  ProjectorTests
//
//  Tests for carrying a detected timecode onto the timeline's frame rate.
//
//  A reel landed four seconds late because its timecode was rescaled by the
//  ratio of the real frame rates. Timecode counts labels, and 23.976 counts the
//  same labels as 24 - the rescale is the 1000/1001 NTSC ratio applied to a
//  whole hour of timecode, which is 101 frames.
//

import XCTest
@testable import Projector

final class EmbeddedTimecodeResultTests: XCTestCase {

    // MARK: - Helper

    private func result(frames: Int, rate: Double, drop: Bool = false) -> EmbeddedTimecodeResult {
        EmbeddedTimecodeResult(
            timecodeFrames: frames,
            formattedTimecode: "",
            source: .quickTimeTrack,
            frameRate: rate,
            isDropFrame: drop
        )
    }

    // MARK: - NTSC pairs share a counting grid

    /// The reported case: 01:10:12:03 on a 23.976 reel, onto a 24 fps timeline.
    ///
    /// 101091 frames must stay 101091. Rescaling by 24/23.976 gives 101192,
    /// which reads as 01:10:16:08 - four seconds and five frames late, and
    /// wrong by the same amount from the reel's first frame to its last.
    func testNTSCTimecodeKeepsItsAddressOnTheIntegerGrid() {
        let detected = result(frames: 101091, rate: 24000.0 / 1001.0)
        XCTAssertEqual(detected.convertedFrames(to: 24.0), 101091)
    }

    /// And the reverse direction.
    func testIntegerTimecodeKeepsItsAddressOnTheNTSCGrid() {
        let detected = result(frames: 101091, rate: 24.0)
        XCTAssertEqual(detected.convertedFrames(to: 24000.0 / 1001.0), 101091)
    }

    /// Same rule one grid up: 29.97 and 30 both count thirty labels a second.
    func testThirtyAndTwentyNineNineSevenShareAGrid() {
        let detected = result(frames: 108000, rate: 30000.0 / 1001.0)
        XCTAssertEqual(detected.convertedFrames(to: 30.0), 108000)
        XCTAssertEqual(result(frames: 108000, rate: 30.0)
            .convertedFrames(to: 30000.0 / 1001.0), 108000)
    }

    /// 59.94 and 60 likewise.
    func testSixtyAndFiftyNineNineFourShareAGrid() {
        let detected = result(frames: 216000, rate: 60000.0 / 1001.0)
        XCTAssertEqual(detected.convertedFrames(to: 60.0), 216000)
    }

    // MARK: - A real change of grid still converts

    /// 24 to 25 is a different number of labels per second, so the count moves.
    func testDifferentGridsStillConvert() {
        // One hour: 86400 frames at 24, 90000 at 25.
        let detected = result(frames: 86400, rate: 24.0)
        XCTAssertEqual(detected.convertedFrames(to: 25.0), 90000)
    }

    /// And 30 to 24 scales down by the same rule.
    func testConversionDownAGrid() {
        let detected = result(frames: 108000, rate: 30.0)
        XCTAssertEqual(detected.convertedFrames(to: 24.0), 86400)
    }

    // MARK: - Identity and edges

    func testSameRateIsIdentity() {
        for rate in [23.976, 24.0, 25.0, 29.97, 30.0, 48.0, 50.0, 60.0] {
            XCTAssertEqual(
                result(frames: 12345, rate: rate).convertedFrames(to: rate),
                12345,
                "\(rate) should be identity"
            )
        }
    }

    func testZeroFramesStaysZero() {
        XCTAssertEqual(result(frames: 0, rate: 24000.0 / 1001.0).convertedFrames(to: 24.0), 0)
    }

    /// A nonsense rate must not divide by zero or silently zero the address.
    func testUnusableRateLeavesTheCountAlone() {
        XCTAssertEqual(result(frames: 101091, rate: 0).convertedFrames(to: 24.0), 101091)
        XCTAssertEqual(result(frames: 101091, rate: 24.0).convertedFrames(to: 0), 101091)
    }

    /// Drop frame changes how labels are *counted*, not how many per second, so
    /// it does not change the grid.
    func testDropFrameSharesTheGridOfItsRate() {
        let detected = result(frames: 108000, rate: 30000.0 / 1001.0, drop: true)
        XCTAssertEqual(detected.convertedFrames(to: 30.0), 108000)
    }
}
