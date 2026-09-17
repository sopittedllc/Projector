import Foundation
import CoreGraphics

/// The vertical layout of one pass of the tracks area: where the picture row,
/// the video's linked audio strips and every standalone lane's row sit.
///
/// Built once per layout pass (`MultiTrackTimelineView` recomputes it whenever
/// the timeline or `isVideoAudioExpanded` changes) and consumed everywhere a
/// pixel position has to become a lane, or a lane's row has to become a pixel
/// span: lane reorder, cross-lane clip drags, the last-row border, the new-lane
/// drop zone's height and marquee selection. Before this type each of those
/// computed its own version of "where is row N", and they drifted apart the
/// moment a lane could be taller than a bare 80pt - a standalone lane's row now
/// carries either an 18pt "add automation" strip or a 48pt automation sub-lane
/// along its bottom edge, never just the lane.
///
/// Every rect this type hands out only means anything vertically. The
/// initializer is not given a zoom level or a content width - it runs once per
/// timeline edit, long before a view knows how many pixels a frame is - so `x`
/// is always `0` and `width` is `Self.unboundedWidth`. Callers that need a
/// horizontal position (a clip's on-screen `x`) compute it themselves from
/// `pixelsPerFrame`, exactly as they did before this type existed; they use
/// this type only for `minY`/`maxY`/`midY`.
struct TrackGeometry {
    /// The video row's picture strip.
    let pictureRect: CGRect

    /// Each expanded linked-audio strip drawn under the picture, by lane id.
    /// Empty when `isVideoAudioExpanded` is `false`, or the video has no
    /// linked audio.
    let linkedStripRects: [UUID: CGRect]

    /// Picture, its linked strips and the dividers between and after them.
    /// Standalone rows start immediately below this.
    let videoGroupHeight: CGFloat

    /// Standalone lanes, in visible (on-screen) order.
    let rows: [LaneRowGeometry]

    /// Sentinel width for every rect this type hands out. See the type-level
    /// discussion: nothing here reads `minX`/`maxX`/`width`.
    private static let unboundedWidth: CGFloat = .greatestFiniteMagnitude

    /// A standalone lane's full row height: the lane itself, plus whichever
    /// automation row is currently drawn under it.
    ///
    /// Never a bare `TimelineLayout.audioLaneHeight` - every standalone row
    /// carries the 18pt "add automation" strip or the 48pt sub-lane, one or
    /// the other, always.
    static func rowHeight(for lane: AudioLane) -> CGFloat {
        TimelineLayout.audioLaneHeight + (isAutomationExpanded(lane)
            ? TimelineLayout.automationLaneHeight
            : TimelineLayout.automationStripHeight)
    }

    private static func isAutomationExpanded(_ lane: AudioLane) -> Bool {
        lane.automation != nil && lane.isAutomationShown
    }

    /// - Parameters:
    ///   - timeline: The timeline to lay out.
    ///   - isVideoAudioExpanded: Whether the video's linked audio strips are
    ///     currently drawn under the picture.
    init(timeline: Timeline, isVideoAudioExpanded: Bool) {
        let linkedLanes = isVideoAudioExpanded ? timeline.videoAudioLanes : []

        let pictureRect = CGRect(
            x: 0,
            y: Spacing.xs,
            width: Self.unboundedWidth,
            height: TimelineLayout.videoTrackHeight
        )

        var linkedRects: [UUID: CGRect] = [:]
        var cursor = pictureRect.maxY
        for lane in linkedLanes {
            // A divider precedes every linked strip, including the first -
            // `videoFileTrack` draws `laneBorder` before each row in its
            // `ForEach`, the picture row included.
            cursor += TimelineLayout.laneSeparatorHeight
            linkedRects[lane.id] = CGRect(
                x: 0,
                y: cursor,
                width: Self.unboundedWidth,
                height: TimelineLayout.linkedAudioStripHeight
            )
            cursor += TimelineLayout.linkedAudioStripHeight
        }

        // The divider between the video group and the first standalone row.
        cursor += TimelineLayout.laneSeparatorHeight

        self.pictureRect = pictureRect
        self.linkedStripRects = linkedRects
        self.videoGroupHeight = cursor

        let standalone = timeline.standaloneAudioLanes
        var builtRows: [LaneRowGeometry] = []
        builtRows.reserveCapacity(standalone.count)
        var rowTop = cursor

        for (ordinal, lane) in standalone.enumerated() {
            let modelIndex = timeline.audioLanes.firstIndex(where: { $0.id == lane.id }) ?? ordinal
            let rowHeight = Self.rowHeight(for: lane)
            let isLastRow = ordinal == standalone.count - 1
            let pitch = rowHeight + (isLastRow ? 0 : TimelineLayout.laneSeparatorHeight)

            let rowRect = CGRect(x: 0, y: rowTop, width: Self.unboundedWidth, height: rowHeight)
            let clipRect = CGRect(x: 0, y: rowTop, width: Self.unboundedWidth, height: TimelineLayout.audioLaneHeight)
            let automationRect = CGRect(
                x: 0,
                y: rowTop + TimelineLayout.audioLaneHeight,
                width: Self.unboundedWidth,
                height: rowHeight - TimelineLayout.audioLaneHeight
            )

            let metric = LaneRowMetric(id: lane.id, top: rowTop, height: rowHeight, pitch: pitch)
            builtRows.append(
                LaneRowGeometry(
                    id: lane.id,
                    ordinal: ordinal,
                    modelIndex: modelIndex,
                    rowRect: rowRect,
                    clipRect: clipRect,
                    automationRect: automationRect,
                    metric: metric
                )
            )

            rowTop += pitch
        }

        self.rows = builtRows
    }

    /// The standalone row whose full row band (lane plus automation strip or
    /// sub-lane) contains `y`.
    ///
    /// `nil` for a `y` inside a divider between rows, above the first row, or
    /// below the last - a caller resolving a drop or a reorder target treats
    /// that as "no lane", not as the nearest one.
    func row(containingY y: CGFloat) -> LaneRowGeometry? {
        rows.first { y >= $0.rowRect.minY && y < $0.rowRect.maxY }
    }

    /// The pure geometry `LaneReorder` needs, in visible order.
    var metrics: [LaneRowMetric] {
        rows.map(\.metric)
    }
}

/// One standalone lane's row: its position in both orderings, and the rects a
/// caller needs to hit-test or draw it.
struct LaneRowGeometry: Identifiable {
    /// The lane this row belongs to.
    let id: UUID

    /// Position among the rows actually drawn, top to bottom. What a reorder
    /// drag or a marquee selection reasons about.
    let ordinal: Int

    /// Position in `Timeline.audioLanes`. What `TimelineManager`'s index-based
    /// mutations need; resolved once here so nothing else has to assume the
    /// two orderings agree.
    let modelIndex: Int

    /// The row's full vertical band: the lane and its automation strip or
    /// sub-lane together. What `LaneReorder` and lane-change hit-testing
    /// reason about.
    let rowRect: CGRect

    /// Just the lane's own band - `TimelineLayout.audioLaneHeight` tall.
    /// Marquee selection tests clips against this, not `rowRect`, so a
    /// marquee drawn entirely over the automation row selects nothing.
    let clipRect: CGRect

    /// The strip or sub-lane band directly under `clipRect`. Always present
    /// for a standalone row - every one carries the 18pt strip or the 48pt
    /// sub-lane - kept optional so a future row kind without one is not
    /// forced to invent a zero-height rect.
    let automationRect: CGRect?

    /// The pure geometry handed to `LaneReorder`.
    let metric: LaneRowMetric
}
