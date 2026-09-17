import Foundation

/// Captures the node and envelope when the numeric editor opens. A delayed
/// submission must not overwrite an edit or undo that happened meanwhile.
struct AutomationLevelEdit {
    let pointId: UUID
    let original: VolumeAutomation

    func applying(gainDB: Float, to current: VolumeAutomation?) -> VolumeAutomation? {
        guard gainDB.isFinite, current == original,
              original.points.contains(where: { $0.id == pointId }) else { return nil }
        var updated = original
        updated.setGain(id: pointId, gainDB: gainDB)
        return updated == original ? nil : updated
    }
}

/// Lane-scoped, inverse-operation undo for volume-automation edits, with real
/// redo.
///
/// `MultiTrackTimelineView`'s snapshot-based `registerTimelineUndo` restores
/// a whole-timeline snapshot captured before an edit and does not re-register
/// itself while undoing, so undoing an automation edit through it would give
/// no redo. Automation edits are frequent - every node drag, every menu
/// command - so this instead registers the *inverse* of each edit, and rearms
/// the inverse of that inverse from inside the very closure that runs it,
/// which is the standard `NSUndoManager` trick for making undo and redo cycle
/// indefinitely between two states.
///
/// A free function type rather than a method on `MultiTrackTimelineView`
/// (which is a `View` struct) so plan §7's tests can drive it directly
/// against a real `UndoManager` and a real `TimelineManager`, without needing
/// a SwiftUI view instance.
@MainActor
enum AutomationUndo {
    /// Registers one undo step that restores `old` to `laneId`'s envelope,
    /// and rearms itself - with `old` and `new` swapped - from inside that
    /// restore, so ⌘Z and ⇧⌘Z keep cycling between the two values rather than
    /// undo working once and redo doing nothing.
    ///
    /// - Parameters:
    ///   - undoManager: The manager to register with. A no-op if `nil`.
    ///   - manager: The timeline manager the undo/redo step mutates.
    ///   - laneId: The lane whose envelope changed.
    ///   - old: The envelope to restore on undo (before the edit). `nil`
    ///     means the lane had no automation yet.
    ///   - new: The envelope to restore on redo (after the edit). `nil`
    ///     means the edit removed the lane's automation entirely.
    ///   - actionName: Shown in the Edit menu as "Undo <name>" / "Redo <name>".
    static func register(
        on undoManager: UndoManager?,
        manager: TimelineManager,
        laneId: UUID,
        from old: VolumeAutomation?,
        to new: VolumeAutomation?,
        actionName: String
    ) {
        guard let undoManager else { return }
        let documentSessionID = manager.documentSessionID
        undoManager.registerUndo(withTarget: manager) { target in
            guard target.documentSessionID == documentSessionID else { return }
            target.applyAutomation(old, laneId: laneId)
            register(on: undoManager, manager: target, laneId: laneId, from: new, to: old, actionName: actionName)
        }
        undoManager.setActionName(actionName)
    }

    /// Whether a captured "before" envelope no longer matches a lane's
    /// current envelope - meaning an undo, a redo, or some other change
    /// happened during an edit gesture (for example, a "Set Level…" popover
    /// left open across an unrelated undo). Callers use this to discard the
    /// edit rather than commit over whatever changed underneath it.
    ///
    /// - Parameters:
    ///   - current: The lane's envelope right now.
    ///   - captured: The envelope captured when the edit gesture began.
    static func isStale(current: VolumeAutomation?, captured: VolumeAutomation?) -> Bool {
        current != captured
    }
}
