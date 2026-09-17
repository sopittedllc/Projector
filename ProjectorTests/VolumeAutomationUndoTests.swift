//
//  VolumeAutomationUndoTests.swift
//  ProjectorTests
//
//  Tests for AutomationUndo - the lane-scoped inverse-operation undo/redo
//  used by the volume-automation editor (plan §5.5,
//  docs/plans/VOLUME-AUTOMATION-PLAN.md).
//

import XCTest
@testable import Projector
import SwiftTimecodeCore

@MainActor
final class VolumeAutomationUndoTests: XCTestCase {

    var manager: TimelineManager!
    var undoManager: UndoManager!
    var laneId: UUID!

    override func setUp() async throws {
        try await super.setUp()

        let startTC = Timecode(.components(h: 0, m: 0, s: 0, f: 0), at: .fps24, by: .clamping)
        let endTC = Timecode(.components(h: 0, m: 6, s: 56, f: 16), at: .fps24, by: .clamping) // 10000 frames at 24fps
        let config = TimelineConfig(startTimecode: startTC, endTimecode: endTC, frameRate: .fps24)
        manager = TimelineManager(timeline: Timeline(config: config, videoReels: [], audioLanes: []))
        undoManager = UndoManager()

        laneId = manager.addAudioLane(name: "Dialogue").id
    }

    override func tearDown() async throws {
        manager = nil
        undoManager = nil
        laneId = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private func currentAutomation() -> VolumeAutomation? {
        manager.timeline.audioLanes.first(where: { $0.id == laneId })?.automation
    }

    private func envelope(_ points: (frame: Int, dB: Float)...) -> VolumeAutomation {
        var automation = VolumeAutomation()
        for point in points {
            automation.insert(frame: point.frame, gainDB: point.dB)
        }
        return automation
    }

    /// Registers one automation edit exactly as `MultiTrackTimelineView`'s
    /// `commitAutomationEdit`/`removeAutomationEdit` do - the inverse
    /// registered immediately before the mutation - then applies `apply`
    /// and asserts the resulting state.
    ///
    /// `endUndoGrouping()` closes the undo group `registerUndo` opens
    /// implicitly: in a real app this closes on its own at the end of the
    /// current run-loop event, but a synchronous test never reaches one, and
    /// calling `undo()` with a group still open raises. `undo()`/`redo()`
    /// manage their own grouping internally for the recursive re-registration
    /// inside ``AutomationUndo/register(on:manager:laneId:from:to:actionName:)``,
    /// so this is only needed once, for the initial registration.
    private func performEdit(
        from old: VolumeAutomation?,
        to new: VolumeAutomation?,
        actionName: String,
        apply: () -> Void
    ) {
        AutomationUndo.register(on: undoManager, manager: manager, laneId: laneId, from: old, to: new, actionName: actionName)
        undoManager.endUndoGrouping()
        apply()
        XCTAssertEqual(currentAutomation(), new, "Applying the edit should reach the timeline")
    }

    /// Runs undo→redo→undo→redo from the state ``performEdit`` left behind -
    /// two full cycles, so a helper that only exercised one wouldn't hide a
    /// "redo works once, then the chain breaks" regression - asserting both
    /// the resulting envelope and the Edit-menu action name at each step.
    private func assertCycles(old: VolumeAutomation?, new: VolumeAutomation?, actionName: String) {
        for cycle in 1...2 {
            XCTAssertTrue(undoManager.canUndo, "Cycle \(cycle): expected an undo step to be available")
            XCTAssertEqual(undoManager.undoActionName, actionName, "Cycle \(cycle)")
            undoManager.undo()
            XCTAssertEqual(currentAutomation(), old, "Cycle \(cycle): undo should restore the prior envelope")

            XCTAssertTrue(undoManager.canRedo, "Cycle \(cycle): undo should have armed redo")
            XCTAssertEqual(undoManager.redoActionName, actionName, "Cycle \(cycle)")
            undoManager.redo()
            XCTAssertEqual(currentAutomation(), new, "Cycle \(cycle): redo should reapply the edit")
        }
    }

    // MARK: - Move / Add / Delete / Reset / Remove / Set Level

    func testMoveNodeUndoRedoCycles() {
        let old = envelope((frame: 100, dB: -6))
        let new = envelope((frame: 150, dB: -12))
        manager.setAutomation(old, laneId: laneId)

        performEdit(from: old, to: new, actionName: "Move Node") {
            manager.setAutomation(new, laneId: laneId)
        }
        assertCycles(old: old, new: new, actionName: "Move Node")
    }

    func testAddNodeUndoRedoCycles() {
        let old = VolumeAutomation()
        let new = envelope((frame: 100, dB: -6))

        performEdit(from: old, to: new, actionName: "Add Node") {
            manager.setAutomation(new, laneId: laneId)
        }
        assertCycles(old: old, new: new, actionName: "Add Node")
    }

    func testDeleteNodeUndoRedoCycles() {
        let old = envelope((frame: 100, dB: -6), (frame: 200, dB: 0))
        let new = envelope((frame: 200, dB: 0))
        manager.setAutomation(old, laneId: laneId)

        performEdit(from: old, to: new, actionName: "Delete Node") {
            manager.setAutomation(new, laneId: laneId)
        }
        assertCycles(old: old, new: new, actionName: "Delete Node")
    }

    func testResetAutomationUndoRedoCycles() {
        let old = envelope((frame: 100, dB: -6), (frame: 200, dB: -12))
        let new = VolumeAutomation()
        manager.setAutomation(old, laneId: laneId)

        performEdit(from: old, to: new, actionName: "Reset Automation") {
            manager.setAutomation(new, laneId: laneId)
        }
        assertCycles(old: old, new: new, actionName: "Reset Automation")
    }

    func testRemoveAutomationUndoRedoCycles() {
        let old = envelope((frame: 100, dB: -6))
        manager.setAutomation(old, laneId: laneId)

        performEdit(from: old, to: nil, actionName: "Remove Automation") {
            manager.removeAutomation(fromLane: laneId)
        }
        assertCycles(old: old, new: nil, actionName: "Remove Automation")
    }

    func testSetLevelUndoRedoCycles() {
        let old = envelope((frame: 100, dB: -6))
        manager.setAutomation(old, laneId: laneId)

        var new = old
        new.setGain(id: old.points[0].id, gainDB: -20)

        performEdit(from: old, to: new, actionName: "Set Level") {
            manager.setAutomation(new, laneId: laneId)
        }
        assertCycles(old: old, new: new, actionName: "Set Level")
    }

    // MARK: - Stale-edit guard

    func testAutomationUndoCannotChangeAReopenedProjectWithMatchingLaneIDs() {
        let old = envelope((0, -6))
        let new = envelope((0, -12))
        manager.setAutomation(new, laneId: laneId)
        undoManager.beginUndoGrouping()
        AutomationUndo.register(on: undoManager, manager: manager, laneId: laneId,
                                from: old, to: new, actionName: "Edit Automation")
        undoManager.endUndoGrouping()
        let session = manager.documentSessionID
        let sameContents = manager.timeline
        manager.replaceProjectTimeline(sameContents)
        XCTAssertNotEqual(manager.documentSessionID, session)
        undoManager.undo()
        XCTAssertEqual(currentAutomation(), new)
        XCTAssertFalse(undoManager.canRedo)
    }

    func testOrdinaryTimelineEditsKeepDocumentSession() {
        let session = manager.documentSessionID
        manager.setAutomation(envelope((0, -6)), laneId: laneId)
        XCTAssertEqual(manager.documentSessionID, session)
    }

    func testNumericEditRejectsInterveningChangesAndRemoval() {
        var original = VolumeAutomation()
        let point = original.insert(frame: 24, gainDB: -6)
        let edit = AutomationLevelEdit(pointId: point.id, original: original)
        var changed = original
        changed.setGain(id: point.id, gainDB: -12)
        XCTAssertNil(edit.applying(gainDB: -3, to: changed))
        changed.remove(id: point.id)
        XCTAssertNil(edit.applying(gainDB: -3, to: changed))
        XCTAssertNil(edit.applying(gainDB: -3, to: nil))
    }

    func testNumericEditChangesOnlyCapturedNodeAndRejectsNoOpsAndNonFiniteInput() throws {
        var original = VolumeAutomation()
        let point = original.insert(frame: 24, gainDB: -6)
        original.insert(frame: 48, gainDB: -12)
        let edit = AutomationLevelEdit(pointId: point.id, original: original)
        let updated = try XCTUnwrap(edit.applying(gainDB: -90, to: original))
        XCTAssertEqual(updated.points[0].gainDB, -60)
        XCTAssertEqual(updated.points[0].id, point.id)
        XCTAssertEqual(updated.points[0].frame, 24)
        XCTAssertEqual(updated.points[1], original.points[1])
        XCTAssertNil(edit.applying(gainDB: -6, to: original))
        XCTAssertNil(edit.applying(gainDB: .nan, to: original))
        XCTAssertNil(edit.applying(gainDB: .infinity, to: original))
    }

    func testIsStaleDetectsChangeSinceCapture() {
        let captured = envelope((frame: 100, dB: -6))
        XCTAssertFalse(AutomationUndo.isStale(current: captured, captured: captured), "Unchanged since capture is not stale")

        let changed = envelope((frame: 100, dB: -12))
        XCTAssertTrue(AutomationUndo.isStale(current: changed, captured: captured), "A different envelope since capture is stale")

        XCTAssertTrue(AutomationUndo.isStale(current: nil, captured: captured), "Automation removed since capture is stale")
        XCTAssertFalse(AutomationUndo.isStale(current: nil, captured: nil), "Both nil is unchanged, not stale")
    }
}
