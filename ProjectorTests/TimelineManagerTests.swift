//
//  TimelineManagerTests.swift
//  ProjectorTests
//
//  Tests for TimelineManager - Timeline state management and persistence
//

import XCTest
@testable import Projector
import SwiftTimecodeCore

@MainActor
final class TimelineManagerTests: XCTestCase {

    var manager: TimelineManager!

    override func setUp() async throws {
        try await super.setUp()

        let startTC = Timecode(.components(h: 0, m: 0, s: 0, f: 0), at: .fps24, by: .clamping)
        let endTC = Timecode(.components(h: 0, m: 6, s: 56, f: 16), at: .fps24, by: .clamping) // 10000 frames at 24fps
        let config = TimelineConfig(
            startTimecode: startTC,
            endTimecode: endTC,
            frameRate: .fps24
        )
        let timeline = Timeline(config: config, videoReels: [], audioLanes: [])
        manager = TimelineManager(timeline: timeline)
    }

    override func tearDown() async throws {
        manager = nil
        try await super.tearDown()
    }

    // MARK: - Initialization Tests

    func testInitialization() throws {
        // Then: Manager initializes with correct config
        XCTAssertNotNil(manager, "Manager should initialize")
        XCTAssertEqual(manager.timeline.config.frameRate, .fps24, "Frame rate should be 24fps")
        XCTAssertEqual(manager.timeline.config.durationFrames, 10000, "Duration should be 10000 frames")
    }

    // MARK: - Audio Lane CRUD Tests

    func testCreateAudioLane() {
        // When: Create audio lane
        let lane = manager.addAudioLane(name: "Dialog")

        // Then: Lane created
        XCTAssertEqual(manager.timeline.audioLanes.count, 1, "Should have 1 audio lane")
        XCTAssertEqual(lane.name, "Dialog", "Lane name should be 'Dialog'")
    }

    func testRemoveAudioLane() {
        // Given: Timeline with audio lane
        let lane = manager.addAudioLane(name: "Music")

        // When: Remove lane
        manager.removeAudioLane(id: lane.id)

        // Then: Lane removed
        XCTAssertEqual(manager.timeline.audioLanes.count, 0, "Should have no lanes")
    }

    func testRenameAudioLane() {
        // Given: Audio lane
        let lane = manager.addAudioLane(name: "Old Name")

        // When: Rename lane
        manager.renameAudioLane(id: lane.id, name: "New Name")

        // Then: Lane renamed
        XCTAssertEqual(manager.timeline.audioLanes[0].name, "New Name", "Lane should be renamed")
    }

    func testSetLaneVolume() {
        // Given: Audio lane
        let lane = manager.addAudioLane(name: "SFX")

        // When: Set volume to 75%
        manager.setLaneVolume(id: lane.id, volume: 0.75)

        // Then: Volume updated
        XCTAssertEqual(manager.timeline.audioLanes[0].volume, 0.75, accuracy: 0.01, "Volume should be 75%")
    }

    // MARK: - Audio Routing Tests

    /// The mapping's channel must reach the lane unchanged.
    ///
    /// `channelStart`, `outputChannelOffset` and the engine's `outputOffset` are
    /// all 0-based; only the UI adds 1 to print hardware numbers. A conversion
    /// here once sent "Out 3-4" to hardware 3 and 4's neighbours, which is
    /// inaudible in a code review and obvious in a studio.
    func testLaneOutputMappingKeepsTheMappedChannel() {
        let lane = manager.addAudioLane(name: "MX")
        // "Out 3-4" as the chooser stores it: 0-based start of 2.
        let mx = MappedAudioOutput(name: "MX", channelStart: 2, channelCount: 2, roleId: "mx")

        manager.setLaneOutputMapping(id: lane.id, mapping: mx)

        let updated = manager.timeline.audioLanes[0]
        XCTAssertEqual(updated.outputChannelOffset, 2, "Lane should play out of channels 3-4, not 2-3")
        XCTAssertEqual(updated.outputChannelCount, 2, "Stereo pair should stay a stereo pair")
        XCTAssertEqual(updated.outputMappingId, mx.id, "Lane should record which mapping it follows")
    }

    /// The first pair is the case the old off-by-one clamped into looking right,
    /// so it is worth pinning separately.
    func testLaneOutputMappingOnFirstPair() {
        let lane = manager.addAudioLane(name: "DX/SFX")
        let dxSfx = MappedAudioOutput(name: "DX/SFX", channelStart: 0, channelCount: 2, roleId: "dx-sfx")

        manager.setLaneOutputMapping(id: lane.id, mapping: dxSfx)

        XCTAssertEqual(manager.timeline.audioLanes[0].outputChannelOffset, 0, "Out 1-2 starts at index 0")
    }

    /// Rule 3 of the routing authority: a device swap replaces every mapping's
    /// identity, and a lane sent to channels 3-4 still means channels 3-4.
    func testLanesRebindByChannelWhenMappingIdentitiesChange() {
        let lane = manager.addAudioLane(name: "MX")
        let before = MappedAudioOutput(name: "MX", channelStart: 2, channelCount: 2, roleId: "mx")
        manager.setLaneOutputMapping(id: lane.id, mapping: before)

        // Same channels, new identity - what applying a profile produces.
        let after = MappedAudioOutput(name: "Music", channelStart: 2, channelCount: 2, roleId: "mx")
        manager.reconcileOutputMappings(with: [after])

        let updated = manager.timeline.audioLanes[0]
        XCTAssertEqual(updated.outputMappingId, after.id, "Lane should adopt the new mapping for its channels")
        XCTAssertEqual(updated.outputChannelOffset, 2, "Re-binding should not shift the channel")
    }

    /// Rule 4: an unresolvable mapping is cleared rather than left routing
    /// audio somewhere nobody chose.
    func testLaneMappingClearsWhenNoOutputMatchesItsChannels() {
        let lane = manager.addAudioLane(name: "MX")
        manager.setLaneOutputMapping(
            id: lane.id,
            mapping: MappedAudioOutput(name: "MX", channelStart: 6, channelCount: 2, roleId: "mx")
        )

        // A smaller interface: nothing reaches channels 7-8.
        manager.reconcileOutputMappings(with: [
            MappedAudioOutput(name: "DX/SFX", channelStart: 0, channelCount: 2, roleId: "dx-sfx")
        ])

        XCTAssertNil(manager.timeline.audioLanes[0].outputMappingId, "Unmatched lane should clear its mapping")
    }

    /// The delivery convention this feature was built for, as it arrives on disk.
    ///
    /// A preview delivery is a run of reels, each a picture file plus Dx/Fx/Mx
    /// stems. The names carry the risks, so the fixtures reproduce their shape
    /// exactly - mixed case (`_Dx`, not `_DX`), an eight-digit date that must
    /// not read as a word, a space before a suffix, and a picture file whose
    /// name says "Splt Audio" and must match no role at all.
    ///
    /// The show name is a placeholder on purpose: fixtures never carry a real
    /// title or a real delivery filename.
    func testDeliveryNamesMatchTheirRoles() {
        let expected: [(name: String, role: OutputRole?)] = [
            ("SHOW_PREV1_R1_COMPOSER_20260701_Dx.wav", .dialogueEffects),
            ("SHOW_PREV1_R1_COMPOSER_20260701_Fx.wav", .dialogueEffects),
            ("SHOW_PREV1_R1_COMPOSER_20260701_Mx.wav", .music),
            ("SHOW_PREV1_R1_COMPOSER_20260701 Splt Audio.mov", nil),
            ("SHOW_PREV1_R5_COMPOSER_20260701_Dx.wav", .dialogueEffects),
            ("SHOW_PREV1_R5_COMPOSER_20260701_Mx.wav", .music)
        ]

        for (name, role) in expected {
            XCTAssertEqual(OutputRole.named(in: name), role, "Wrong role for \(name)")
        }
    }

    /// Routing a stem and the picture's own audio to different outputs, which is
    /// the shape of a reel delivery: stems to their buses, guide track elsewhere.
    func testStemAndVideoAudioLanesRouteIndependently() {
        let mx = MappedAudioOutput(name: "MX", channelStart: 2, channelCount: 2, roleId: "mx")
        let dxSfx = MappedAudioOutput(name: "DX/SFX", channelStart: 0, channelCount: 2, roleId: "dx-sfx")

        let musicLane = manager.addAudioLane(name: "SHOW_PREV1_R1_COMPOSER_20260701_Mx")
        let guideLane = manager.addAudioLane(name: "SHOW_PREV1_R1_COMPOSER_20260701 Splt Audio")

        manager.setLaneOutputMapping(id: musicLane.id, mapping: mx)
        manager.setLaneOutputMapping(id: guideLane.id, mapping: dxSfx)

        let music = manager.timeline.audioLanes.first { $0.id == musicLane.id }
        let guide = manager.timeline.audioLanes.first { $0.id == guideLane.id }
        XCTAssertEqual(music?.outputChannelOffset, 2, "MX stem should play out of 3-4")
        XCTAssertEqual(guide?.outputChannelOffset, 0, "Video's audio should play out of 1-2")
    }

    // MARK: - No Output ("None")

    /// None silences the lane: nothing on it is offered for playback.
    func testLaneRoutedToNoneIsSilent() {
        let lane = manager.addAudioLane(name: "MX")
        manager.timeline.addClip(Self.makeClip(startFrame: 0), toLane: lane.id)
        XCTAssertEqual(manager.timeline.activeAudioClips(at: 10).count, 1, "Sanity: audible first")

        manager.disableLaneOutput(id: lane.id)

        XCTAssertTrue(manager.timeline.audioLanes[0].isOutputDisabled)
        XCTAssertEqual(
            manager.timeline.activeAudioClips(at: 10).count, 0,
            "A lane routed to None should produce nothing to play"
        )
    }

    /// None is a routing state, not a transport state - it leaves M alone.
    func testNoneDoesNotTouchMuteOrClips() {
        let lane = manager.addAudioLane(name: "MX")
        manager.timeline.addClip(Self.makeClip(startFrame: 0), toLane: lane.id)

        manager.disableLaneOutput(id: lane.id)

        let updated = manager.timeline.audioLanes[0]
        XCTAssertFalse(updated.isMuted, "None should not press the mute button for the user")
        XCTAssertEqual(updated.clips.count, 1, "None should not disturb the lane's clips")
    }

    /// Choosing a real output again restores the lane.
    func testChoosingAnOutputUndoesNone() {
        let lane = manager.addAudioLane(name: "MX")
        manager.timeline.addClip(Self.makeClip(startFrame: 0), toLane: lane.id)
        manager.disableLaneOutput(id: lane.id)

        let mx = MappedAudioOutput(name: "MX", channelStart: 2, channelCount: 2, roleId: "mx")
        manager.setLaneOutputMapping(id: lane.id, mapping: mx)

        XCTAssertFalse(manager.timeline.audioLanes[0].isOutputDisabled)
        XCTAssertEqual(manager.timeline.activeAudioClips(at: 10).count, 1, "Lane should be audible again")
    }

    /// Rule 5: reconciling outputs must not quietly un-silence a None lane.
    ///
    /// The lane keeps the channel numbers it had, so channel matching would
    /// otherwise adopt whatever output now sits on them.
    func testReconcileLeavesNoneAlone() {
        let lane = manager.addAudioLane(name: "MX")
        manager.setLaneOutputMapping(
            id: lane.id,
            mapping: MappedAudioOutput(name: "MX", channelStart: 2, channelCount: 2, roleId: "mx")
        )
        manager.disableLaneOutput(id: lane.id)

        manager.reconcileOutputMappings(with: [
            MappedAudioOutput(name: "Music", channelStart: 2, channelCount: 2, roleId: "mx")
        ])

        XCTAssertTrue(manager.timeline.audioLanes[0].isOutputDisabled, "None should survive a device change")
        XCTAssertNil(manager.timeline.audioLanes[0].outputMappingId)
    }

    /// None must survive save and reload.
    func testNoneSurvivesEncodingRoundTrip() throws {
        var lane = AudioLane(name: "MX")
        lane.isOutputDisabled = true

        let data = try JSONEncoder().encode(lane)
        let decoded = try JSONDecoder().decode(AudioLane.self, from: data)

        XCTAssertTrue(decoded.isOutputDisabled)
    }

    /// Projects saved before None existed must still decode, and stay audible.
    func testLanesSavedBeforeNoneDecodeAsRouted() throws {
        let legacy = """
        {"id":"\(UUID().uuidString)","name":"MX","clips":[],"isMuted":false,
         "isSolo":false,"volume":1,"colorIndex":0}
        """
        let decoded = try JSONDecoder().decode(AudioLane.self, from: Data(legacy.utf8))

        XCTAssertFalse(decoded.isOutputDisabled, "An absent flag means routed, not silent")
    }

    // MARK: - Set Timeline Start to Region

    /// The region's timecode becomes the timeline's, and the region lands on 0.
    func testSetTimelineStartToRegionMovesStartAndKeepsDuration() {
        let originalDuration = manager.timeline.config.durationFrames
        let lane = manager.addAudioLane(name: "MX")
        var clip = Self.makeClip(startFrame: 240)
        manager.timeline.addClip(clip, toLane: lane.id)

        manager.setTimelineStart(toFrame: 240)

        XCTAssertEqual(
            manager.timeline.config.startTimecode.frameCount.wholeFrames, 240,
            "Timeline should now start at the region's timecode"
        )
        XCTAssertEqual(
            manager.timeline.config.durationFrames, originalDuration,
            "Moving the start should carry the end with it, not shorten the timeline"
        )

        clip = manager.timeline.audioLanes[0].clips[0]
        XCTAssertEqual(clip.timelineStartFrame, 0, "The region should now sit at the start")
    }

    /// Content keeps its absolute timecode: everything shifts by the same amount.
    func testSetTimelineStartToRegionShiftsOtherContentEqually() {
        let lane = manager.addAudioLane(name: "Stems")
        manager.timeline.addClip(Self.makeClip(startFrame: 240), toLane: lane.id)
        manager.timeline.addClip(Self.makeClip(startFrame: 600), toLane: lane.id)

        manager.setTimelineStart(toFrame: 240)

        let starts = manager.timeline.audioLanes[0].clips.map { $0.timelineStartFrame }.sorted()
        XCTAssertEqual(starts, [0, 360], "The later region should keep its 360-frame separation")
    }

    /// A region already at the start has nothing to move.
    func testSetTimelineStartToRegionAtZeroDoesNothing() {
        let before = manager.timeline.config.startTimecode.frameCount.wholeFrames

        manager.setTimelineStart(toFrame: 0)

        XCTAssertEqual(manager.timeline.config.startTimecode.frameCount.wholeFrames, before)
    }

    // MARK: - Earliest Content (timeline start snaps to it on import)

    /// Nothing on the timeline is distinct from content sitting at frame 0 - the
    /// import snap has to leave an empty timeline's start alone.
    func testEarliestContentFrameIsNilWhenEmpty() {
        XCTAssertNil(manager.timeline.earliestContentFrame)
    }

    func testEarliestContentFrameTakesTheFirstReel() {
        manager.timeline.videoReels = [
            Self.makeReel(startFrame: 600),
            Self.makeReel(startFrame: 48)
        ]

        XCTAssertEqual(manager.timeline.earliestContentFrame, 48)
    }

    /// A stem can precede the picture, so audio counts as content too.
    func testEarliestContentFrameCountsAudioAgainstVideo() {
        manager.timeline.videoReels = [Self.makeReel(startFrame: 240)]
        let lane = manager.addAudioLane(name: "DX")
        manager.timeline.addClip(Self.makeClip(startFrame: 96), toLane: lane.id)

        XCTAssertEqual(
            manager.timeline.earliestContentFrame, 96,
            "The earliest thing on the timeline is the stem, not the reel"
        )
    }

    /// The whole point: a reel delivered two seconds into the default timeline
    /// ends up at its head, with its absolute timecode intact.
    func testSnappingTheStartToTheFirstReelLeavesNoDeadHead() {
        let originalDuration = manager.timeline.config.durationFrames
        let startBefore = manager.timeline.config.startTimecode.frameCount.wholeFrames
        manager.timeline.videoReels = [Self.makeReel(startFrame: 48)]

        guard let earliest = manager.timeline.earliestContentFrame else {
            return XCTFail("Expected content")
        }
        manager.setTimelineStart(toFrame: earliest)

        XCTAssertEqual(
            manager.timeline.videoReels[0].timelineStartFrame, 0,
            "The reel should now sit at the head of the timeline"
        )
        XCTAssertEqual(
            manager.timeline.config.startTimecode.frameCount.wholeFrames, startBefore + 48,
            "The start should have moved to the reel's own timecode"
        )
        XCTAssertEqual(manager.timeline.config.durationFrames, originalDuration)
    }

    /// Idempotent, which is what makes it safe after every import.
    func testSnappingAgainAfterTheFirstSnapChangesNothing() {
        manager.timeline.videoReels = [Self.makeReel(startFrame: 48)]
        manager.setTimelineStart(toFrame: manager.timeline.earliestContentFrame ?? 0)
        let startAfterFirstSnap = manager.timeline.config.startTimecode.frameCount.wholeFrames

        // A later import lands further along and must not drag the project back.
        manager.timeline.videoReels.append(Self.makeReel(startFrame: 5_000))
        let earliest = manager.timeline.earliestContentFrame
        XCTAssertEqual(earliest, 0, "The head of the programme is still the head")
        manager.setTimelineStart(toFrame: earliest ?? 0)

        XCTAssertEqual(
            manager.timeline.config.startTimecode.frameCount.wholeFrames,
            startAfterFirstSnap
        )
        XCTAssertEqual(manager.timeline.videoReels[1].timelineStartFrame, 5_000)
    }

    private static func makeReel(startFrame: Int) -> VideoReel {
        VideoReel(
            sourceURL: URL(fileURLWithPath: "/tmp/reel.mov"),
            timelineStartFrame: startFrame,
            durationFrames: 1_440
        )
    }

    private static func makeClip(startFrame: Int) -> AudioClip {
        AudioClip(
            sourceURL: URL(fileURLWithPath: "/tmp/stem.wav"),
            timelineStartFrame: startFrame,
            durationFrames: 120,
            sourceStartFrame: 0,
            sourceType: .audioFile,
            channelCount: 2,
            sampleRate: 48000
        )
    }

    // MARK: - Timeline Configuration Tests

    func testUpdateFrameRate() {
        // When: Change frame rate to 30fps
        let startTC = Timecode(.components(h: 0, m: 0, s: 0, f: 0), at: .fps30, by: .clamping)
        let endTC = Timecode(.components(h: 0, m: 5, s: 33, f: 10), at: .fps30, by: .clamping) // ~10000 frames at 30fps
        let newConfig = TimelineConfig(
            startTimecode: startTC,
            endTimecode: endTC,
            frameRate: .fps30
        )
        manager.updateConfig(newConfig)

        // Then: Frame rate updated
        XCTAssertEqual(manager.timeline.config.frameRate, .fps30, "Frame rate should be 30fps")
    }

    func testPrimaryCallbackAndAdditionalObserverBothReceiveChanges() {
        var primaryCallbackCount = 0
        var observerCallbackCount = 0

        manager.onTimelineChanged = {
            primaryCallbackCount += 1
        }
        let observerID = manager.addTimelineChangeObserver {
            observerCallbackCount += 1
        }

        _ = manager.addAudioLane(name: "Dialog")

        XCTAssertEqual(primaryCallbackCount, 1)
        XCTAssertEqual(observerCallbackCount, 1)

        manager.removeTimelineChangeObserver(id: observerID)
        _ = manager.addAudioLane(name: "Music")

        XCTAssertEqual(primaryCallbackCount, 2)
        XCTAssertEqual(observerCallbackCount, 1)
    }

    // MARK: - Timeline Duration Calculation Tests

    func testCalculateTotalDuration() {
        // Given: Multiple audio lanes with clips would have different end points
        // For now just verify the config-based duration
        XCTAssertEqual(manager.timeline.config.durationFrames, 10000, "Duration should be 10000 frames")
    }
}
