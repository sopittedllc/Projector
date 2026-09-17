import AppKit
import SwiftUI

/// A lane's volume-automation sub-lane: a short row drawn directly beneath
/// its ``AudioLaneView``, showing and editing that lane's
/// ``VolumeAutomation`` envelope.
///
/// Owns the "preview while dragging" state itself (plan §5.4's apply-on-
/// release rule): while a node is being dragged, this view draws the
/// in-progress envelope without telling anything else about it, and only
/// calls ``onCommit`` once the mouse is released.
struct VolumeAutomationLaneView: View {
    let lane: AudioLane
    let laneIndex: Int
    let pixelsPerFrame: CGFloat
    let durationFrames: Int

    /// Full row width, header column included - the same convention every
    /// other timeline row uses (`MultiTrackTimelineView.timelineContentWidth(for:)`).
    let totalContentWidth: CGFloat

    /// Current playhead frame, for the header's live dB readout and the
    /// envelope's "add node at playhead" accessibility action.
    let playheadFrame: Int

    /// Renders an absolute frame as a timecode string - threaded down to the
    /// envelope for its accessibility labels, and used directly by the "Set
    /// Level…" popover's read-only timecode.
    let formatTimecode: (Int) -> String

    /// Called once, before any mutation, when an edit gesture begins - the
    /// call site uses this to capture undo state.
    let onBeginEdit: () -> Void

    /// Called when that gesture is over - see `VolumeAutomationEnvelopeView.onEndEdit`.
    let onEndEdit: () -> Void

    /// Called once an edit is finished and should take effect, with a name
    /// for the Edit menu - see `VolumeAutomationEnvelopeView.onCommit`.
    let onCommit: (VolumeAutomation, String) -> Void

    /// Called when "Remove Automation" is chosen from the envelope's
    /// empty-space context menu - see `VolumeAutomationEnvelopeView.onRemove`.
    let onRemove: () -> Void

    /// Called when the collapse control at the top of this row is pressed,
    /// so the caller can hide the sub-lane again. The envelope itself is
    /// untouched - hiding is view state, not bypass (`AudioLane.isAutomationShown`).
    let onHide: () -> Void

    /// Horizontal scroll offset the header column counter-shifts by, so it
    /// stays pinned to the viewport edge exactly as ``AudioLaneView``'s own
    /// header does.
    @Environment(\.timelineHeaderScrollOffset) private var headerScrollOffset

    /// The envelope being drawn while a drag is in progress. `nil` outside a
    /// drag, in which case ``lane``'s stored envelope is authoritative.
    @State private var previewAutomation: VolumeAutomation?

    /// The node the "Set Level…" popover is open for, if any.
    @State private var levelEditor: LevelEditorTarget?

    /// The popover's text field contents, seeded from the node's current
    /// gain when the popover opens and parsed on Return.
    @State private var levelEditorText: String = ""

    private var displayedAutomation: VolumeAutomation {
        previewAutomation ?? lane.automation ?? VolumeAutomation()
    }

    private var laneColor: Color {
        LaneColor.color(forLaneIndex: laneIndex)
    }

    var body: some View {
        HStack(spacing: 0) {
            header
                // Visual only, matching `AudioLaneView.laneHeader`: the row
                // still reserves the column so the envelope beside it keeps
                // its position.
                .offset(x: headerScrollOffset)
                .zIndex(1)

            envelope
        }
        .frame(width: totalContentWidth, height: TimelineLayout.automationLaneHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Volume automation for \(lane.name)")
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 0) {
            // Same accent stripe and width as `AudioLaneView.laneHeader`, so
            // the text after it lines up with the lane name above.
            Rectangle()
                .fill(laneColor)
                .frame(width: TimelineLayout.laneAccentWidth)

            // "Volume" over the live readout, stacked the way the lane
            // header above stacks its name over the M/S row at the same
            // leading edge - a trailing readout would introduce a second,
            // unrelated horizontal rhythm this header doesn't otherwise have.
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.xs) {
                    Text("Volume")
                        .font(Typography.monoTiny)
                        .foregroundColor(AppColors.textTertiary)
                    Spacer(minLength: 0)
                    Button(action: onHide) {
                        Image(systemName: "chevron.up")
                            .font(Typography.iconTiny)
                            .foregroundColor(AppColors.textTertiary)
                            // The glyph is 8pt; the click target is the same
                            // well size as M/S so it can actually be hit.
                            .frame(width: TimelineLayout.laneControlHeight, height: TimelineLayout.laneControlHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Hide Automation")
                    .accessibilityLabel("Hide Automation")
                }
                Text(String(format: "%+.1f dB", displayedAutomation.gainDB(at: playheadFrame)))
                    .font(Typography.monoTiny)
                    .foregroundColor(AppColors.textSecondary)
            }
            .padding(.horizontal, Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: TimelineLayout.headerWidth, height: TimelineLayout.automationLaneHeight)
        .background(TimelineHeaderColumnBackground())
    }

    // MARK: - Envelope

    private var envelope: some View {
        VolumeAutomationEnvelopeView(
            automation: displayedAutomation,
            pixelsPerFrame: pixelsPerFrame,
            durationFrames: durationFrames,
            laneColor: NSColor(laneColor),
            playheadFrame: playheadFrame,
            formatTimecode: formatTimecode,
            onBeginEdit: onBeginEdit,
            // The preview is view state and is cleared on *every* end - a
            // no-op drag never commits, and a preview that outlived its
            // gesture would keep drawing over whatever the lane holds next.
            onEndEdit: {
                previewAutomation = nil
                onEndEdit()
            },
            onPreview: { previewAutomation = $0 },
            onCommit: { automation, actionName in
                previewAutomation = nil
                onCommit(automation, actionName)
            },
            onRemove: onRemove,
            onSetLevel: { pointId, currentDB, frame, rect in
                guard let original = lane.automation else { return }
                levelEditorText = String(format: "%.1f", currentDB)
                levelEditor = LevelEditorTarget(
                    id: pointId, frame: frame, rect: rect,
                    edit: AutomationLevelEdit(pointId: pointId, original: original)
                )
            }
        )
        .frame(width: totalContentWidth - TimelineLayout.headerWidth, height: TimelineLayout.automationLaneHeight)
        .background(envelopeBackground)
        .popover(
            item: $levelEditor,
            attachmentAnchor: .rect(.rect(levelEditor?.rect ?? .zero)),
            arrowEdge: .top
        ) { target in
            levelEditorPopover(for: target)
        }
    }

    /// "Set Level…"'s content: the node's timecode (read-only) above a dB
    /// field. Return commits, clamped to ``VolumeAutomation/gainRange``;
    /// non-numeric text is left in place rather than committed or dismissed,
    /// so a bad edit can be corrected without reopening the popover. Escape
    /// (or any other dismissal) clears ``levelEditor`` without committing -
    /// standard `.popover(item:)` behaviour, not code this view has to write.
    private func levelEditorPopover(for target: LevelEditorTarget) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(formatTimecode(target.frame))
                .font(Typography.mono)
                .foregroundColor(AppColors.textSecondary)
            HStack(spacing: Spacing.xs) {
                TextField("Level", text: $levelEditorText)
                    .font(Typography.mono)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
                    .onSubmit { commitLevelEditor(for: target) }
                Text("dB")
                    .font(Typography.mono)
                    .foregroundColor(AppColors.textSecondary)
            }
        }
        .padding(Spacing.md)
    }

    private func commitLevelEditor(for target: LevelEditorTarget) {
        guard let value = Float(levelEditorText), value.isFinite else { return }
        guard let working = target.edit.applying(gainDB: value, to: lane.automation) else {
            levelEditor = nil
            return
        }

        onBeginEdit()
        onCommit(working, "Set Level")
        onEndEdit()
        levelEditor = nil
    }

    /// The same alternating tint `AudioLaneView.laneBackground` uses, a step
    /// darker so the sub-lane reads as recessed beneath the lane it belongs
    /// to rather than a peer row. Built entirely from existing `AppColors`
    /// tokens rather than new opacity literals.
    private var envelopeBackground: some View {
        ZStack {
            laneIndex.isMultiple(of: 2) ? AppColors.surfaceSubtle : AppColors.surfaceLight
            AppColors.overlayDark
        }
    }
}

/// The node a "Set Level…" popover is editing: its id (to commit the right
/// point), its frame (for the popover's read-only timecode) and its rect in
/// the envelope's own coordinate space (to anchor the popover there).
private struct LevelEditorTarget: Identifiable {
    let id: UUID
    let frame: Int
    let rect: CGRect
    let edit: AutomationLevelEdit
}
