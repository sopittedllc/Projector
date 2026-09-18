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
}
