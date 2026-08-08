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
final class LaneReorderTests: XCTestCase {

    /// The real thing: an 80pt lane, a 1pt divider, 0.18 of a row of stickiness.
    private let reorder = LaneReorder(rowHeight: 81, hysteresisRows: 0.18)

    func testNoDragKeepsTheLaneWhereItIs() {
        XCTAssertEqual(reorder.target(source: 2, held: nil, dragOffset: 0, laneCount: 5), 2)
    }

    /// Short of halfway is not a move - that was the old fixed 20pt trigger.
    func testShortOfHalfwayDoesNotMove() {
        XCTAssertEqual(reorder.target(source: 2, held: nil, dragOffset: 30, laneCount: 5), 2)
        XCTAssertEqual(reorder.target(source: 2, held: nil, dragOffset: -30, laneCount: 5), 2)
    }

    /// Past halfway plus the sticky margin, it commits - down and up alike.
    func testPastHalfwayMovesOneLane() {
        XCTAssertEqual(reorder.target(source: 2, held: nil, dragOffset: 57, laneCount: 5), 3)
        XCTAssertEqual(reorder.target(source: 2, held: nil, dragOffset: -57, laneCount: 5), 1)
    }

    /// Every step costs the same, which the fixed-threshold version did not: its
    /// first swap took 20pt and every later one a full row.
    func testStepsAreEvenlySpaced() {
        XCTAssertEqual(reorder.target(source: 0, held: nil, dragOffset: 81, laneCount: 6), 1)
        XCTAssertEqual(reorder.target(source: 0, held: nil, dragOffset: 162, laneCount: 6), 2)
        XCTAssertEqual(reorder.target(source: 0, held: nil, dragOffset: 243, laneCount: 6), 3)
    }

    /// The jumpiness itself: a hand holding a lane on the boundary must not flip
    /// the target back and forth, because every flip re-animates the other lanes.
    func testSittingOnTheBoundaryDoesNotFlipTheTarget() {
        let boundary: CGFloat = 81 * 0.5

        // Not yet committed: hovering either side of halfway holds at the source.
        XCTAssertEqual(reorder.target(source: 1, held: 1, dragOffset: boundary - 1, laneCount: 4), 1)
        XCTAssertEqual(reorder.target(source: 1, held: 1, dragOffset: boundary + 1, laneCount: 4), 1)

        // Committed to the next lane, then jittering back across halfway: it stays.
        XCTAssertEqual(reorder.target(source: 1, held: 2, dragOffset: boundary + 1, laneCount: 4), 2)
        XCTAssertEqual(reorder.target(source: 1, held: 2, dragOffset: boundary - 1, laneCount: 4), 2)
    }

    /// Dragged clear of the boundary in the other direction, it does change back.
    func testDraggingClearOfTheBoundaryChangesBack() {
        XCTAssertEqual(reorder.target(source: 1, held: 2, dragOffset: 20, laneCount: 4), 1)
    }

    func testTargetIsClampedToTheLanesThatExist() {
        XCTAssertEqual(reorder.target(source: 3, held: nil, dragOffset: 900, laneCount: 4), 3)
        XCTAssertEqual(reorder.target(source: 0, held: nil, dragOffset: -900, laneCount: 4), 0)
    }

    func testDegenerateInputsAreLeftAlone() {
        let zeroHeight = LaneReorder(rowHeight: 0, hysteresisRows: 0.18)
        XCTAssertEqual(zeroHeight.target(source: 2, held: nil, dragOffset: 500, laneCount: 5), 2)
        XCTAssertEqual(reorder.target(source: 0, held: nil, dragOffset: 500, laneCount: 0), 0)
    }
}
