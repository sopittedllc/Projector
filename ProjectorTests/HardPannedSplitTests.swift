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

    func testSplitProducesTwoMonoLanesLockedToVideo() throws {
        let manager = makeManager()
        let reelId = UUID()
        let lane = manager.addAudioLane(name: "Reel_01")
        let clip = makeVideoClip()
        manager.timeline.addClip(clip, toLane: lane.id)

        let output = MappedAudioOutput(name: "Stereo Out", channelStart: 0, channelCount: 2)
        manager.setLaneOutputMapping(id: lane.id, mapping: output)
        let original = try XCTUnwrap(manager.timeline.audioLanes.first { $0.id == lane.id })

        let created = try XCTUnwrap(manager.splitVideoAudioClipByChannel(
            clipId: clip.id,
            inLane: lane.id,
            reelId: reelId,
            names: [.left: "DX/SFX", .right: "MX"]
        ))

        XCTAssertEqual(created.count, 2)
        XCTAssertNil(manager.timeline.audioLanes.first { $0.id == lane.id },
                     "a lane emptied by the split should not be left behind")

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
            // Shared by every split reel, so no single reel owns it; the side is
            // what marks it as video audio.
            XCTAssertNil(lane.ownerVideoReelId)
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
        let clip = makeVideoClip(start: 120, duration: 360)
        manager.timeline.addClip(clip, toLane: lane.id)

        let created = try XCTUnwrap(manager.splitVideoAudioClipByChannel(
            clipId: clip.id, inLane: lane.id, reelId: UUID(),
            names: [.left: "DX/SFX", .right: "MX"]
        ))

        for lane in created {
            XCTAssertEqual(lane.clips.first?.timelineStartFrame, 120)
            XCTAssertEqual(lane.clips.first?.durationFrames, 360)
        }
    }

    func testSplitLanesSurviveATimelineRoundTrip() throws {
        let manager = makeManager()
        let lane = manager.addAudioLane(name: "Reel_01")
        let clip = makeVideoClip()
        manager.timeline.addClip(clip, toLane: lane.id)
        manager.splitVideoAudioClipByChannel(
            clipId: clip.id, inLane: lane.id, reelId: UUID(),
            names: [.left: "DX/SFX", .right: "MX"]
        )

        let data = try JSONEncoder().encode(manager.timeline)
        let decoded = try JSONDecoder().decode(Timeline.self, from: data)

        let linked = decoded.videoAudioLanes
        XCTAssertEqual(linked.count, 2)
        XCTAssertEqual(linked.first?.splitChannel, .left)
        XCTAssertEqual(linked.last?.splitChannel, .right)
        XCTAssertTrue(decoded.standaloneAudioLanes.isEmpty)
    }

    // MARK: - Shared Lanes

    /// A second split joins the lanes the first one made, so six reels give two
    /// lanes rather than twelve.
    func testSplittingASecondReelReusesTheSameTwoLanes() throws {
        let manager = makeManager()
        let lane = manager.addAudioLane(name: "Video Audio")
        let clipA = makeVideoClip(start: 0, duration: 480)
        let clipB = makeVideoClip(start: 480, duration: 480)
        manager.timeline.addClip(clipA, toLane: lane.id)
        manager.timeline.addClip(clipB, toLane: lane.id)

        manager.splitVideoAudioClipByChannel(
            clipId: clipA.id, inLane: lane.id, reelId: UUID(),
            names: [.left: "DX/SFX", .right: "MX"]
        )
        manager.splitVideoAudioClipByChannel(
            clipId: clipB.id, inLane: lane.id, reelId: UUID(),
            names: [.left: "DX/SFX", .right: "MX"]
        )

        let splitLanes = manager.timeline.audioLanes.filter { $0.splitChannel != nil }
        XCTAssertEqual(splitLanes.count, 2, "both reels should share one lane per side")
        for lane in splitLanes {
            XCTAssertEqual(lane.clips.count, 2, "each side should hold a clip from both reels")
        }
    }

    func testSplittingOneReelKeepsAnotherReelsClipInTheSameLane() throws {
        let manager = makeManager()
        let lane = manager.addAudioLane(name: "Video Audio")
        let clipA = makeVideoClip(start: 0, duration: 480)
        let clipB = makeVideoClip(start: 480, duration: 480)
        manager.timeline.addClip(clipA, toLane: lane.id)
        manager.timeline.addClip(clipB, toLane: lane.id)

        manager.splitVideoAudioClipByChannel(
            clipId: clipA.id, inLane: lane.id, reelId: UUID(),
            names: [.left: "DX/SFX", .right: "MX"]
        )

        let survivor = manager.timeline.audioLanes.first { $0.id == lane.id }
        XCTAssertEqual(survivor?.clips.map(\.id), [clipB.id],
                       "splitting one reel must not destroy another reel's audio")
    }

    func testDeletingAReelTakesOnlyItsOwnSplitClips() {
        let manager = makeManager()
        let keptURL = URL(fileURLWithPath: "/tmp/Reel_02.mov")
        let goingReelId = UUID()

        for channel in [SplitChannel.left, .right] {
            manager.timeline.addAudioLane(AudioLane(
                name: channel.conventionalRoleName,
                clips: [
                    AudioClip(sourceURL: reelURL, timelineStartFrame: 0, durationFrames: 240,
                              sourceType: .videoTrack, sourceChannel: channel),
                    AudioClip(sourceURL: keptURL, timelineStartFrame: 240, durationFrames: 240,
                              sourceType: .videoTrack, sourceChannel: channel)
                ],
                splitChannel: channel
            ))
        }

        manager.removeLanesOwned(byReel: goingReelId, sourceURL: reelURL)

        let splitLanes = manager.timeline.audioLanes.filter { $0.splitChannel != nil }
        XCTAssertEqual(splitLanes.count, 2, "the shared lanes must survive")
        for lane in splitLanes {
            XCTAssertEqual(lane.clips.map(\.sourceURL), [keptURL],
                           "only the removed reel's clips should go")
        }
    }

    func testDeletingTheLastSplitReelRemovesTheEmptyLanes() {
        let manager = makeManager()
        for channel in [SplitChannel.left, .right] {
            manager.timeline.addAudioLane(AudioLane(
                name: channel.conventionalRoleName,
                clips: [AudioClip(sourceURL: reelURL, timelineStartFrame: 0, durationFrames: 240,
                                  sourceType: .videoTrack, sourceChannel: channel)],
                splitChannel: channel
            ))
        }

        manager.removeLanesOwned(byReel: UUID(), sourceURL: reelURL)

        XCTAssertTrue(manager.timeline.audioLanes.isEmpty,
                      "a split lane with nothing left on it is just clutter")
    }

    // MARK: - Legacy Ownership

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

    // MARK: - Extraction



    // MARK: - Routing

    /// Assigning an output must keep the lane spanning a stereo pair, since that
    /// is what duplicates a mono side across both speakers.
    func testAssigningAStereoOutputKeepsTheLaneStereo() throws {
        let manager = makeManager()
        let lane = manager.addAudioLane(name: "Reel_01")
        let clip = makeVideoClip()
        manager.timeline.addClip(clip, toLane: lane.id)
        let created = try XCTUnwrap(manager.splitVideoAudioClipByChannel(
            clipId: clip.id, inLane: lane.id, reelId: UUID(),
            names: [.left: "DX/SFX", .right: "MX"]
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
        let clip = makeVideoClip()
        manager.timeline.addClip(clip, toLane: lane.id)
        let created = try XCTUnwrap(manager.splitVideoAudioClipByChannel(
            clipId: clip.id, inLane: lane.id, reelId: UUID(),
            names: [.left: "DX/SFX", .right: "MX"]
        ))

        manager.setLaneOutputMapping(
            id: created[0].id,
            mapping: MappedAudioOutput(name: "DX/SFX", channelStart: 2, channelCount: 2, roleId: "dx-sfx")
        )

        let right = try XCTUnwrap(manager.timeline.audioLanes.first { $0.id == created[1].id })
        XCTAssertNil(right.outputMappingId, "the right lane should still be unassigned")
    }

    func testSplittingAClipThatIsNotThereFails() {
        let manager = makeManager()
        let lane = manager.addAudioLane(name: "Empty")

        XCTAssertNil(manager.splitVideoAudioClipByChannel(
            clipId: UUID(), inLane: lane.id, reelId: UUID(),
            names: [.left: "DX/SFX", .right: "MX"]
        ))
        XCTAssertEqual(manager.timeline.audioLanes.count, 1, "a failed split must change nothing")
    }

    // MARK: - Output Naming

    /// A lane with no mapping is not silent - the engine feeds it from its
    /// channel span - so a split lane must state the output it is really on.
    func testSplitLanesCarryTheChannelSpanTheEngineWillUse() throws {
        let manager = makeManager()
        let lane = manager.addAudioLane(name: "Reel_01")
        let clip = makeVideoClip()
        manager.timeline.addClip(clip, toLane: lane.id)

        let created = try XCTUnwrap(manager.splitVideoAudioClipByChannel(
            clipId: clip.id, inLane: lane.id, reelId: UUID(),
            names: [.left: "DX/SFX", .right: "MX"]
        ))

        for lane in created {
            XCTAssertEqual(lane.outputChannelCount, 2)
            XCTAssertEqual(lane.outputChannelOffset, 0,
                           "the span the engine falls back to must be the one a lane advertises")
        }
    }

    /// Splitting a lane that already has an output must carry it to both sides,
    /// so the sound does not move off whatever is being monitored.
    func testSplitLanesInheritAnExplicitOutput() throws {
        let manager = makeManager()
        let lane = manager.addAudioLane(name: "Reel_01")
        let clip = makeVideoClip()
        manager.timeline.addClip(clip, toLane: lane.id)

        let output = MappedAudioOutput(name: "Stereo Out", channelStart: 0, channelCount: 2)
        manager.setLaneOutputMapping(id: lane.id, mapping: output)

        let created = try XCTUnwrap(manager.splitVideoAudioClipByChannel(
            clipId: clip.id, inLane: lane.id, reelId: UUID(),
            names: [.left: "DX/SFX", .right: "MX"]
        ))

        for lane in created {
            XCTAssertEqual(lane.outputMappingId, output.id,
                           "both sides must keep the output the video audio was using")
        }
    }

    // MARK: - Waveform Handover

    /// The stereo trace already on screen holds both sides separately, so a
    /// split can hand each one over instead of decoding to recompute it.
    func testSplitClipAdoptsTheChannelAlreadyDrawn() {
        let cache = WaveformCache()
        let stereoClipId = UUID()
        let leftClipId = UUID()

        let left = WaveformLevel(min: [-0.1, -0.9, -0.3], max: [0.1, 0.9, 0.3], rms: [0.05, 0.6, 0.2])
        let right = WaveformLevel(min: [-0.4, -0.2, -0.8], max: [0.4, 0.2, 0.8], rms: [0.3, 0.1, 0.5])
        cache.setAtlasForTesting(
            WaveformAtlas(
                duration: 12,
                levels: [3: WaveformLevel(min: [-0.25, -0.55, -0.55], max: [0.25, 0.55, 0.55], rms: [0.2, 0.35, 0.35])],
                channelLevels: [[3: left], [3: right]]
            ),
            for: stereoClipId
        )

        let adopted = cache.adoptChannel(from: stereoClipId, channel: .left, as: leftClipId)

        XCTAssertTrue(adopted)
        let atlas = cache.clipAtlases[leftClipId]
        XCTAssertEqual(atlas?.duration, 12)
        XCTAssertEqual(atlas?.levels[3]?.max, left.max,
                       "the split clip must draw the exact side it was already showing")
        XCTAssertTrue(atlas?.channelLevels.isEmpty ?? false,
                      "a mono clip has no channels of its own to keep apart")
    }

    func testAdoptingTheRightChannelTakesTheOtherSide() {
        let cache = WaveformCache()
        let stereoClipId = UUID()
        let rightClipId = UUID()

        let left = WaveformLevel(min: [-0.1, -0.9], max: [0.1, 0.9], rms: [0.05, 0.6])
        let right = WaveformLevel(min: [-0.4, -0.2], max: [0.4, 0.2], rms: [0.3, 0.1])
        cache.setAtlasForTesting(
            WaveformAtlas(duration: 8, levels: [2: left], channelLevels: [[2: left], [2: right]]),
            for: stereoClipId
        )

        cache.adoptChannel(from: stereoClipId, channel: .right, as: rightClipId)

        XCTAssertEqual(cache.clipAtlases[rightClipId]?.levels[2]?.max, right.max)
    }

    /// Nothing to hand over when the stereo trace had not finished drawing, and
    /// the caller has to know so the clip can generate its own.
    func testAdoptingReportsFailureWithoutPerChannelData() {
        let cache = WaveformCache()
        let stereoClipId = UUID()

        cache.setAtlasForTesting(
            WaveformAtlas(duration: 5, levels: [2: WaveformLevel(min: [-0.5, -0.5], max: [0.5, 0.5], rms: [0.4, 0.4])]),
            for: stereoClipId
        )

        XCTAssertFalse(cache.adoptChannel(from: stereoClipId, channel: .left, as: UUID()))
        XCTAssertFalse(cache.adoptChannel(from: UUID(), channel: .left, as: UUID()),
                       "an unknown clip has nothing to give")
    }

    // MARK: - Undo

    /// Splitting happens without being asked, so restoring the timeline exactly
    /// as the import left it is what makes that safe.
    func testRestoringASnapshotUndoesAWholeBatchSplit() throws {
        let manager = makeManager()
        let lane = manager.addAudioLane(name: "Video Audio")
        let clipA = makeVideoClip(start: 0, duration: 480)
        let clipB = makeVideoClip(start: 480, duration: 480)
        manager.timeline.addClip(clipA, toLane: lane.id)
        manager.timeline.addClip(clipB, toLane: lane.id)

        // What the undo registration captures before anything moves.
        let snapshot = manager.timeline

        manager.splitVideoAudioClipByChannel(
            clipId: clipA.id, inLane: lane.id, reelId: UUID(),
            names: [.left: "DX/SFX", .right: "MX"]
        )
        manager.splitVideoAudioClipByChannel(
            clipId: clipB.id, inLane: lane.id, reelId: UUID(),
            names: [.left: "DX/SFX", .right: "MX"]
        )
        XCTAssertEqual(manager.timeline.audioLanes.filter { $0.splitChannel != nil }.count, 2)

        manager.timeline = snapshot

        let lanes = manager.timeline.audioLanes
        XCTAssertEqual(lanes.count, 1, "one undo must take both reels' splits with it")
        XCTAssertTrue(lanes.allSatisfy { $0.splitChannel == nil })
        XCTAssertEqual(lanes.first?.clips.map(\.id), [clipA.id, clipB.id],
                       "both reels' original clips must come back to the lane they were on")
    }

    // MARK: - Split Roles

    /// Each side belongs on the output configured for its role. Matching on the
    /// channel span instead put both lanes on the same output, since a split
    /// pair shares one.
    func testEachSideCarriesItsOwnRoleIdentifier() {
        XCTAssertEqual(SplitChannel.left.conventionalRoleId, "dx-sfx")
        XCTAssertEqual(SplitChannel.right.conventionalRoleId, "mx")
        XCTAssertNotEqual(
            SplitChannel.left.conventionalRoleId,
            SplitChannel.right.conventionalRoleId,
            "the two sides must not resolve to one output"
        )
    }

    /// The identifiers have to match the roles the settings UI writes, or a
    /// configured output will never be found.
    func testRoleIdentifiersMatchTheConfiguredOutputs() {
        let dx = MappedAudioOutput(name: "DX/SFX", channelStart: 2, channelCount: 2, roleId: "dx-sfx")
        let mx = MappedAudioOutput(name: "MX", channelStart: 4, channelCount: 2, roleId: "mx")
        let outputs = [dx, mx]

        let forLeft = outputs.first { $0.roleId == SplitChannel.left.conventionalRoleId }
        let forRight = outputs.first { $0.roleId == SplitChannel.right.conventionalRoleId }

        XCTAssertEqual(forLeft?.id, dx.id)
        XCTAssertEqual(forRight?.id, mx.id)
    }
}
