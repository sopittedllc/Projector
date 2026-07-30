//
//  HardPannedSplitTests.swift
//  ProjectorTests
//
//  Tests for splitting hard-panned video audio into two locked lanes:
//  persistence, the derived/owned fallback, and the split itself.
//

import XCTest
@testable import Projector
import SwiftTimecodeCore

@MainActor
final class HardPannedSplitTests: XCTestCase {

    private let reelURL = URL(fileURLWithPath: "/tmp/Reel_01.mov")

    private func makeManager() -> TimelineManager {
        let startTC = Timecode(.components(h: 0, m: 0, s: 0, f: 0), at: .fps24, by: .clamping)
        let endTC = Timecode(.components(h: 0, m: 10, s: 0, f: 0), at: .fps24, by: .clamping)
        let config = TimelineConfig(
            startTimecode: startTC,
            endTimecode: endTC,
            frameRate: .fps24
        )
        return TimelineManager(timeline: Timeline(config: config, videoReels: [], audioLanes: []))
    }

    private func makeVideoClip(start: Int = 0, duration: Int = 240) -> AudioClip {
        AudioClip(
            sourceURL: reelURL,
            timelineStartFrame: start,
            durationFrames: duration,
            sourceType: .videoTrack,
            sourceTrackIndex: 0
        )
    }

    // MARK: - Persistence

    func testSplitChannelSurvivesClipRoundTrip() throws {
        let clip = AudioClip(
            sourceURL: reelURL,
            timelineStartFrame: 48,
            durationFrames: 240,
            sourceType: .videoTrack,
            channelCount: 1,
            sourceChannel: .right
        )

        let data = try JSONEncoder().encode(clip)
        let decoded = try JSONDecoder().decode(AudioClip.self, from: data)

        XCTAssertEqual(decoded.sourceChannel, .right)
        XCTAssertEqual(decoded.channelCount, 1)
    }

    func testOwnershipSurvivesLaneRoundTrip() throws {
        let reelId = UUID()
        let lane = AudioLane(
            name: "MX",
            clips: [makeVideoClip()],
            outputChannelCount: 1,
            colorIndex: 1,
            ownerVideoReelId: reelId,
            splitChannel: .right
        )

        let data = try JSONEncoder().encode(lane)
        let decoded = try JSONDecoder().decode(AudioLane.self, from: data)

        XCTAssertEqual(decoded.ownerVideoReelId, reelId)
        XCTAssertEqual(decoded.splitChannel, .right)
        XCTAssertTrue(decoded.isLockedToVideo)
    }

    /// A project saved before splitting existed must still open, with its lanes
    /// unowned rather than failing to decode.
    func testLaneSavedBeforeSplittingDecodesUnowned() throws {
        let legacyJSON = """
        {
            "id": "\(UUID().uuidString)",
            "name": "Dialogue",
            "clips": [],
            "isMuted": false,
            "isSolo": false,
            "volume": 1.0,
            "outputChannelOffset": 0,
            "outputChannelCount": 2,
            "colorIndex": 2
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(AudioLane.self, from: legacyJSON)

        XCTAssertNil(decoded.ownerVideoReelId)
        XCTAssertNil(decoded.splitChannel)
        XCTAssertFalse(decoded.isLockedToVideo)
    }

    func testClipSavedBeforeSplittingDecodesWithoutChannel() throws {
        let legacyJSON = """
        {
            "id": "\(UUID().uuidString)",
            "sourcePath": "/tmp/Reel_01.mov",
            "timelineStartFrame": 0,
            "durationFrames": 240,
            "sourceStartFrame": 0,
            "sourceType": "videoTrack",
            "volume": 1.0,
            "isMuted": false
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(AudioClip.self, from: legacyJSON)

        XCTAssertNil(decoded.sourceChannel)
        XCTAssertEqual(decoded.sourceType, .videoTrack)
    }

    // MARK: - Lane Derivation

    func testOwnedLanesAreReturnedLeftThenRight() {
        let manager = makeManager()
        let reelId = UUID()

        // Deliberately added right-first, so ordering cannot pass by accident.
        manager.timeline.addAudioLane(AudioLane(
            name: "MX", clips: [makeVideoClip()],
            ownerVideoReelId: reelId, splitChannel: .right
        ))
        manager.timeline.addAudioLane(AudioLane(
            name: "DX/SFX", clips: [makeVideoClip()],
            ownerVideoReelId: reelId, splitChannel: .left
        ))

        let linked = manager.timeline.videoAudioLanes

        XCTAssertEqual(linked.count, 2)
        XCTAssertEqual(linked.first?.splitChannel, .left)
        XCTAssertEqual(linked.last?.splitChannel, .right)
    }

    /// Ownership and the derived rule must never combine, or a split pair would
    /// pick up an unrelated lane that merely holds video audio.
    func testOwnedLanesSuppressTheDerivedRule() {
        let manager = makeManager()
        let reelId = UUID()

        manager.timeline.addAudioLane(AudioLane(
            name: "DX/SFX", clips: [makeVideoClip()],
            ownerVideoReelId: reelId, splitChannel: .left
        ))
        manager.timeline.addAudioLane(AudioLane(
            name: "MX", clips: [makeVideoClip()],
            ownerVideoReelId: reelId, splitChannel: .right
        ))
        // Unowned, but every clip came from a video track - the derived rule
        // would otherwise claim this too.
        manager.timeline.addAudioLane(AudioLane(name: "Stray", clips: [makeVideoClip()]))

        XCTAssertEqual(manager.timeline.videoAudioLanes.count, 2)
        XCTAssertTrue(manager.timeline.videoAudioLanes.allSatisfy(\.isLockedToVideo))
    }

    /// Projects saved before ownership existed still identify their video lane.
    func testDerivedRuleStillFindsVideoLaneWhenNothingIsOwned() {
        let manager = makeManager()
        manager.timeline.addAudioLane(AudioLane(name: "Video Audio", clips: [makeVideoClip()]))
        manager.timeline.addAudioLane(AudioLane(name: "Music", clips: [
            AudioClip(sourceURL: URL(fileURLWithPath: "/tmp/cue.wav"),
                      timelineStartFrame: 0, durationFrames: 240, sourceType: .audioFile)
        ]))

        let linked = manager.timeline.videoAudioLanes

        XCTAssertEqual(linked.count, 1)
        XCTAssertEqual(linked.first?.name, "Video Audio")
    }

    func testStandaloneLanesExcludeBothSplitLanes() {
        let manager = makeManager()
        let reelId = UUID()

        manager.timeline.addAudioLane(AudioLane(
            name: "DX/SFX", clips: [makeVideoClip()],
            ownerVideoReelId: reelId, splitChannel: .left
        ))
        manager.timeline.addAudioLane(AudioLane(
            name: "MX", clips: [makeVideoClip()],
            ownerVideoReelId: reelId, splitChannel: .right
        ))
        manager.timeline.addAudioLane(AudioLane(name: "Foley"))

        let standalone = manager.timeline.standaloneAudioLanes

        XCTAssertEqual(standalone.count, 1)
        XCTAssertEqual(standalone.first?.name, "Foley")
    }

    // MARK: - The Split

    func testSplitProducesTwoOwnedMonoLanes() throws {
        let manager = makeManager()
        let reelId = UUID()
        let lane = manager.addAudioLane(name: "Reel_01")
        manager.timeline.addClip(makeVideoClip(), toLane: lane.id)

        let output = MappedAudioOutput(name: "Stereo Out", channelStart: 0, channelCount: 2)
        manager.setLaneOutputMapping(id: lane.id, mapping: output)
        let original = try XCTUnwrap(manager.timeline.audioLanes.first { $0.id == lane.id })

        let created = try XCTUnwrap(manager.splitVideoAudioLaneByChannel(
            laneId: lane.id,
            reelId: reelId,
            names: [.left: "DX/SFX", .right: "MX"]
        ))

        XCTAssertEqual(created.count, 2)
        XCTAssertNil(manager.timeline.audioLanes.first { $0.id == lane.id },
                     "the original lane should be replaced, not left behind")

        XCTAssertEqual(created[0].name, "DX/SFX")
        XCTAssertEqual(created[0].splitChannel, .left)
        XCTAssertEqual(created[1].name, "MX")
        XCTAssertEqual(created[1].splitChannel, .right)

        // Both sides keep the routing the video's audio already had. Sending
        // them to the DX/SFX and MX roles instead moved the audio off whatever
        // was being monitored, which is indistinguishable from playback breaking.
        for lane in created {
            XCTAssertEqual(lane.outputMappingId, original.outputMappingId,
                           "a split lane must inherit its output, not be re-pointed")
        }

        for lane in created {
            XCTAssertEqual(lane.ownerVideoReelId, reelId)
            XCTAssertTrue(lane.isLockedToVideo)
            // A mono clip spanning a stereo output is what un-pans the side: the
            // mixer duplicates one input channel across two output channels.
            // Setting the lane to one output channel plays it out of the left
            // speaker only, which is the panning the split exists to undo.
            XCTAssertEqual(lane.outputChannelCount, 2,
                           "a split lane must span a stereo output, or it plays hard left")
            XCTAssertEqual(lane.clips.count, 1)
            XCTAssertEqual(lane.clips.first?.channelCount, 1)
            XCTAssertEqual(lane.clips.first?.sourceChannel, lane.splitChannel)
            XCTAssertNil(lane.clips.first?.extractedAudioURL,
                         "the stereo extraction must not be reused, or both lanes play both sides")
        }
    }

    func testSplitLanesKeepTimingOfTheOriginalClip() throws {
        let manager = makeManager()
        let lane = manager.addAudioLane(name: "Reel_01")
        manager.timeline.addClip(makeVideoClip(start: 120, duration: 360), toLane: lane.id)

        let created = try XCTUnwrap(manager.splitVideoAudioLaneByChannel(
            laneId: lane.id, reelId: UUID(), names: [.left: "DX/SFX", .right: "MX"]
        ))

        for lane in created {
            XCTAssertEqual(lane.clips.first?.timelineStartFrame, 120)
            XCTAssertEqual(lane.clips.first?.durationFrames, 360)
        }
    }

    func testSplitLanesSurviveATimelineRoundTrip() throws {
        let manager = makeManager()
        let reelId = UUID()
        let lane = manager.addAudioLane(name: "Reel_01")
        manager.timeline.addClip(makeVideoClip(), toLane: lane.id)
        manager.splitVideoAudioLaneByChannel(
            laneId: lane.id, reelId: reelId, names: [.left: "DX/SFX", .right: "MX"]
        )

        let data = try JSONEncoder().encode(manager.timeline)
        let decoded = try JSONDecoder().decode(Timeline.self, from: data)

        let linked = decoded.videoAudioLanes
        XCTAssertEqual(linked.count, 2)
        XCTAssertEqual(linked.first?.splitChannel, .left)
        XCTAssertEqual(linked.last?.splitChannel, .right)
        XCTAssertTrue(linked.allSatisfy { $0.ownerVideoReelId == reelId })
        XCTAssertTrue(decoded.standaloneAudioLanes.isEmpty)
    }

    func testDeletingTheReelRemovesBothOwnedLanes() {
        let manager = makeManager()
        let reelId = UUID()

        manager.timeline.addAudioLane(AudioLane(
            name: "DX/SFX", clips: [makeVideoClip()],
            ownerVideoReelId: reelId, splitChannel: .left
        ))
        manager.timeline.addAudioLane(AudioLane(
            name: "MX", clips: [makeVideoClip()],
            ownerVideoReelId: reelId, splitChannel: .right
        ))
        manager.timeline.addAudioLane(AudioLane(name: "Foley"))

        manager.removeLanesOwned(byReel: reelId)

        XCTAssertEqual(manager.timeline.audioLanes.count, 1)
        XCTAssertEqual(manager.timeline.audioLanes.first?.name, "Foley")
    }

    func testLanesOwnedByAnotherReelAreLeftAlone() {
        let manager = makeManager()
        let keepReelId = UUID()
        let deleteReelId = UUID()

        manager.timeline.addAudioLane(AudioLane(
            name: "Reel 1 DX", clips: [makeVideoClip()],
            ownerVideoReelId: keepReelId, splitChannel: .left
        ))
        manager.timeline.addAudioLane(AudioLane(
            name: "Reel 2 DX", clips: [makeVideoClip()],
            ownerVideoReelId: deleteReelId, splitChannel: .left
        ))

        manager.removeLanesOwned(byReel: deleteReelId)

        XCTAssertEqual(manager.timeline.audioLanes.count, 1)
        XCTAssertEqual(manager.timeline.audioLanes.first?.ownerVideoReelId, keepReelId)
    }

    func testSplitClipSourceIsAttachedToTheRightLane() throws {
        let manager = makeManager()
        let lane = manager.addAudioLane(name: "Reel_01")
        manager.timeline.addClip(makeVideoClip(), toLane: lane.id)
        let created = try XCTUnwrap(manager.splitVideoAudioLaneByChannel(
            laneId: lane.id, reelId: UUID(), names: [.left: "DX/SFX", .right: "MX"]
        ))

        let leftURL = URL(fileURLWithPath: "/tmp/Reel_01-left.caf")
        manager.updateSplitClipSource(laneId: created[0].id, extractedURL: leftURL)

        let lanes = manager.timeline.audioLanes
        let left = lanes.first { $0.id == created[0].id }
        let right = lanes.first { $0.id == created[1].id }

        XCTAssertEqual(left?.clips.first?.extractedAudioURL, leftURL)
        XCTAssertNil(right?.clips.first?.extractedAudioURL,
                     "attaching one side must not touch the other")
    }

    // MARK: - Routing

    /// Assigning an output must keep the lane spanning a stereo pair, since that
    /// is what duplicates a mono side across both speakers.
    func testAssigningAStereoOutputKeepsTheLaneStereo() throws {
        let manager = makeManager()
        let lane = manager.addAudioLane(name: "Reel_01")
        manager.timeline.addClip(makeVideoClip(), toLane: lane.id)
        let created = try XCTUnwrap(manager.splitVideoAudioLaneByChannel(
            laneId: lane.id, reelId: UUID(), names: [.left: "DX/SFX", .right: "MX"]
        ))

        let output = MappedAudioOutput(
            name: "DX/SFX", channelStart: 2, channelCount: 2,
            roleId: "dx-sfx"
        )
        manager.setLaneOutputMapping(id: created[0].id, mapping: output)

        let routed = try XCTUnwrap(manager.timeline.audioLanes.first { $0.id == created[0].id })
        XCTAssertEqual(routed.outputMappingId, output.id)
        XCTAssertEqual(routed.outputChannelOffset, 2)
        XCTAssertEqual(routed.outputChannelCount, 2, "still a stereo span after routing")
        XCTAssertFalse(routed.isOutputDisabled)
    }

    /// Routing one side must not disturb the other.
    func testRoutingOneSplitLaneLeavesTheOtherAlone() throws {
        let manager = makeManager()
        let lane = manager.addAudioLane(name: "Reel_01")
        manager.timeline.addClip(makeVideoClip(), toLane: lane.id)
        let created = try XCTUnwrap(manager.splitVideoAudioLaneByChannel(
            laneId: lane.id, reelId: UUID(), names: [.left: "DX/SFX", .right: "MX"]
        ))

        manager.setLaneOutputMapping(
            id: created[0].id,
            mapping: MappedAudioOutput(name: "DX/SFX", channelStart: 2, channelCount: 2, roleId: "dx-sfx")
        )

        let right = try XCTUnwrap(manager.timeline.audioLanes.first { $0.id == created[1].id })
        XCTAssertNil(right.outputMappingId, "the right lane should still be unassigned")
    }

    func testSplittingALaneWithNoClipsFails() {
        let manager = makeManager()
        let lane = manager.addAudioLane(name: "Empty")

        XCTAssertNil(manager.splitVideoAudioLaneByChannel(
            laneId: lane.id, reelId: UUID(), names: [.left: "DX/SFX", .right: "MX"]
        ))
        XCTAssertEqual(manager.timeline.audioLanes.count, 1, "a failed split must change nothing")
    }
}
