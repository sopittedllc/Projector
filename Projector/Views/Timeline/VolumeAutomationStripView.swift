import SwiftUI

/// The collapsed row drawn directly beneath a standalone lane when its
/// ``VolumeAutomation`` sub-lane is not shown.
///
/// Every standalone lane gets one of these, regardless of whether it has an
/// envelope yet - it doubles as the lane's only way to add automation (there
/// is no header well and no context-menu item; the user decided against
/// both after using the step-2 prototype) and, once an envelope exists, as
/// the way to bring the hidden sub-lane back.
struct VolumeAutomationStripView: View {
    let lane: AudioLane

    /// Index into `timeline.audioLanes`, for the lane's accent colour.
    let laneIndex: Int

    /// Full row width, header column included - the same convention every
    /// other timeline row uses (`MultiTrackTimelineView.timelineContentWidth(for:)`).
    let totalContentWidth: CGFloat

    /// Called when the strip's control is pressed. The call site decides
    /// whether that means adding a new envelope or revealing an existing,
    /// hidden one.
    let onActivate: () -> Void

    @State private var isHovered = false

    /// "Add Automation" when the lane has no envelope yet, "Show Automation"
    /// once one exists but is hidden.
    private var title: String {
        lane.automation == nil ? "Add Automation" : "Show Automation"
    }

    /// Horizontal scroll offset the header column counter-shifts by, so the
    /// strip stays pinned to the viewport edge like every other row header.
    @Environment(\.timelineHeaderScrollOffset) private var headerScrollOffset

    var body: some View {
        HStack(spacing: 0) {
            header
                // Visual only, matching `AudioLaneView.laneHeader`: the row
                // still reserves the column.
                .offset(x: headerScrollOffset)
                .zIndex(1)
            Color.clear
        }
        .frame(width: totalContentWidth, height: TimelineLayout.automationStripHeight)
    }

    private var header: some View {
        HStack(spacing: 0) {
            // Same accent stripe as the lane header and the sub-lane header,
            // so the "+" sits on the lane name's leading edge rather than
            // three points to its left - and the strip reads as the lane's.
            Rectangle()
                .fill(LaneColor.color(forLaneIndex: laneIndex))
                .frame(width: TimelineLayout.laneAccentWidth)
            addButton
        }
        .frame(width: TimelineLayout.headerWidth, height: TimelineLayout.automationStripHeight)
        .background(TimelineHeaderColumnBackground())
    }

    private var addButton: some View {
        Button(action: onActivate) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "plus.circle")
                    .font(Typography.iconTiny)
                Text(title)
                    .font(Typography.captionSmall)
            }
            .foregroundColor(isHovered ? .primary : AppColors.textTertiary)
            .padding(.horizontal, Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: TimelineLayout.automationStripHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(title)
        .accessibilityLabel(title)
    }
}
