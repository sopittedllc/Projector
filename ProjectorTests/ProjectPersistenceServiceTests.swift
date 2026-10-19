import AppKit
import XCTest
@testable import Projector

@MainActor
final class ProjectPersistenceServiceTests: XCTestCase {
    private func withProject(_ body: (ProjectDocument, ProjectPersistenceService, URL, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.projector")
        try ProjectDocument().save(to: target)
        let document = ProjectDocument()
        let service = ProjectPersistenceService(projectDocument: document, mediaLibrary: ProjectMediaLibrary(),
                                                timelineManager: TimelineManager(), playbackEngine: PlaybackEngine())
        document.markDirty()
        try body(document, service, target, directory)
    }

    func testCancelKeepsUnsavedProject() throws {
        try withProject { document, service, target, _ in
            service.confirmProjectReplacement = { .alertThirdButtonReturn }
            service.openProject(from: target)
            XCTAssertNil(document.fileURL)
            XCTAssertTrue(document.hasUnsavedChanges)
        }
    }

    func testDiscardOpensSelectedProject() throws {
        try withProject { document, service, target, _ in
            service.confirmProjectReplacement = { .alertSecondButtonReturn }
            service.openProject(from: target)
            XCTAssertEqual(document.fileURL, target)
            XCTAssertFalse(document.hasUnsavedChanges)
        }
    }

    func testSaveAsWaitsForSuccessfulSaveBeforeOpening() throws {
        try withProject { document, service, target, directory in
            service.confirmProjectReplacement = { .alertFirstButtonReturn }
            var completeSave: ((URL) -> Void)?
            service.onSaveAsRequested = { completeSave = $0 }
            service.openProject(from: target)
            XCTAssertNil(document.fileURL)
            XCTAssertTrue(document.hasUnsavedChanges)
            let saved = directory.appendingPathComponent("saved.projector")
            try XCTUnwrap(completeSave)(saved)
            XCTAssertTrue(FileManager.default.fileExists(atPath: saved.appendingPathComponent("project.json").path))
            XCTAssertEqual(document.fileURL, target)
        }
    }

    func testSaveAsFailureKeepsUnsavedProject() throws {
        try withProject { document, service, target, directory in
            let invalid = directory.appendingPathComponent("file")
            try Data().write(to: invalid)
            service.confirmProjectReplacement = { .alertFirstButtonReturn }
            service.onSaveAsRequested = { $0(invalid) }
            var reportedError = false
            service.onError = { _ in reportedError = true }
            service.openProject(from: target)
            XCTAssertTrue(reportedError)
            XCTAssertNil(document.fileURL)
            XCTAssertTrue(document.hasUnsavedChanges)
        }
    }

    func testExistingProjectSaveFailureDoesNotOpenOrRequestSaveAs() throws {
        try withProject { document, service, target, directory in
            let saved = directory.appendingPathComponent("saved.projector")
            try document.save(to: saved)
            try FileManager.default.removeItem(at: saved)
            try Data().write(to: saved)
            document.markDirty()
            service.confirmProjectReplacement = { .alertFirstButtonReturn }
            service.onSaveAsRequested = { _ in XCTFail("Failed saves must stop opening") }
            service.openProject(from: target)
            XCTAssertEqual(document.fileURL, saved)
            XCTAssertTrue(document.hasUnsavedChanges)
        }
    }

    func testExistingProjectSavesBeforeOpening() throws {
        try withProject { document, service, target, directory in
            let saved = directory.appendingPathComponent("saved.projector")
            try document.save(to: saved)
            document.uiState.playerWindowVisible = true
            document.markDirty()
            service.confirmProjectReplacement = { .alertFirstButtonReturn }
            service.openProject(from: target)
            let reopened = ProjectDocument()
            try reopened.load(from: saved)
            XCTAssertTrue(reopened.uiState.playerWindowVisible)
            XCTAssertEqual(document.fileURL, target)
        }
    }
    /// Reopening a project keeps every media item's recorded state.
    ///
    /// Loading rebuilt each item field by field to swap in the resolved bookmark
    /// URL and left `isOptimized` out, so optimized media came back unoptimized and
    /// the next import offered all of it for optimizing again.
    func testReopeningKeepsOptimizedMediaOptimized() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaURL = directory.appendingPathComponent("reel 1 optimized.mov")
        try Data().write(to: mediaURL)
        let bookmark = try mediaURL.bookmarkData(options: .withSecurityScope)
        let knownBitrate = 1_200_000
        let document = ProjectDocument()
        document.mediaLibrary = [MediaItem(url: mediaURL, bookmark: bookmark, type: .video, duration: 1, bitrate: knownBitrate, isOptimized: true)]

        let reopened = ProjectDocument()
        try reopened.decode(from: try document.encode())

        let item = try XCTUnwrap(reopened.mediaLibrary.first)
        XCTAssertTrue(item.isOptimized)
        XCTAssertEqual(item.bitrate, knownBitrate)
        XCTAssertEqual(item.url.standardizedFileURL.resolvingSymlinksInPath(), mediaURL.standardizedFileURL.resolvingSymlinksInPath())
    }
    /// A project saved after the flag was lost recovers it from where the file lives.
    func testOpeningRecoversFlagForFilesInOptimizedMediaFolder() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectURL = directory.appendingPathComponent("Show.projector")
        let optimizedFolder = try XCTUnwrap(ProjectFolders.optimizedMediaFolder(forProjectAt: projectURL))
        try FileManager.default.createDirectory(at: optimizedFolder, withIntermediateDirectories: true)
        let optimizedURL = optimizedFolder.appendingPathComponent("reel 1.mov")
        let incomingURL = directory.appendingPathComponent("reel 2.mov")
        let document = ProjectDocument()
        document.mediaLibrary = [
            MediaItem(url: optimizedURL, type: .video, duration: 1),
            MediaItem(url: incomingURL, type: .video, duration: 1)
        ]
        try document.save(to: projectURL)

        let reopened = ProjectDocument()
        try reopened.load(from: projectURL)

        XCTAssertEqual(reopened.mediaLibrary.map(\.isOptimized), [true, false])
    }

    /// A saved project remembers its folder, and carries it through a reopen and resave.
    ///
    /// Optimized Media is written beside the package, which an open does not grant;
    /// without this bookmark a reopened project could not optimize.
    func testProjectRemembersItsFolderAcrossReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectURL = directory.appendingPathComponent("Show.projector")
        try ProjectDocument().save(to: projectURL)

        let reopened = ProjectDocument()
        try reopened.load(from: projectURL)
        XCTAssertTrue(reopened.canWriteProjectFolder)

        let json = try JSONSerialization.jsonObject(with: try reopened.encode()) as? [String: Any]
        XCTAssertNotNil(json?["projectFolderBookmark"])
    }

    /// The codec read at import survives a save and reopen.
    func testCodecNameSurvivesReopen() throws {
        var item = MediaItem(url: URL(fileURLWithPath: "/tmp/reel 1.mov"), type: .video, duration: 1)
        item.codecName = "Avid DNxHR"
        let document = ProjectDocument()
        document.mediaLibrary = [item]

        let reopened = ProjectDocument()
        try reopened.decode(from: try document.encode())

        XCTAssertEqual(reopened.mediaLibrary.first?.codecName, "Avid DNxHR")
    }
}
