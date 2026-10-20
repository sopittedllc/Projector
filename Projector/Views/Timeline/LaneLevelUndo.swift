import Foundation

/// Undo for the lane level control, with real redo.
///
/// One entry per drag, not per value the knob passes through: the view
/// applies the level live while dragging and registers a single step when the
/// drag ends. Like ``AutomationUndo``, the step registers its own inverse from
/// inside the closure that runs it, so undo and redo cycle between the two
/// values.
@MainActor
enum LaneLevelUndo {
    /// Action name shown in the Edit menu.
    static let actionName = "Change Lane Level"

    /// Registers one undo step that restores `old` to `laneId`'s level.
    ///
    /// - Parameters:
    ///   - undoManager: The manager to register with. A no-op if `nil`.
    ///   - manager: The timeline manager the undo/redo step mutates.
    ///   - laneId: The lane whose level changed.
    ///   - old: The linear level to restore on undo.
    ///   - new: The linear level to restore on redo.
    static func register(
        on undoManager: UndoManager?,
        manager: TimelineManager,
        laneId: UUID,
        from old: Float,
        to new: Float
    ) {
        guard let undoManager, old != new else { return }
        let documentSessionID = manager.documentSessionID
        undoManager.registerUndo(withTarget: manager) { target in
            guard target.documentSessionID == documentSessionID else { return }
            target.setLaneVolume(id: laneId, volume: old)
            register(on: undoManager, manager: target, laneId: laneId, from: new, to: old)
        }
        undoManager.setActionName(actionName)
    }
}
