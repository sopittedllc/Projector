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

    /// A file stamped before the start moves the start back to meet it, and the
    /// content already there moves later by the same amount. `placementFrame`
    /// relies on this to place a picture that precedes a stem imported first.
    func testSetTimelineStartToANegativeFrameMovesTheStartEarlier() {
        // The fixture starts at 00:00:00:00, where nothing can be earlier.
        var config = manager.timeline.config
        config.startTimecode = Timecode(.components(h: 1, m: 0, s: 0, f: 0), at: .fps24, by: .clamping)
        config.endTimecode = Timecode(.components(h: 2, m: 0, s: 0, f: 0), at: .fps24, by: .clamping)
        manager.timeline.config = config
        let originalStart = manager.timeline.config.startTimecode.frameCount.wholeFrames
        let originalDuration = manager.timeline.config.durationFrames
        let lane = manager.addAudioLane(name: "MX")
        manager.timeline.addClip(Self.makeClip(startFrame: 0), toLane: lane.id)

        manager.setTimelineStart(toFrame: -240)

        XCTAssertEqual(manager.timeline.config.startTimecode.frameCount.wholeFrames, originalStart - 240)
        XCTAssertEqual(manager.timeline.config.durationFrames, originalDuration)
        XCTAssertEqual(manager.timeline.audioLanes[0].clips[0].timelineStartFrame, 240)
    }

    /// Changing the frame rate re-expresses the same start timecode, and that
    /// changes its frame count. That is not the start moving. A stem sitting at
    /// frame 0 before the first reel set the rate must still be at frame 0 after
    /// - it was drawn under the track headers when this was read as a shift.
    func testChangingTheFrameRateDoesNotShiftContent() {
        var config = manager.timeline.config
        config.setFrameRate(.fps24)
        config.startTimecode = Timecode(.components(h: 1, m: 26, s: 2, f: 0), at: .fps24, by: .clamping)
        config.endTimecode = Timecode(.components(h: 2, m: 26, s: 2, f: 0), at: .fps24, by: .clamping)
        manager.timeline.config = config

        let lane = manager.addAudioLane(name: "MX")
        var clip = Self.makeClip(startFrame: 0)
        clip.durationFrames = 24 * 10 // ten seconds at 24
        manager.timeline.addClip(clip, toLane: lane.id)

        config.setFrameRate(.fps25)
        manager.updateConfig(config)

        let after = manager.timeline.audioLanes[0].clips[0]
        XCTAssertEqual(after.timelineStartFrame, 0, "Same timecode at a new rate is not a move")
        XCTAssertEqual(after.durationFrames, 25 * 10, "Ten seconds is ten seconds at the new rate")
        XCTAssertEqual(manager.timeline.config.startTimecode.stringValue(), "01:26:02:00")
    }

    /// Content keeps its real time across a rate change: a clip ten seconds in
    /// is at frame 240 at 24 fps and frame 250 at 25.
    func testChangingTheFrameRateRegridsPositions() {
        var config = manager.timeline.config
        config.setFrameRate(.fps24)
        manager.timeline.config = config
        let lane = manager.addAudioLane(name: "MX")
        manager.timeline.addClip(Self.makeClip(startFrame: 240), toLane: lane.id)

        manager.setFrameRate(.fps25)

        XCTAssertEqual(manager.timeline.audioLanes[0].clips[0].timelineStartFrame, 250)
    }

    /// 23.976 and 24 count the same 24 frames per second, so a switch between
    /// them is a relabelling, not a move. Scaling by the real ratio (the mistake
    /// `convertedFrames(to:)` already corrected for embedded timecode) would
    /// slide a clip at the two-hour mark by ~173 frames.
    func testSwitchingWithinAPulldownPairLeavesContentWhereItIs() {
        var config = manager.timeline.config
        config.setFrameRate(.fps24)
        manager.timeline.config = config
        let lane = manager.addAudioLane(name: "MX")
        let twoHours = 2 * 60 * 60 * 24
        manager.timeline.addClip(Self.makeClip(startFrame: twoHours), toLane: lane.id)

        manager.setFrameRate(.fps23_976)

        XCTAssertEqual(manager.timeline.audioLanes[0].clips[0].timelineStartFrame, twoHours)
        XCTAssertEqual(manager.timeline.audioLanes[0].clips[0].durationFrames, 120)
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

    // MARK: - Dragging a Clip Between Lanes

    /// A clip dragged onto another lane arrives there, and leaves the old one.
    ///
    /// Vertical dragging used to be gated on `sourceType == .videoTrack`, so
    /// this - an ordinary stem being moved off the lane it imported onto - did
    /// nothing at all.
    func testMovingAClipToAnotherLaneLeavesTheFirst() {
        let dx = manager.addAudioLane(name: "DX")
        let mx = manager.addAudioLane(name: "MX")
        let clip = Self.makeClip(startFrame: 100)
        manager.timeline.addClip(clip, toLane: dx.id)

        manager.moveAudioClipToLane(clipId: clip.id, fromLane: dx.id, toLane: mx.id)

        XCTAssertTrue(manager.timeline.audioLanes[0].clips.isEmpty, "Source lane should give it up")
        XCTAssertEqual(manager.timeline.audioLanes[1].clips.map(\.id), [clip.id])
    }

    /// A diagonal drag carries its horizontal half across with it.
    ///
    /// The lane change is one gesture with the timecode move, so committing the
    /// lane while discarding the frame would slide a stem out of sync with
    /// picture as the price of changing which lane it sits on.
    func testMovingToAnotherLaneKeepsTheDraggedFrame() {
        let dx = manager.addAudioLane(name: "DX")
        let mx = manager.addAudioLane(name: "MX")
        let clip = Self.makeClip(startFrame: 100)
        manager.timeline.addClip(clip, toLane: dx.id)

        manager.moveAudioClipToLane(clipId: clip.id, fromLane: dx.id, toLane: mx.id, at: 550)

        XCTAssertEqual(manager.timeline.audioLanes[1].clips.first?.timelineStartFrame, 550)
    }

    /// Without a frame the clip keeps the timecode it had.
    ///
    /// This is the video-linked path: those clips are pinned to their reel
    /// horizontally, so a lane change must not move them along the timeline.
    func testMovingToAnotherLaneWithoutAFrameKeepsTheOldPosition() {
        let dx = manager.addAudioLane(name: "DX")
        let mx = manager.addAudioLane(name: "MX")
        let clip = Self.makeClip(startFrame: 100)
        manager.timeline.addClip(clip, toLane: dx.id)

        manager.moveAudioClipToLane(clipId: clip.id, fromLane: dx.id, toLane: mx.id)

        XCTAssertEqual(manager.timeline.audioLanes[1].clips.first?.timelineStartFrame, 100)
    }

    /// Overlap is judged where the clip is going, not where it came from.
    ///
    /// `hasOverlap` is what the drag consults before committing, so a probe at
    /// the landing frame has to be the thing asked. Testing the old frame would
    /// refuse moves into free space and permit moves straight onto a clip.
    func testOverlapIsJudgedAtTheLandingFrame() {
        let mx = manager.addAudioLane(name: "MX")
        manager.timeline.addClip(Self.makeClip(startFrame: 500), toLane: mx.id)

        var probe = Self.makeClip(startFrame: 100)
        let target = manager.timeline.audioLanes[0]
        XCTAssertFalse(target.hasOverlap(with: probe), "Clear at its old frame")

        // 120 frames long, so 550 lands inside the 500..620 clip already there.
        probe.timelineStartFrame = 550
        XCTAssertTrue(target.hasOverlap(with: probe), "Occupied at the frame it is dragged to")
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

// MARK: - QuickTime Demo

/// The span a review QuickTime covers, and the level conversion that goes with
/// it. Pure arithmetic, so it is pinned here rather than left to be discovered by
/// exporting a two-hour reel and watching where the picture starts.
final class QuickTimeDemoSpanTests: XCTestCase {

    private func spec(
        wavStartFrame: Int,
        wavDurationFrames: Int,
        head: Int = 0,
        tail: Int = 0
    ) -> QuickTimeDemoSpec {
        QuickTimeDemoSpec(
            wavURL: URL(fileURLWithPath: "/tmp/mix.wav"),
            wavStartFrame: wavStartFrame,
            wavDurationFrames: wavDurationFrames,
            headFrames: head,
            tailFrames: tail
        )
    }

    func testSpanWithNoHandlesIsExactlyTheMix() {
        let span = QuickTimeDemoSpan(spec: spec(wavStartFrame: 1_000, wavDurationFrames: 480))

        XCTAssertEqual(span.startFrame, 1_000)
        XCTAssertEqual(span.endFrame, 1_480)
        XCTAssertEqual(span.durationFrames, 480)
    }

    func testHandlesExtendBothEnds() {
        let span = QuickTimeDemoSpan(
            spec: spec(wavStartFrame: 1_000, wavDurationFrames: 480, head: 48, tail: 96)
        )

        XCTAssertEqual(span.startFrame, 952)
        XCTAssertEqual(span.endFrame, 1_576)
        XCTAssertEqual(span.durationFrames, 624)
    }

    /// There is no picture before the head of the timeline, and asking a
    /// composition for a negative time is a crash waiting to happen.
    func testHeadIsClampedAtTheStartOfTheTimeline() {
        let span = QuickTimeDemoSpan(
            spec: spec(wavStartFrame: 24, wavDurationFrames: 480, head: 240)
        )

        XCTAssertEqual(span.startFrame, 0, "Cannot print picture from before frame 0")
        XCTAssertEqual(span.endFrame, 504, "The tail end is unaffected by the clamp")
    }

    /// Deliberately unclamped: a mix may run past the last reel, and black
    /// picture with the audio continuing is the honest answer.
    func testTailIsNotClampedToTheTimeline() {
        let span = QuickTimeDemoSpan(
            spec: spec(wavStartFrame: 1_000, wavDurationFrames: 480, tail: 100_000)
        )

        XCTAssertEqual(span.endFrame, 101_480)
    }

    func testNegativeHandlesAreIgnoredRatherThanShorteningTheDemo() {
        let span = QuickTimeDemoSpan(
            spec: spec(wavStartFrame: 1_000, wavDurationFrames: 480, head: -240, tail: -240)
        )

        XCTAssertEqual(span.startFrame, 1_000)
        XCTAssertEqual(span.endFrame, 1_480)
    }

    func testOffsetIsMeasuredFromTheSpanStart() {
        let span = QuickTimeDemoSpan(
            spec: spec(wavStartFrame: 1_000, wavDurationFrames: 480, head: 48)
        )

        XCTAssertEqual(span.offset(ofTimelineFrame: 952), 0)
        XCTAssertEqual(span.offset(ofTimelineFrame: 1_000), 48, "The mix begins after the head")
    }

    @MainActor
    func testDecibelsConvertToLinearVolume() {
        XCTAssertEqual(QuickTimeDemoBuilder.linearVolume(fromDB: 0), 1.0, accuracy: 0.0001)
        XCTAssertEqual(QuickTimeDemoBuilder.linearVolume(fromDB: -6), 0.5012, accuracy: 0.001)
        XCTAssertEqual(QuickTimeDemoBuilder.linearVolume(fromDB: -20), 0.1, accuracy: 0.0001)
        XCTAssertGreaterThan(QuickTimeDemoBuilder.linearVolume(fromDB: 6), 1.0)
    }
}

// MARK: - Undo

/// Every timeline undo in the app restores a snapshot rather than reversing the
/// individual edit, so what matters is that a snapshot is a faithful inverse -
/// including the config, which an import changes when it snaps the start.
final class TimelineSnapshotUndoTests: XCTestCase {

    @MainActor
    private func makeManager() -> TimelineManager {
        let rate = TimecodeFrameRate.fps24
        let config = TimelineConfig(
            startTimecode: Timecode(.components(h: 0, m: 59, s: 50, f: 0), at: rate, by: .clamping),
            endTimecode: Timecode(.components(h: 2, m: 59, s: 50, f: 0), at: rate, by: .clamping),
            frameRate: rate
        )
        return TimelineManager(timeline: Timeline(config: config, videoReels: [], audioLanes: []))
    }

    /// The shape of an import: a reel, a lane, a clip, and a moved start.
    @MainActor
    func testRestoringASnapshotReversesAWholeImport() {
        let manager = makeManager()
        let before = manager.timeline

        let lane = manager.addAudioLane(name: "MX")
        manager.timeline.addClip(
            AudioClip(
                sourceURL: URL(fileURLWithPath: "/tmp/stem.wav"),
                timelineStartFrame: 48,
                durationFrames: 240,
                sourceStartFrame: 0,
                sourceType: .audioFile,
                channelCount: 2,
                sampleRate: 48_000
            ),
            toLane: lane.id
        )
        manager.timeline.videoReels = [
            VideoReel(
                sourceURL: URL(fileURLWithPath: "/tmp/reel.mov"),
                timelineStartFrame: 48,
                durationFrames: 1_440
            )
        ]
        manager.setTimelineStart(toFrame: 48)

        XCTAssertNotEqual(manager.timeline, before, "The import should have changed something")

        // What undo does.
        manager.timeline = before

        XCTAssertEqual(manager.timeline, before)
        XCTAssertTrue(manager.timeline.videoReels.isEmpty, "The reel should be gone")
        XCTAssertTrue(manager.timeline.audioLanes.isEmpty, "The lane the import made should be gone")
        XCTAssertEqual(
            manager.timeline.config.startTimecode.frameCount.wholeFrames,
            before.config.startTimecode.frameCount.wholeFrames,
            "The start the import snapped should be back where it was"
        )
    }

    /// A drop that places nothing must not register a step - `Cmd-Z` consuming a
    /// press to restore an identical timeline reads as broken undo.
    @MainActor
    func testATimelineThatDidNotChangeIsRecognisedAsUnchanged() {
        let manager = makeManager()
        let before = manager.timeline

        XCTAssertEqual(manager.timeline, before, "Nothing placed means nothing to undo")
    }
}

// MARK: - Lane Reorder

/// The reorder rule, which has been wrong twice and cannot be judged by eye: the
/// failures are a few points wide and the only symptom a person can report is
/// "it feels jumpy".
///
/// `LaneReorder` used to take a single `rowHeight` because every row was the
/// same height. Since a standalone lane always carries an 18pt "add
/// automation" strip or a 48pt sub-lane along its bottom edge, rows differ in
/// height, so the rule now works from each row's actual frame (`LaneRowMetric`)
/// rather than a shared constant.
final class LaneReorderTests: XCTestCase {

    /// `count` rows, each `height` points tall with a 1pt divider under every
    /// row but the last - matches `TrackGeometry`'s own convention exactly, so
    /// a test built from this reproduces what the real layout produces.
    private func uniformRows(count: Int, height: CGFloat = 80, divider: CGFloat = 1) -> [LaneRowMetric] {
        rows(heights: Array(repeating: height, count: count), divider: divider)
    }

    /// Rows of the given heights, in order, with a 1pt divider under every row
    /// but the last.
    private func rows(heights: [CGFloat], divider: CGFloat = 1) -> [LaneRowMetric] {
        var result: [LaneRowMetric] = []
        var top: CGFloat = 0
        for (index, height) in heights.enumerated() {
            let isLast = index == heights.count - 1
            let pitch = height + (isLast ? 0 : divider)
            result.append(LaneRowMetric(id: UUID(), top: top, height: height, pitch: pitch))
            top += pitch
        }
        return result
    }

    /// Five equal 80pt rows (81pt pitch, bar the last) - the uniform case the
    /// old single `rowHeight` covered, kept as the baseline for most tests.
    private lazy var reorder = LaneReorder(rows: uniformRows(count: 5), separator: 1, hysteresis: TimelineLayout.laneReorderHysteresis)

    func testNoDragKeepsTheLaneWhereItIs() {
        XCTAssertEqual(reorder.target(sourceOrdinal: 2, heldOrdinal: nil, dragOffset: 0), 2)
    }

    /// Short of halfway is not a move - that was the old fixed 20pt trigger.
    func testShortOfHalfwayDoesNotMove() {
        XCTAssertEqual(reorder.target(sourceOrdinal: 2, heldOrdinal: nil, dragOffset: 30), 2)
        XCTAssertEqual(reorder.target(sourceOrdinal: 2, heldOrdinal: nil, dragOffset: -30), 2)
    }

    /// Past halfway plus the sticky margin, it commits - down and up alike.
    func testPastHalfwayMovesOneLane() {
        XCTAssertEqual(reorder.target(sourceOrdinal: 2, heldOrdinal: nil, dragOffset: 57), 3)
        XCTAssertEqual(reorder.target(sourceOrdinal: 2, heldOrdinal: nil, dragOffset: -57), 1)
    }

    /// Every step costs the same, which the fixed-threshold version did not: its
    /// first swap took 20pt and every later one a full row. Also a multi-row
    /// jump: a single, large drag lands several rows away in one call, not one
    /// row at a time.
    func testStepsAreEvenlySpaced() {
        let six = LaneReorder(rows: uniformRows(count: 6), separator: 1, hysteresis: TimelineLayout.laneReorderHysteresis)
        XCTAssertEqual(six.target(sourceOrdinal: 0, heldOrdinal: nil, dragOffset: 81), 1)
        XCTAssertEqual(six.target(sourceOrdinal: 0, heldOrdinal: nil, dragOffset: 162), 2)
        XCTAssertEqual(six.target(sourceOrdinal: 0, heldOrdinal: nil, dragOffset: 243), 3)
    }

    /// The jumpiness itself: a hand holding a lane on the boundary must not flip
    /// the target back and forth, because every flip re-animates the other lanes.
    func testSittingOnTheBoundaryDoesNotFlipTheTarget() {
        let four = LaneReorder(rows: uniformRows(count: 4), separator: 1, hysteresis: TimelineLayout.laneReorderHysteresis)
        let boundary: CGFloat = 81 * 0.5

        // Not yet committed: hovering either side of halfway holds at the source.
        XCTAssertEqual(four.target(sourceOrdinal: 1, heldOrdinal: 1, dragOffset: boundary - 1), 1)
        XCTAssertEqual(four.target(sourceOrdinal: 1, heldOrdinal: 1, dragOffset: boundary + 1), 1)

        // Committed to the next lane, then jittering back across halfway: it stays -
        // this is the reversal case: the held ordinal keeps until the *opposite*
        // threshold is crossed, not the one that produced it.
        XCTAssertEqual(four.target(sourceOrdinal: 1, heldOrdinal: 2, dragOffset: boundary + 1), 2)
        XCTAssertEqual(four.target(sourceOrdinal: 1, heldOrdinal: 2, dragOffset: boundary - 1), 2)
    }

    /// Dragged clear of the boundary in the other direction, it does change back.
    func testDraggingClearOfTheBoundaryChangesBack() {
        let four = LaneReorder(rows: uniformRows(count: 4), separator: 1, hysteresis: TimelineLayout.laneReorderHysteresis)
        XCTAssertEqual(four.target(sourceOrdinal: 1, heldOrdinal: 2, dragOffset: 20), 1)
    }

    func testTargetIsClampedToTheLanesThatExist() {
        let four = LaneReorder(rows: uniformRows(count: 4), separator: 1, hysteresis: TimelineLayout.laneReorderHysteresis)
        XCTAssertEqual(four.target(sourceOrdinal: 3, heldOrdinal: nil, dragOffset: 900), 3)
        XCTAssertEqual(four.target(sourceOrdinal: 0, heldOrdinal: nil, dragOffset: -900), 0)
    }

    func testDegenerateInputsAreLeftAlone() {
        let empty = LaneReorder(rows: [], separator: 1, hysteresis: TimelineLayout.laneReorderHysteresis)
        XCTAssertEqual(empty.target(sourceOrdinal: 2, heldOrdinal: nil, dragOffset: 500), 0)

        // A source ordinal outside the frozen rows - nothing to reason from,
        // so the safe answer is the top, not a guess.
        XCTAssertEqual(reorder.target(sourceOrdinal: 99, heldOrdinal: nil, dragOffset: 500), 0)
    }

    // MARK: - Mixed heights

    /// Rows `[80, 128, 80, 80]` - one automation sub-lane much taller than its
    /// neighbours, as `TrackGeometry` produces once a lane's envelope is
    /// shown. Pitches are `[81, 129, 81, 80]`: every row but the last carries
    /// the 1pt divider, and the last row's pitch equals its own height.
    private var mixedRows: [LaneRowMetric] { rows(heights: [80, 128, 80, 80]) }
    private var mixedReorder: LaneReorder {
        LaneReorder(rows: mixedRows, separator: 1, hysteresis: TimelineLayout.laneReorderHysteresis)
    }

    func testMixedHeightRowsHaveThePitchesTheyShould() {
        XCTAssertEqual(mixedRows.map(\.pitch), [81, 129, 81, 80])
        XCTAssertEqual(mixedRows.map(\.top), [0, 81, 210, 291])
        XCTAssertEqual(mixedRows.last?.pitch, mixedRows.last?.height, "the last row has no divider to add")
    }

    /// Dragging the short first row down commits past the tall row only once
    /// its bottom edge clears the tall row's centre by the hysteresis - not
    /// simply "half of 80" or "half of 128", which is why this is asserted
    /// against the mixed table rather than the uniform one.
    func testMixedHeightRowsCommitAtTheTallRowsOwnCentre() {
        // Tall row (ordinal 1) starts at 81 and is 128pt tall, so its centre
        // is 145 and the dragged row's bottom edge (starting at 80) must
        // exceed 159 (145 + the 14pt hysteresis).
        XCTAssertEqual(mixedReorder.target(sourceOrdinal: 0, heldOrdinal: nil, dragOffset: 78), 0)
        XCTAssertEqual(mixedReorder.target(sourceOrdinal: 0, heldOrdinal: nil, dragOffset: 80), 1)
    }

    /// A single large drag jumps two rows in one call, skipping the
    /// intermediate ordinal entirely - `LaneReorder` never requires a caller
    /// to visit every row in between.
    func testMixedHeightRowsSupportAMultiRowJump() {
        XCTAssertEqual(mixedReorder.target(sourceOrdinal: 0, heldOrdinal: nil, dragOffset: 185), 2)
    }

    /// Only the rows strictly between source and target move, and they move by
    /// the *dragged* row's own pitch - not the height of whatever row they
    /// happen to be - since that pitch is exactly the space the dragged row
    /// vacates or demands.
    func testDisplacementUsesTheDraggedRowsOwnPitch() {
        XCTAssertEqual(mixedReorder.displacement(forOrdinal: 1, sourceOrdinal: 0, targetOrdinal: 2), -81)
        XCTAssertEqual(mixedReorder.displacement(forOrdinal: 2, sourceOrdinal: 0, targetOrdinal: 2), -81)
        XCTAssertEqual(mixedReorder.displacement(forOrdinal: 3, sourceOrdinal: 0, targetOrdinal: 2), 0)
        XCTAssertEqual(mixedReorder.displacement(forOrdinal: 0, sourceOrdinal: 0, targetOrdinal: 2), 0, "the dragged row is not displaced by this formula - it follows the drag directly")
    }

    // MARK: - Last row

    /// The last row (ordinal 3) has no divider under it, so its pitch equals
    /// its height (80, not 81) - dragging it should still commit at the same
    /// edge-crossing rule as any other row.
    func testDraggingTheLastRowUpPastAShorterNeighbourCommits() {
        XCTAssertEqual(mixedReorder.target(sourceOrdinal: 3, heldOrdinal: nil, dragOffset: -54), 3)
        XCTAssertEqual(mixedReorder.target(sourceOrdinal: 3, heldOrdinal: nil, dragOffset: -56), 2)
    }

    /// When the last row is dragged upward, the rows it passes move down by
    /// its height *plus a divider*: once it is no longer last it gains the
    /// divider under it, and the row that becomes last loses one - so the
    /// space that changes hands is a full row-with-divider, not the last
    /// row's divider-less pitch. Using the pitch put previews 1pt short.
    func testDisplacementWhenTheLastRowIsDragged() {
        XCTAssertEqual(mixedReorder.displacement(forOrdinal: 2, sourceOrdinal: 3, targetOrdinal: 2), 81)
        XCTAssertEqual(mixedReorder.displacement(forOrdinal: 1, sourceOrdinal: 3, targetOrdinal: 2), 0)
        XCTAssertEqual(mixedReorder.displacement(forOrdinal: 0, sourceOrdinal: 3, targetOrdinal: 2), 0)
    }

    /// The preview must land rows exactly where the committed order will put
    /// them: for first↔last swaps, every displaced row's previewed top equals
    /// its top in the recomputed final geometry.
    func testDisplacedPreviewMatchesRecomputedFinalGeometryForFirstLastSwaps() {
        let heights: [CGFloat] = [80, 128, 80, 80]
        func tops(for order: [Int]) -> [Int: CGFloat] {
            // Rows laid out in `order`, divider after every row but the last.
            var y: CGFloat = 0
            var result: [Int: CGFloat] = [:]
            for (position, original) in order.enumerated() {
                result[original] = y
                y += heights[original] + (position == order.count - 1 ? 0 : 1)
            }
            return result
        }

        // First row dragged to last: rows 1...3 all move up.
        let firstToLast = tops(for: [1, 2, 3, 0])
        for ordinal in 1...3 {
            let previewed = mixedRows[ordinal].top + mixedReorder.displacement(forOrdinal: ordinal, sourceOrdinal: 0, targetOrdinal: 3)
            XCTAssertEqual(previewed, firstToLast[ordinal], "row \(ordinal) first→last")
        }

        // Last row dragged to first: rows 0...2 all move down.
        let lastToFirst = tops(for: [3, 0, 1, 2])
        for ordinal in 0...2 {
            let previewed = mixedRows[ordinal].top + mixedReorder.displacement(forOrdinal: ordinal, sourceOrdinal: 3, targetOrdinal: 0)
            XCTAssertEqual(previewed, lastToFirst[ordinal], "row \(ordinal) last→first")
        }
    }
}

// MARK: - QuickTime Demo Defaults

/// The demo setup remembered between projects.
///
/// Pinned because the failure is silent: a setup that does not survive encoding
/// simply reverts to defaults next time, which reads as "the feature does
/// nothing" rather than as a bug, and only shows up on the second project.
final class QuickTimeDemoDefaultsTests: XCTestCase {

    private func roundTrip(_ defaults: QuickTimeDemoDefaults) throws -> QuickTimeDemoDefaults {
        let data = try JSONEncoder().encode(defaults)
        return try JSONDecoder().decode(QuickTimeDemoDefaults.self, from: data)
    }

    func testAnEmptySetupRoundTripsToTheSameDefaults() throws {
        XCTAssertEqual(try roundTrip(QuickTimeDemoDefaults()), QuickTimeDemoDefaults())
    }

    func testHandlesLevelsAndLanesAllSurviveEncoding() throws {
        var defaults = QuickTimeDemoDefaults()
        defaults.headSeconds = 8
        defaults.tailSeconds = 12
        defaults.mixGainDB = -3
        defaults.lanes["DX/SFX"] = .init(isIncluded: true, gainDB: -6)
        defaults.lanes["MX"] = .init(isIncluded: false, gainDB: 2.5)

        let decoded = try roundTrip(defaults)

        XCTAssertEqual(decoded.headSeconds, 8)
        XCTAssertEqual(decoded.tailSeconds, 12)
        XCTAssertEqual(decoded.mixGainDB, -3)
        XCTAssertEqual(decoded.lanes["DX/SFX"], .init(isIncluded: true, gainDB: -6))
        XCTAssertEqual(decoded.lanes["MX"], .init(isIncluded: false, gainDB: 2.5))
    }

    /// A lane never seen before has no remembered setting, and the caller is
    /// expected to fall back to excluded at unity rather than to invent one.
    func testAnUnknownLaneHasNoRememberedSetting() {
        var defaults = QuickTimeDemoDefaults()
        defaults.lanes["MX"] = .init(isIncluded: true, gainDB: -6)

        XCTAssertNil(defaults.lanes["Foley"])
    }

    /// Merging is why a project containing only music does not erase the
    /// dialogue setting made in the previous one.
    func testRememberingOneLaneLeavesTheOthersAlone() {
        var defaults = QuickTimeDemoDefaults()
        defaults.lanes["DX/SFX"] = .init(isIncluded: true, gainDB: -6)
        defaults.lanes["MX"] = .init(isIncluded: true, gainDB: 0)

        defaults.lanes["MX"] = .init(isIncluded: false, gainDB: -12)

        XCTAssertEqual(defaults.lanes["DX/SFX"], .init(isIncluded: true, gainDB: -6))
        XCTAssertEqual(defaults.lanes["MX"], .init(isIncluded: false, gainDB: -12))
    }

    /// Decoding must not throw on a payload written before a field existed -
    /// every stored setup predates whatever is added next.
    func testAPartialPayloadStillDecodes() throws {
        let json = Data(#"{"headSeconds":5}"#.utf8)
        let decoded = try JSONDecoder().decode(QuickTimeDemoDefaults.self, from: json)

        XCTAssertEqual(decoded.headSeconds, 5)
        XCTAssertEqual(decoded.tailSeconds, 0)
        XCTAssertEqual(decoded.mixGainDB, 0)
        XCTAssertTrue(decoded.lanes.isEmpty)
    }
}
