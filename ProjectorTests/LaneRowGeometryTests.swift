//
//  LaneRowGeometryTests.swift
//  ProjectorTests
//
//  Tests for TrackGeometry - the shared row table behind lane reorder, marquee
//  selection, cross-lane clip drags and the new-lane drop zone.
//

import XCTest
@testable import Projector

final class LaneRowGeometryTests: XCTestCase {

    private func lane(
        name: String,
        automation: VolumeAutomation? = nil,
        isAutomationShown: Bool = false,
        ownerVideoReelId: UUID? = nil
    ) -> AudioLane {
        AudioLane(
            name: name,
            ownerVideoReelId: ownerVideoReelId,
            automation: automation,
            isAutomationShown: isAutomationShown
        )
    }

    // MARK: - Mixed heights

    /// Three standalone lanes: no automation (18pt strip), a shown sub-lane
    /// (48pt), and a hidden envelope (still 18pt - shown state, not existence,
    /// decides the strip). Rows: 98, 128, 98; last has no divider.
    func testMixedRowHeights() {
        let lanes = [
            lane(name: "DX"),
            lane(name: "MX", automation: VolumeAutomation(), isAutomationShown: true),
            lane(name: "SFX", automation: VolumeAutomation(), isAutomationShown: false)
        ]
        let timeline = Timeline(audioLanes: lanes)
        let geometry = TrackGeometry(timeline: timeline, isVideoAudioExpanded: true)

        XCTAssertEqual(geometry.rows.count, 3)
        XCTAssertEqual(geometry.rows[0].metric.height, 98)
        XCTAssertEqual(geometry.rows[1].metric.height, 128)
        XCTAssertEqual(geometry.rows[2].metric.height, 98)

        // Every row but the last carries a 1pt divider in its pitch.
        XCTAssertEqual(geometry.rows[0].metric.pitch, 99)
        XCTAssertEqual(geometry.rows[1].metric.pitch, 129)
        XCTAssertEqual(geometry.rows[2].metric.pitch, 98, "last row's pitch has no divider to add")

        // Tops accumulate by pitch, not by a shared assumption of one height.
        let expectedFirstRowTop = geometry.videoGroupHeight
        XCTAssertEqual(geometry.rows[0].metric.top, expectedFirstRowTop)
        XCTAssertEqual(geometry.rows[1].metric.top, expectedFirstRowTop + 99)
        XCTAssertEqual(geometry.rows[2].metric.top, expectedFirstRowTop + 99 + 129)

        // clipRect is always the bare 80pt lane band, whatever automation row
        // sits under it.
        for row in geometry.rows {
            XCTAssertEqual(row.clipRect.height, TimelineLayout.audioLaneHeight)
            XCTAssertNotNil(row.automationRect)
        }
        XCTAssertEqual(geometry.rows[1].automationRect?.height, TimelineLayout.automationLaneHeight)
        XCTAssertEqual(geometry.rows[0].automationRect?.height, TimelineLayout.automationStripHeight)
        XCTAssertEqual(geometry.rows[2].automationRect?.height, TimelineLayout.automationStripHeight)
    }

    // MARK: - Linked strips

    func testLinkedStripsWhenExpanded() throws {
        let reelId = UUID()
        let linked = lane(name: "Video Audio", ownerVideoReelId: reelId)
        let stem = lane(name: "DX")
        let timeline = Timeline(audioLanes: [linked, stem])

        let geometry = TrackGeometry(timeline: timeline, isVideoAudioExpanded: true)

        XCTAssertEqual(geometry.linkedStripRects.count, 1)
        let stripRect = try XCTUnwrap(geometry.linkedStripRects[linked.id])
        XCTAssertEqual(stripRect.minY, geometry.pictureRect.maxY + TimelineLayout.laneSeparatorHeight)
        XCTAssertEqual(stripRect.height, TimelineLayout.linkedAudioStripHeight)

        // The linked lane is excluded from the standalone rows entirely.
        XCTAssertEqual(geometry.rows.count, 1)
        XCTAssertEqual(geometry.rows[0].id, stem.id)

        // Standalone rows start after the picture, the strip and both
        // dividers (one before the strip, one after the group).
        let expectedFirstRowTop = Spacing.xs
            + TimelineLayout.videoTrackHeight
            + TimelineLayout.laneSeparatorHeight
            + TimelineLayout.linkedAudioStripHeight
            + TimelineLayout.laneSeparatorHeight
        XCTAssertEqual(geometry.videoGroupHeight, expectedFirstRowTop)
        XCTAssertEqual(geometry.rows[0].metric.top, expectedFirstRowTop)
    }

    func testLinkedStripsWhenCollapsed() {
        let reelId = UUID()
        let linked = lane(name: "Video Audio", ownerVideoReelId: reelId)
        let stem = lane(name: "DX")
        let timeline = Timeline(audioLanes: [linked, stem])

        let geometry = TrackGeometry(timeline: timeline, isVideoAudioExpanded: false)

        XCTAssertTrue(geometry.linkedStripRects.isEmpty)
        XCTAssertEqual(geometry.videoGroupHeight, Spacing.xs + TimelineLayout.videoTrackHeight + TimelineLayout.laneSeparatorHeight)
        XCTAssertEqual(geometry.rows.count, 1)
        XCTAssertEqual(geometry.rows[0].metric.top, geometry.videoGroupHeight)
    }

    /// A linked lane sitting between two stems in model order. The standalone
    /// rows must stay contiguous on screen (ordinals 0, 1) while each row's
    /// `modelIndex` still names its real position in `timeline.audioLanes`.
    func testLinkedLaneBetweenStemsInModelOrder() {
        let reelId = UUID()
        let first = lane(name: "DX")
        let linked = lane(name: "Video Audio", ownerVideoReelId: reelId)
        let second = lane(name: "MX")
        let timeline = Timeline(audioLanes: [first, linked, second])

        let geometry = TrackGeometry(timeline: timeline, isVideoAudioExpanded: true)

        XCTAssertEqual(geometry.rows.count, 2)
        XCTAssertEqual(geometry.rows[0].id, first.id)
        XCTAssertEqual(geometry.rows[0].ordinal, 0)
        XCTAssertEqual(geometry.rows[0].modelIndex, 0)

        XCTAssertEqual(geometry.rows[1].id, second.id)
        XCTAssertEqual(geometry.rows[1].ordinal, 1, "ordinals stay contiguous even though the linked lane sits between the stems")
        XCTAssertEqual(geometry.rows[1].modelIndex, 2, "modelIndex still names the real position in audioLanes")

        XCTAssertEqual(geometry.linkedStripRects.count, 1)
        XCTAssertNotNil(geometry.linkedStripRects[linked.id])
    }

    // MARK: - First / last row

    func testLastRowHasNoDividerInItsPitch() throws {
        let timeline = Timeline(audioLanes: [lane(name: "DX"), lane(name: "MX")])
        let geometry = TrackGeometry(timeline: timeline, isVideoAudioExpanded: true)

        let last = try XCTUnwrap(geometry.rows.last)
        XCTAssertEqual(last.metric.pitch, last.metric.height)
    }

    func testFirstRowStartsRightAfterTheVideoGroup() {
        let timeline = Timeline(audioLanes: [lane(name: "DX")])
        let geometry = TrackGeometry(timeline: timeline, isVideoAudioExpanded: true)

        XCTAssertEqual(geometry.rows.first?.metric.top, geometry.videoGroupHeight)
    }

    // MARK: - No standalone rows

    func testNoStandaloneLanesProducesNoRows() {
        let timeline = Timeline(audioLanes: [])
        let geometry = TrackGeometry(timeline: timeline, isVideoAudioExpanded: true)

        XCTAssertTrue(geometry.rows.isEmpty)
        XCTAssertTrue(geometry.metrics.isEmpty)
        XCTAssertNil(geometry.row(containingY: geometry.videoGroupHeight))
    }

    /// A timeline holding only the video's own (owned) lane - every lane is
    /// linked, so there is nothing left to draw as a standalone row.
    func testOnlyVideoOwnedLaneProducesNoStandaloneRows() {
        let reelId = UUID()
        let timeline = Timeline(audioLanes: [lane(name: "Video Audio", ownerVideoReelId: reelId)])
        let geometry = TrackGeometry(timeline: timeline, isVideoAudioExpanded: true)

        XCTAssertTrue(geometry.rows.isEmpty)
    }

    // MARK: - row(containingY:) boundaries

    func testRowContainingYAtBoundaries() {
        let lanes = [
            lane(name: "DX"),
            lane(name: "MX", automation: VolumeAutomation(), isAutomationShown: true)
        ]
        let timeline = Timeline(audioLanes: lanes)
        let geometry = TrackGeometry(timeline: timeline, isVideoAudioExpanded: true)

        let firstRow = geometry.rows[0]
        let secondRow = geometry.rows[1]

        // The top edge belongs to the row; one point above does not.
        XCTAssertEqual(geometry.row(containingY: firstRow.rowRect.minY)?.id, firstRow.id)
        XCTAssertNil(geometry.row(containingY: firstRow.rowRect.minY - 1))

        // The bottom edge (exclusive) belongs to the divider, not the row.
        XCTAssertNil(geometry.row(containingY: firstRow.rowRect.maxY))
        XCTAssertEqual(geometry.row(containingY: firstRow.rowRect.maxY - 1)?.id, firstRow.id)

        // A point squarely inside the divider between the two rows resolves
        // to neither.
        let dividerY = firstRow.metric.top + firstRow.metric.pitch - TimelineLayout.laneSeparatorHeight / 2
        XCTAssertNil(geometry.row(containingY: dividerY))

        // The last row's bottom edge, since it has no divider under it.
        XCTAssertEqual(geometry.row(containingY: secondRow.rowRect.maxY - 1)?.id, secondRow.id)
        XCTAssertNil(geometry.row(containingY: secondRow.rowRect.maxY))

        // Above everything.
        XCTAssertNil(geometry.row(containingY: 0))
    }

    // MARK: - rowHeight(for:)

    func testRowHeightForLane() {
        XCTAssertEqual(
            TrackGeometry.rowHeight(for: lane(name: "DX")),
            TimelineLayout.audioLaneHeight + TimelineLayout.automationStripHeight
        )
        XCTAssertEqual(
            TrackGeometry.rowHeight(for: lane(name: "DX", automation: VolumeAutomation(), isAutomationShown: true)),
            TimelineLayout.audioLaneHeight + TimelineLayout.automationLaneHeight
        )
        XCTAssertEqual(
            TrackGeometry.rowHeight(for: lane(name: "DX", automation: VolumeAutomation(), isAutomationShown: false)),
            TimelineLayout.audioLaneHeight + TimelineLayout.automationStripHeight,
            "a hidden envelope still draws the collapsed strip, not the sub-lane"
        )
    }
}
