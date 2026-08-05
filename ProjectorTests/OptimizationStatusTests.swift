//
//  OptimizationStatusTests.swift
//  ProjectorTests
//
//  What counts as media worth optimizing. The Optimize Media button is shown from
//  exactly this answer, so "nothing qualifies" has to be reachable.
//

import CoreGraphics
import XCTest
@testable import Projector

final class OptimizationStatusTests: XCTestCase {

    // MARK: - Helpers

    private func item(
        name: String = "clip",
        ext: String = "mov",
        type: MediaType = .video,
        width: CGFloat? = 1920,
        bitrate: Int? = nil,
        isOptimized: Bool = false
    ) -> MediaItem {
        var media = MediaItem(
            url: URL(fileURLWithPath: "/tmp/\(name).\(ext)"),
            type: type,
            duration: 60,
            videoSize: width.map { CGSize(width: $0, height: $0 * 9 / 16) },
            bitrate: bitrate
        )
        media.isOptimized = isOptimized
        return media
    }

    private func qualifies(_ media: MediaItem) -> Bool {
        if case .needsOptimization = OptimizationStatusHelper.status(for: media) { return true }
        return false
    }

    // MARK: - Nothing To Do

    /// The case the button's visibility hangs on: ordinary delivery-weight media that
    /// is already fine. Previously an unsaved project offered to optimize this anyway.
    func testModestFileNeedsNothing() {
        let modest = item(ext: "mp4", width: 1920, bitrate: 5_000_000)
        XCTAssertFalse(qualifies(modest))
    }

    func testAlreadyOptimizedFileNeedsNothing() {
        // Heavy enough to qualify on every other rule - the optimized flag wins.
        let done = item(width: 3840, bitrate: 100_000_000, isOptimized: true)
        XCTAssertFalse(qualifies(done))

        guard case .optimized = OptimizationStatusHelper.status(for: done) else {
            return XCTFail("Expected .optimized")
        }
    }

    func testAudioFileNeedsNothing() {
        let audio = item(ext: "wav", type: .audio, width: nil, bitrate: 2_300_000)
        XCTAssertFalse(qualifies(audio))
    }

    // MARK: - Thresholds

    func testResolutionThresholdIsExclusive() {
        // 1920 wide is the reference delivery size and must not be flagged; anything
        // wider is. An inclusive comparison here would mark every HD reel as needing
        // work, which is the whole population.
        XCTAssertFalse(qualifies(item(ext: "mp4", width: 1920, bitrate: 5_000_000)))
        XCTAssertTrue(qualifies(item(ext: "mp4", width: 1921, bitrate: 5_000_000)))
    }

    func testHighResolutionQualifies() {
        guard case .needsOptimization(let reason) =
                OptimizationStatusHelper.status(for: item(ext: "mp4", width: 3840, bitrate: 5_000_000)),
              case .highResolution(let width) = reason else {
            return XCTFail("Expected .highResolution")
        }
        XCTAssertEqual(width, 3840)
    }

    func testHighBitrateQualifies() {
        guard case .needsOptimization(let reason) =
                OptimizationStatusHelper.status(for: item(ext: "mp4", width: 1920, bitrate: 20_000_000)),
              case .highBitrate = reason else {
            return XCTFail("Expected .highBitrate")
        }
    }

    func testBitrateThresholdIsExclusive() {
        XCTAssertFalse(qualifies(item(ext: "mp4", width: 1920, bitrate: 10_000_000)))
        XCTAssertTrue(qualifies(item(ext: "mp4", width: 1920, bitrate: 10_000_001)))
    }

    // MARK: - Production Codecs

    func testHeavyQuickTimeIsFlaggedAsProductionCodec() {
        guard case .needsOptimization(let reason) =
                OptimizationStatusHelper.status(for: item(ext: "mov", width: 1920, bitrate: 100_000_000)),
              case .productionCodec = reason else {
            return XCTFail("Expected .productionCodec")
        }
    }

    func testLightQuickTimeIsNotAProductionCodecByExtensionAlone() {
        // A .mov is not heavy just for being a .mov - a 5 Mbps one is ordinary.
        XCTAssertFalse(qualifies(item(ext: "mov", width: 1920, bitrate: 5_000_000)))
    }

    // MARK: - Missing Metadata

    func testUnknownBitrateDoesNotQualifyOnItsOwn() {
        // Bitrate is estimated from file size and can be absent. Absent must not read
        // as "huge", or the button returns for files nothing is known about.
        XCTAssertFalse(qualifies(item(ext: "mp4", width: 1920, bitrate: nil)))
    }

    // MARK: - The Button's Rule

    func testALibraryOfLightMediaOffersNothing() {
        let library = [
            item(name: "a", ext: "mp4", width: 1920, bitrate: 5_000_000),
            item(name: "b", ext: "wav", type: .audio, width: nil, bitrate: 2_300_000),
            item(name: "c", ext: "mov", width: 1280, bitrate: 8_000_000)
        ]
        XCTAssertFalse(library.contains(where: qualifies))
    }

    func testOneHeavyFileIsEnoughToOffer() {
        let library = [
            item(name: "a", ext: "mp4", width: 1920, bitrate: 5_000_000),
            item(name: "b", ext: "mov", width: 3840, bitrate: 200_000_000)
        ]
        XCTAssertTrue(library.contains(where: qualifies))
    }

    func testAnEmptyLibraryOffersNothing() {
        XCTAssertFalse([MediaItem]().contains(where: qualifies))
    }
}
