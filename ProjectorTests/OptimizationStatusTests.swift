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

    // MARK: - Nothing Left To Flag

    /// Optimized media carries no badge and raises no banner. Both are shown from
    /// `.needsOptimization`, so `.optimized` answering anything else is what makes
    /// the flag disappear when the work is done.
    func testOptimizingSilencesEveryOffer() {
        var library = [
            item(name: "a", ext: "mov", width: 3840, bitrate: 200_000_000),
            item(name: "b", ext: "mp4", width: 1920, bitrate: 40_000_000)
        ]
        XCTAssertTrue(library.contains(where: qualifies), "Precondition: work to offer")

        for index in library.indices {
            library[index].isOptimized = true
        }
        XCTAssertFalse(library.contains(where: qualifies))
    }

    /// The banner splits what qualifies into "ProRes" and everything else, so the
    /// production-codec test has to stand on its own outside `status(for:)`.
    func testProductionCodecTestIsIndependentOfStatus() {
        XCTAssertTrue(OptimizationStatusHelper.isProductionCodec(item(ext: "mov", bitrate: 100_000_000)))
        XCTAssertTrue(OptimizationStatusHelper.isProductionCodec(item(ext: "mxf", bitrate: 100_000_000)))
        XCTAssertFalse(OptimizationStatusHelper.isProductionCodec(item(ext: "mov", bitrate: 5_000_000)))
        XCTAssertFalse(OptimizationStatusHelper.isProductionCodec(item(ext: "mp4", bitrate: 100_000_000)))
        // Absent bitrate must not read as heavy, same as everywhere else.
        XCTAssertFalse(OptimizationStatusHelper.isProductionCodec(item(ext: "mov", bitrate: nil)))
    }
}

// MARK: - ProjectFolders

/// What counts as already being in the project. The Consolidate Media button is
/// shown from exactly this answer.
final class ProjectFoldersTests: XCTestCase {

    private let projectURL = URL(fileURLWithPath: "/Users/editor/Show/Cut.projector")

    private func contains(_ path: String) -> Bool {
        ProjectFolders.contains(URL(fileURLWithPath: path), projectURL: projectURL)
    }

    func testMediaInsideThePackageIsOurs() {
        XCTAssertTrue(contains("/Users/editor/Show/Cut.projector/Media/reel.mov"))
    }

    /// The case that made the button reappear after every optimize pass: optimized
    /// output is written *beside* the package, not inside it, so a package-only test
    /// read the app's own output as external media and offered to copy it back in.
    func testOptimizedOutputIsOurs() {
        XCTAssertTrue(contains("/Users/editor/Show/Optimized Media/reel.mov"))
    }

    func testMovedOriginalsAreOurs() {
        XCTAssertTrue(contains("/Users/editor/Show/Raw Files/reel.mov"))
    }

    func testMediaElsewhereIsExternal() {
        XCTAssertFalse(contains("/Volumes/Transfer/reel.mov"))
    }

    /// A neighbouring folder in the same directory is not the project's.
    /// Claiming the whole enclosing directory would consider a project saved to
    /// the Desktop to have consolidated the entire Desktop.
    func testSiblingFoldersWeDoNotOwnAreExternal() {
        XCTAssertFalse(contains("/Users/editor/Show/Dailies/reel.mov"))
    }

    /// String prefixes match names that merely start the same. `Cut.projector`
    /// is a textual prefix of `Cut.projector.backup`, a different directory.
    func testNeighbourWithASharedNamePrefixIsExternal() {
        XCTAssertFalse(contains("/Users/editor/Show/Cut.projector.backup/Media/reel.mov"))
        XCTAssertFalse(contains("/Users/editor/Show/Optimized Media Archive/reel.mov"))
    }

    /// The folder itself is not a file inside it.
    func testTheFolderIsNotItsOwnContents() {
        XCTAssertFalse(contains("/Users/editor/Show/Cut.projector"))
    }
}
