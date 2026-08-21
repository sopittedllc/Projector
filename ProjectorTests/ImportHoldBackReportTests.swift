//
//  ImportHoldBackReportTests.swift
//  ProjectorTests
//
//  The report an import shows for files it held back.
//
//  A picture turnover routinely arrives with no timecode anywhere, so this
//  alert is what the user sees on a whole delivery rather than an odd file. It
//  has to stay readable at fifteen files and dismissable at fifty.
//

import XCTest
@testable import Projector

final class ImportHoldBackReportTests: XCTestCase {

    private func names(_ count: Int, _ reason: ImportHoldBackReason = .noTimecode) -> [HeldBackFile] {
        (1...count).map { HeldBackFile(name: "Sample reel \($0)_Dx_Fx.wav", reason: reason) }
    }

    /// Nothing held back means no alert at all, not an empty one.
    func testNoNamesProducesNoMessage() {
        XCTAssertNil(ImportHoldBackReport.message(for: []))
    }

    /// Every name is listed while the list is short enough to read.
    func testListsEveryNameUpToTheCap() {
        let all = names(ImportHoldBackReport.maxListedNames)
        guard let message = ImportHoldBackReport.message(for: all) else {
            return XCTFail("expected a message")
        }

        for file in all {
            XCTAssertTrue(message.contains("• \(file.name)"), "missing \(file.name)")
        }
        XCTAssertFalse(message.contains("more"))
    }

    /// Past the cap the rest are counted, so a fifty-file delivery still fits
    /// on screen and can be dismissed.
    func testLongListIsTruncatedAndCounted() {
        let all = names(ImportHoldBackReport.maxListedNames + 7)
        guard let message = ImportHoldBackReport.message(for: all) else {
            return XCTFail("expected a message")
        }

        let bullets = message.components(separatedBy: "\n").filter { $0.hasPrefix("• ") }
        XCTAssertEqual(bullets.count, ImportHoldBackReport.maxListedNames + 1)
        XCTAssertTrue(message.contains("…and 7 more"))
        XCTAssertTrue(message.contains(all[0].name))
        XCTAssertFalse(message.contains(all[all.count - 1].name))
    }

    /// One file reads as one file. The alert fires for a single held-back file
    /// in a batch that placed the rest, so the plural is not safe to assume.
    func testSingleFileReadsInTheSingular() {
        guard let message = ImportHoldBackReport.message(for: [HeldBackFile(name: "Sample reel 1_Mx.wav", reason: .noTimecode)]) else {
            return XCTFail("expected a message")
        }

        XCTAssertTrue(message.contains("This file carries no timecode"))
        XCTAssertTrue(message.contains("where it belongs"))
        XCTAssertTrue(message.contains("It was added to Media"))
    }

    /// Several files read as several.
    func testSeveralFilesReadInThePlural() {
        guard let message = ImportHoldBackReport.message(for: names(3)) else {
            return XCTFail("expected a message")
        }

        XCTAssertTrue(message.contains("These files carry no timecode"))
        XCTAssertTrue(message.contains("where they belong"))
        XCTAssertTrue(message.contains("They were added to Media"))
    }

    /// The title does not claim the whole import failed - files that carry
    /// timecode are still placed in the same drop.
    func testTitleDoesNotClaimNothingWasPlaced() {
        XCTAssertEqual(ImportHoldBackReport.title, "Not Placed")
    }

    /// A file held back for landing on an occupied lane reads differently from
    /// one held back for having no timecode - the delivery problems are not the
    /// same and the user has to be able to tell them apart.
    func testOccupiedLaneReadsAsItsOwnReason() {
        guard let message = ImportHoldBackReport.message(for: names(2, .timecodeAlreadyOccupied)) else {
            return XCTFail("expected a message")
        }

        XCTAssertTrue(message.contains("already occupies"))
        XCTAssertFalse(message.contains("no timecode"))
    }

    /// One drop can hold files back for both reasons. Each gets its own heading
    /// and its own list, rather than one undifferentiated pile.
    func testBothReasonsAreReportedSeparatelyInOneAlert() {
        let mixed = [
            HeldBackFile(name: "Sample reel 1_Dx_Fx.wav", reason: .noTimecode),
            HeldBackFile(name: "Sample reel 2_Mx.wav", reason: .timecodeAlreadyOccupied),
            HeldBackFile(name: "Sample reel 3_Mx.wav", reason: .noTimecode)
        ]

        guard let message = ImportHoldBackReport.message(for: mixed) else {
            return XCTFail("expected a message")
        }

        XCTAssertTrue(message.contains("no timecode"))
        XCTAssertTrue(message.contains("already occupies"))
        for file in mixed {
            XCTAssertTrue(message.contains("• \(file.name)"), "missing \(file.name)")
        }
        // Grouped, not interleaved: the two files sharing a reason sit together.
        let noTimecodeHeading = message.range(of: "no timecode")!
        let occupiedHeading = message.range(of: "already occupies")!
        let reel3 = message.range(of: "Sample reel 3_Mx.wav")!
        XCTAssertTrue(reel3.lowerBound > noTimecodeHeading.lowerBound)
        XCTAssertTrue(reel3.lowerBound < occupiedHeading.lowerBound)
    }

    /// The message says what to do next, not only what went wrong.
    func testMessageSaysWhereTheFilesWentAndWhatToDo() {
        guard let message = ImportHoldBackReport.message(for: names(2)) else {
            return XCTFail("expected a message")
        }

        XCTAssertTrue(message.contains("added to Media"))
        XCTAssertTrue(message.contains("Drag one onto a lane"))
    }
}
