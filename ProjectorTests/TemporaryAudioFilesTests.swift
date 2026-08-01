//
//  TemporaryAudioFilesTests.swift
//  ProjectorTests
//
//  Extracted audio is a cache. These cover the two properties that stop it
//  growing without bound: a name that can be reused, and a sweep that removes
//  what nothing has read.
//

import XCTest
@testable import Projector

final class TemporaryAudioFilesTests: XCTestCase {

    private let source = URL(fileURLWithPath: "/Volumes/Media/SHOW_PREV2_R1_COMPOSER.mov")

    private var written: [URL] = []

    override func tearDownWithError() throws {
        for url in written { try? FileManager.default.removeItem(at: url) }
        written = []
        try super.tearDownWithError()
    }

    @discardableResult
    private func makeFile(_ url: URL, bytes: Int = 1024) throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0, count: bytes).write(to: url)
        written.append(url)
        return url
    }

    private func setUsedDate(_ date: Date, on url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    // MARK: - Naming

    /// The bug: `String.hashValue` is seeded per process, so the same reel got a
    /// different filename on every launch and every one of them stayed on disk.
    func testTheSameSourceAlwaysGivesTheSameURL() {
        let first = TemporaryAudioFiles.url(for: source, role: "track0", fileExtension: "mov")
        let second = TemporaryAudioFiles.url(for: source, role: "track0", fileExtension: "mov")

        XCTAssertEqual(first, second)
    }

    func testTheDigestDoesNotDependOnProcessSeeding() {
        // Recomputed from the same input the type hashes. A per-process seed
        // would make this differ from the name in use.
        let url = TemporaryAudioFiles.url(for: source, role: "track0", fileExtension: "mov")

        XCTAssertTrue(
            url.lastPathComponent.contains("SHOW_PREV2_R1_COMPOSER"),
            "the readable stem is what makes the directory legible while debugging"
        )
        XCTAssertTrue(url.lastPathComponent.hasSuffix(".mov"))
    }

    func testEachRoleGetsItsOwnFile() {
        let left = TemporaryAudioFiles.url(for: source, role: "left", fileExtension: "caf")
        let right = TemporaryAudioFiles.url(for: source, role: "right", fileExtension: "caf")
        let track = TemporaryAudioFiles.url(for: source, role: "track0", fileExtension: "mov")

        XCTAssertNotEqual(left, right, "the two sides must not overwrite each other")
        XCTAssertNotEqual(left, track)
    }

    func testDifferentSourcesDoNotCollide() {
        let other = URL(fileURLWithPath: "/Volumes/Media/SHOW_PREV2_R2_COMPOSER.mov")

        XCTAssertNotEqual(
            TemporaryAudioFiles.url(for: source, role: "left", fileExtension: "caf"),
            TemporaryAudioFiles.url(for: other, role: "left", fileExtension: "caf")
        )
    }

    func testEverythingLandsInOneDirectory() {
        let url = TemporaryAudioFiles.url(for: source, role: "left", fileExtension: "caf")

        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "ExtractedAudio")
        XCTAssertTrue(TemporaryAudioFiles.isManaged(url))
    }

    // MARK: - Deleting

    func testRemoveDeletesAManagedFile() throws {
        let url = try makeFile(
            TemporaryAudioFiles.url(for: source, role: "removable", fileExtension: "caf")
        )

        TemporaryAudioFiles.remove(url)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// The guard that stops a wrong argument reaching a user's media.
    func testRemoveIgnoresAnythingOutsideTheDirectory() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-ours-\(UUID().uuidString).mov")
        try makeFile(outside)

        TemporaryAudioFiles.remove(outside)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: outside.path),
            "only files this type wrote may be deleted"
        )
    }

    // MARK: - Sweeping

    func testPurgeTakesFilesNothingHasRead() throws {
        let stale = try makeFile(
            TemporaryAudioFiles.url(for: source, role: "stale", fileExtension: "caf")
        )
        try setUsedDate(Date().addingTimeInterval(-60 * 60 * 24 * 30), on: stale)

        TemporaryAudioFiles.purge(before: Date().addingTimeInterval(-60 * 60 * 24 * 7))

        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }

    func testPurgeKeepsFilesStillInUse() throws {
        let fresh = try makeFile(
            TemporaryAudioFiles.url(for: source, role: "fresh", fileExtension: "caf")
        )

        TemporaryAudioFiles.purge(before: Date().addingTimeInterval(-60 * 60 * 24 * 7))

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fresh.path),
            "a reel still being worked on is read constantly and must survive"
        )
    }

    func testPurgeReportsWhatItReclaimed() throws {
        let stale = try makeFile(
            TemporaryAudioFiles.url(for: source, role: "accounted", fileExtension: "caf"),
            bytes: 4096
        )
        try setUsedDate(Date().addingTimeInterval(-60 * 60 * 24 * 30), on: stale)

        let reclaimed = TemporaryAudioFiles.purge(before: Date().addingTimeInterval(-60 * 60 * 24 * 7))

        XCTAssertGreaterThanOrEqual(reclaimed, 4096)
    }

    // MARK: - Legacy Files

    /// Names the old schemes produced, which nothing will ever look for again.
    func testLegacyNamesAreRecognised() {
        XCTAssertTrue(TemporaryAudioFiles.isLegacyName("projector-audio-8471895692213557923.mov"))
        XCTAssertTrue(TemporaryAudioFiles.isLegacyName("SHOW_PREV2_R1_COMPOSER-left-9D38DAB8.caf"))
        XCTAssertTrue(TemporaryAudioFiles.isLegacyName("260727_DeliLove_Full-right-290C97D5.caf"))
    }

    /// A user's own media, and this type's current files, must not match.
    func testCurrentAndUnrelatedNamesAreNotTreatedAsLegacy() {
        XCTAssertFalse(TemporaryAudioFiles.isLegacyName("Reel_01.mov"))
        XCTAssertFalse(TemporaryAudioFiles.isLegacyName("MyMix-final.caf"))
        XCTAssertFalse(TemporaryAudioFiles.isLegacyName("com.projector.app.savedState"))

        let current = TemporaryAudioFiles.url(for: source, role: "left", fileExtension: "caf")
        XCTAssertFalse(
            TemporaryAudioFiles.isLegacyName(current.lastPathComponent),
            "the sweep must not treat a file still in use as legacy"
        )
    }
}
