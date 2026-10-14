//
//  PlacedWithoutTimecodeTests.swift
//  ProjectorTests
//
//  The warning for files placed where they were dropped, and the flag that
//  carries it in the project file.
//
//  The flag is new, so projects saved before it existed must still open, and
//  one that was set must survive a save.
//

import XCTest
@testable import Projector

final class PlacedWithoutTimecodeTests: XCTestCase {

    // MARK: - Report wording

    /// Nothing placed means no alert at all, not an empty one.
    func testNoFilesProducesNoMessage() {
        XCTAssertNil(PlacedWithoutTimecodeReport.message(for: []))
    }

    /// One file reads as a sentence about that file, with its timecode.
    func testSingleFileNamesItAndWhereItWent() throws {
        let message = try XCTUnwrap(PlacedWithoutTimecodeReport.message(for: [
            PlacedWithoutTimecodeFile(name: "Reel_2.mp4", timecode: "00:59:50:00")
        ]))

        XCTAssertTrue(message.contains("\"Reel_2.mp4\" carries no timecode"))
        XCTAssertTrue(message.contains("Projector had nothing to place it by"))
        XCTAssertTrue(message.contains("It was placed at 00:59:50:00"))
        XCTAssertFalse(message.contains("dropped"))
        XCTAssertTrue(message.contains("If it belongs somewhere else"))
        XCTAssertFalse(message.contains("•"))
    }

    /// Several files are one list, each with its own timecode, in drop order.
    func testSeveralFilesAreListedWithTheirTimecodes() throws {
        let message = try XCTUnwrap(PlacedWithoutTimecodeReport.message(for: [
            PlacedWithoutTimecodeFile(name: "Reel_1.mp4", timecode: "01:00:00:00"),
            PlacedWithoutTimecodeFile(name: "Reel_2.mp4", timecode: "01:10:00:00")
        ]))

        XCTAssertTrue(message.contains("These files carry no timecode"))
        XCTAssertTrue(message.contains("• Reel_1.mp4 - 01:00:00:00"))
        XCTAssertTrue(message.contains("• Reel_2.mp4 - 01:10:00:00"))
        XCTAssertLessThan(
            try XCTUnwrap(message.range(of: "Reel_1.mp4")).lowerBound,
            try XCTUnwrap(message.range(of: "Reel_2.mp4")).lowerBound
        )
    }

    /// Past the cap the rest are counted, so a large drop still fits on screen.
    func testListIsCappedAndTheRestCounted() throws {
        let cap = PlacedWithoutTimecodeReport.maxListedFiles
        let files = (1...(cap + 3)).map {
            PlacedWithoutTimecodeFile(name: "Sample \($0).wav", timecode: "01:00:00:00")
        }
        let message = try XCTUnwrap(PlacedWithoutTimecodeReport.message(for: files))

        XCTAssertTrue(message.contains("Sample \(cap).wav"))
        XCTAssertFalse(message.contains("Sample \(cap + 1).wav"))
        XCTAssertTrue(message.contains("…and 3 more"))
    }

    // MARK: - Which files are flagged

    private func embeddedTimecode() -> EmbeddedTimecodeResult {
        EmbeddedTimecodeResult(
            timecodeFrames: 86_400,
            formattedTimecode: "01:00:00:00",
            source: .quickTimeTrack,
            frameRate: 24,
            isDropFrame: false
        )
    }

    /// A file that says nothing about where it belongs is flagged.
    func testFileWithNoTimecodeIsFlagged() {
        XCTAssertTrue(PlacedWithoutTimecodeReport.shouldFlag(metadata: nil, filenameTimecode: nil))
    }

    /// Embedded timecode is enough to leave a file unflagged.
    func testEmbeddedTimecodeIsNotFlagged() {
        XCTAssertFalse(PlacedWithoutTimecodeReport.shouldFlag(metadata: embeddedTimecode(), filenameTimecode: nil))
    }

    /// So is a timecode parsed from the file name.
    func testFilenameTimecodeIsNotFlagged() {
        XCTAssertFalse(PlacedWithoutTimecodeReport.shouldFlag(metadata: nil, filenameTimecode: "01:00:00:00"))
    }

    /// Both together is still unflagged.
    func testBothSourcesAreNotFlagged() {
        XCTAssertFalse(PlacedWithoutTimecodeReport.shouldFlag(metadata: embeddedTimecode(), filenameTimecode: "01:00:00:00"))
    }

    // MARK: - Persistence

    private let sourceURL = URL(fileURLWithPath: "/tmp/Reel_2.mp4")

    /// A project saved before the flag existed opens with it off.
    func testVideoReelWithoutTheKeyDecodesAsFalse() throws {
        let reel = VideoReel(sourceURL: sourceURL, timelineStartFrame: 10, durationFrames: 100)
        let data = try JSONEncoder().encode(reel)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "placedWithoutTimecode")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        XCTAssertFalse(try JSONDecoder().decode(VideoReel.self, from: legacy).placedWithoutTimecode)
    }

    /// A set flag survives a save and reload.
    func testVideoReelFlagRoundTrips() throws {
        let reel = VideoReel(sourceURL: sourceURL, timelineStartFrame: 10, durationFrames: 100, placedWithoutTimecode: true)
        let decoded = try JSONDecoder().decode(VideoReel.self, from: JSONEncoder().encode(reel))

        XCTAssertTrue(decoded.placedWithoutTimecode)
    }

    /// A project saved before the flag existed opens with it off.
    func testAudioClipWithoutTheKeyDecodesAsFalse() throws {
        let clip = AudioClip(sourceURL: sourceURL, timelineStartFrame: 10, durationFrames: 100)
        let data = try JSONEncoder().encode(clip)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "placedWithoutTimecode")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        XCTAssertFalse(try JSONDecoder().decode(AudioClip.self, from: legacy).placedWithoutTimecode)
    }

    /// A set flag survives a save and reload.
    func testAudioClipFlagRoundTrips() throws {
        let clip = AudioClip(sourceURL: sourceURL, timelineStartFrame: 10, durationFrames: 100, placedWithoutTimecode: true)
        let decoded = try JSONDecoder().decode(AudioClip.self, from: JSONEncoder().encode(clip))

        XCTAssertTrue(decoded.placedWithoutTimecode)
    }
}
