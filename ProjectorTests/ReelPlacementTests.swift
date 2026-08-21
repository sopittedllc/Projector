//
//  ReelPlacementTests.swift
//  ProjectorTests
//
//  Where a reel lands when its timecode is already taken.
//
//  The case that prompted these: a five-reel delivery whose pictures were all
//  stamped 01:00:00:00. Every reel asked for the same frame, and the old rule
//  measured the second and later neighbours against a reel that had already been
//  moved - so reel 4 was slid onto exactly the same frames as reel 2 and
//  disappeared underneath it. Nothing on the video track showed it; the only
//  sign was a duplicate audio lane holding its embedded audio.
//

import XCTest
@testable import Projector

final class ReelPlacementTests: XCTestCase {

    private func start(_ preferred: Int, _ duration: Int, _ occupied: [Range<Int>]) -> Int {
        ReelPlacement.firstFreeStart(
            preferredStart: preferred,
            durationFrames: duration,
            occupied: occupied
        )
    }

    /// An empty track honours the timecode exactly.
    func testFirstReelKeepsItsTimecode() {
        XCTAssertEqual(start(240, 26543, []), 240)
    }

    /// A free gap is not disturbed, even with reels either side of it.
    func testAFreeStartIsLeftAlone() {
        XCTAssertEqual(start(50_000, 1_000, [0..<10_000, 100_000..<110_000]), 50_000)
    }

    /// Touching is not overlapping: a reel may start exactly where another ends.
    func testAReelMayBeginWhereAnotherEnds() {
        XCTAssertEqual(start(10_000, 5_000, [0..<10_000]), 10_000)
    }

    /// The reported case. Four reels all stamped the same frame must come out on
    /// four different frames, laid in the order they were imported.
    ///
    /// The old rule returned 26783 for the fourth reel - the same frame as the
    /// second - because it tested every neighbour against the reel's *original*
    /// position instead of its current one.
    func testReelsSharingOneTimecodeDoNotLandOnTopOfEachOther() {
        let durations = [26_543, 24_924, 33_204, 20_109]
        var occupied: [Range<Int>] = []
        var starts: [Int] = []

        for duration in durations {
            let s = start(240, duration, occupied)
            starts.append(s)
            occupied.append(s ..< (s + duration))
        }

        XCTAssertEqual(starts, [240, 26_783, 51_707, 84_911])

        // Stated separately from the numbers above, because the numbers are only
        // right if this holds: no two reels share a frame.
        for (i, a) in occupied.enumerated() {
            for b in occupied[(i + 1)...] {
                XCTAssertFalse(a.overlaps(b), "\(a) overlaps \(b)")
            }
        }
    }

    /// A short reel slid past one neighbour must still clear the next, which is
    /// the specific failure the stale end produced.
    func testAShortReelSlidPastOneNeighbourStillClearsTheNext() {
        // Blocked by 0..<100, then would sit inside 100..<200 if the end were
        // still measured from frame 0.
        XCTAssertEqual(start(0, 50, [0..<100, 100..<200]), 200)
    }

    /// Ranges arrive in whatever order the track holds them; the answer must not
    /// depend on that.
    func testOrderOfExistingReelsDoesNotMatter() {
        let ranges: [Range<Int>] = [100..<200, 0..<100, 200..<300]
        XCTAssertEqual(start(0, 50, ranges), 300)
        XCTAssertEqual(start(0, 50, ranges.reversed()), 300)
    }

    /// A reel is never moved earlier than its timecode asked for. Answering
    /// early would be a worse lie than answering late.
    func testAReelIsNeverMovedEarlier() {
        XCTAssertGreaterThanOrEqual(start(500, 100, [0..<10_000]), 500)
    }
}
