//
//  LinkedDragPreviewTests.swift
//  ProjectorTests
//
//  The one rule deciding which reels and clips follow a linked drag.
//

import XCTest
@testable import Projector

final class LinkedDragPreviewTests: XCTestCase {

    private let url = URL(fileURLWithPath: "/tmp/neutral_source.mov")

    private func reel(sourceStart: Int, at start: Int = 100) -> VideoReel {
        VideoReel(sourceURL: url, timelineStartFrame: start, durationFrames: 240, sourceStartFrame: sourceStart)
    }

    private func linkedClip(sourceStart: Int, at start: Int = 100) -> AudioClip {
        AudioClip(
            sourceURL: url,
            timelineStartFrame: start,
            durationFrames: 240,
            sourceStartFrame: sourceStart,
            sourceType: .videoTrack
        )
    }

    /// A reel trimmed in from its head still finds its audio; a hard-coded
    /// source start of zero used to miss it.
    func testReelPreviewMatchesLinkedClipWithNonZeroSourceStart() {
        let preview = LinkedDragPreview(reel: reel(sourceStart: 48), toFrame: 300)
        XCTAssertTrue(preview.matches(linkedClip(sourceStart: 48)))
        XCTAssertEqual(preview.deltaFrames, 200)
    }

    /// The clip-initiated preview finds the reel the same way.
    func testClipPreviewMatchesItsReel() {
        let preview = LinkedDragPreview(clip: linkedClip(sourceStart: 48), toFrame: 150)
        XCTAssertTrue(preview.matches(reel(sourceStart: 48)))
    }

    /// Anything that is not the same cut at the same place stays put.
    func testMismatchesDoNotFollow() {
        let preview = LinkedDragPreview(reel: reel(sourceStart: 0), toFrame: 300)
        XCTAssertFalse(preview.matches(linkedClip(sourceStart: 12)))
        XCTAssertFalse(preview.matches(linkedClip(sourceStart: 0, at: 500)))

        let plain = AudioClip(sourceURL: url, timelineStartFrame: 100, durationFrames: 240)
        XCTAssertFalse(preview.matches(plain))
    }
}
