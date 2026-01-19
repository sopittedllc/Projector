import SwiftUI
import SwiftTimecodeCore

/// Visual cue lane displayed inside the timeline ScrollView.
///
/// Shows cue markers as colored rectangles positioned by their frame times.
/// Supports click to select and double-click to seek to cue start.
///
/// ## Positioning
///
/// This view is placed inside the timeline ScrollView, so it scrolls naturally
/// with the other timeline content. Markers are positioned at:
/// `headerWidth + (frame × pixelsPerFrame)`
///
/// The parent provides the total width via `.frame(width: totalContentWidth)`.
struct CueLaneView: View {
    let cues: [Cue]
    let audioLanes: [AudioLane]
    let pixelsPerFrame: CGFloat
    let selectedCueId: UUID?
    let onCueSelected: (UUID) -> Void
    let onCueDoubleClick: (Cue) -> Void

    /// Lane colors matching AudioClipView
    private static let laneColors: [Color] = [
        .blue, .green, .orange, .purple, .pink, .cyan, .mint, .indigo
    ]

    /// Get the lane index for a cue's source clip
    private func laneIndex(for cue: Cue) -> Int? {
        guard let clipId = cue.sourceClipId else { return nil }
        for (index, lane) in audioLanes.enumerated() {
            if lane.clips.contains(where: { $0.id == clipId }) {
                return index
            }
        }
        return nil
    }

    /// Get the color for a cue based on its source clip's lane
    private func color(for cue: Cue) -> Color {
        if let index = laneIndex(for: cue) {
            return Self.laneColors[index % Self.laneColors.count]
        }
        // Fallback to first lane color for cues without a source clip
        return Self.laneColors[0]
    }

    var body: some View {
        HStack(spacing: 0) {
            // Header (matches track headers)
            cueHeader
                .frame(width: TimelineLayout.headerWidth)

            // Cue content area - markers positioned absolutely
            ZStack(alignment: .leading) {
                // Background
                Color(white: 0.14)

                // Cue markers - positioned at frame × ppf
                ForEach(cues) { cue in
                    CueMarkerView(
                        cue: cue,
                        pixelsPerFrame: pixelsPerFrame,
                        markerColor: color(for: cue),
                        isSelected: cue.id == selectedCueId,
                        onSelect: { onCueSelected(cue.id) },
                        onDoubleClick: { onCueDoubleClick(cue) }
                    )
                    .offset(x: CGFloat(cue.startFrame) * pixelsPerFrame)
                }
            }
        }
        .frame(height: CueLaneLayout.laneHeight)
    }

    private var cueHeader: some View {
        HStack(spacing: 4) {
            Image(systemName: "flag.fill")
                .font(.system(size: 10))
                .foregroundColor(.secondary)

            Text("Cues")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)

            if !cues.isEmpty {
                Text("(\(cues.count))")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary.opacity(0.7))
            }

            Spacer()
        }
        .padding(.horizontal, Spacing.sm)
        .background(Color(white: 0.16))
    }
}

/// Individual cue marker in the cue lane.
struct CueMarkerView: View {
    let cue: Cue
    let pixelsPerFrame: CGFloat
    let markerColor: Color
    let isSelected: Bool
    let onSelect: () -> Void
    let onDoubleClick: () -> Void

    @State private var isHovered = false

    private var markerWidth: CGFloat {
        max(CueLaneLayout.markerMinWidth, CGFloat(cue.durationFrames) * pixelsPerFrame)
    }

    /// Show cue number when marker is wide enough
    private var showNumber: Bool {
        markerWidth >= CueLaneLayout.markerNumberMinWidth
    }

    /// Show title only when marker is significantly wider (zoomed in)
    private var showTitle: Bool {
        markerWidth >= CueLaneLayout.markerTitleMinWidth && !cue.title.isEmpty
    }

    var body: some View {
        Button(action: onSelect) {
            ZStack(alignment: .leading) {
                // Background
                RoundedRectangle(cornerRadius: CueLaneLayout.markerCornerRadius)
                    .fill(displayColor)

                // Border for selected state
                if isSelected {
                    RoundedRectangle(cornerRadius: CueLaneLayout.markerCornerRadius)
                        .strokeBorder(Color.white.opacity(0.8), lineWidth: 1.5)
                }

                // Cue number (when zoomed out) and title (when zoomed in)
                if showNumber {
                    HStack(spacing: 2) {
                        Text(showTitle ? "\(cue.number):" : "\(cue.number)")
                            .font(.system(size: 9, weight: .bold))
                        if showTitle {
                            Text(cue.title)
                                .font(.system(size: 9, weight: .medium))
                        }
                    }
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                }
            }
            .frame(width: markerWidth, height: CueLaneLayout.laneHeight - 4)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .simultaneousGesture(
            TapGesture(count: 2)
                .onEnded { _ in
                    onDoubleClick()
                }
        )
        .help(cueTooltip)
    }

    private var displayColor: Color {
        if isSelected {
            return markerColor.opacity(1.0)
        } else if isHovered {
            return markerColor.opacity(0.9)
        } else {
            return markerColor.opacity(0.85)
        }
    }

    private var cueTooltip: String {
        var tooltip = "Cue \(cue.number)"
        if !cue.title.isEmpty {
            tooltip += ": \(cue.title)"
        }
        return tooltip
    }
}

#Preview {
    let cues = [
        Cue(number: 1, title: "Opening", startFrame: 0, endFrame: 100),
        Cue(number: 2, title: "Scene 1", startFrame: 150, endFrame: 300),
        Cue(number: 3, title: "Transition", startFrame: 320, endFrame: 350)
    ]

    return CueLaneView(
        cues: cues,
        audioLanes: [],
        pixelsPerFrame: 0.5,
        selectedCueId: cues[0].id,
        onCueSelected: { _ in },
        onCueDoubleClick: { _ in }
    )
    .frame(width: 800)
    .background(Color(white: 0.1))
}
