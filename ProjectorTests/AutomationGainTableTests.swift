//
//  AutomationGainTableTests.swift
//  ProjectorTests
//
//  Tests for AutomationGainTable - the precomputed base-gain and envelope
//  lookup that PlaybackEngine's per-frame hook reads instead of walking the
//  timeline (plan §3.2, docs/plans/VOLUME-AUTOMATION-PLAN.md).
//

import XCTest
@testable import Projector
import SwiftTimecodeCore

final class AutomationGainTableTests: XCTestCase {

    // MARK: - Fixtures

    private func makeClip(
        id: UUID = UUID(),
        start: Int = 0,
        duration: Int = 100,
        volume: Float = 1.0,
        isMuted: Bool = false
    ) -> AudioClip {
        AudioClip(
            id: id,
            sourceURL: URL(fileURLWithPath: "/tmp/AutomationGainTableTests-clip.wav"),
            timelineStartFrame: start,
            durationFrames: duration,
            volume: volume,
            isMuted: isMuted
        )
    }

    private func makeLane(
        id: UUID = UUID(),
        clips: [AudioClip] = [],
        isMuted: Bool = false,
        isSolo: Bool = false,
        volume: Float = 1.0,
        isOutputDisabled: Bool = false,
        ownerVideoReelId: UUID? = nil,
        splitChannel: SplitChannel? = nil,
        automation: VolumeAutomation? = nil
    ) -> AudioLane {
        AudioLane(
            id: id,
            name: "Lane",
            clips: clips,
            isMuted: isMuted,
            isSolo: isSolo,
            volume: volume,
            isOutputDisabled: isOutputDisabled,
            ownerVideoReelId: ownerVideoReelId,
            splitChannel: splitChannel,
            automation: automation
        )
    }

    private func dippingEnvelope() -> VolumeAutomation {
        var automation = VolumeAutomation()
        automation.insert(frame: 0, gainDB: 0)
        automation.insert(frame: 100, gainDB: -60)
        return automation
    }

    // MARK: - Unity lane

    func testUnityLaneIsNotAutomatedAndGainIsBase() {
        let clip = makeClip(volume: 0.5)
        let lane = makeLane(clips: [clip], volume: 0.8, automation: VolumeAutomation())

        let table = AutomationGainTable(timeline: Timeline(audioLanes: [lane]))

        XCTAssertFalse(table.hasAutomation, "An empty (unity) envelope must not count as automation")
        XCTAssertEqual(table.gain(forClip: clip.id, at: 0), 0.5 * 0.8)
        XCTAssertEqual(table.gain(forClip: clip.id, at: 50), 0.5 * 0.8)
    }

    func testNilAutomationIsNotAutomated() {
        let clip = makeClip()
        let lane = makeLane(clips: [clip], automation: nil)

        let table = AutomationGainTable(timeline: Timeline(audioLanes: [lane]))

        XCTAssertFalse(table.hasAutomation)
        XCTAssertEqual(table.gain(forClip: clip.id, at: 0), 1.0)
    }

    // MARK: - Automated standalone lane

    func testAutomatedStandaloneLaneGainIsBaseTimesLinearGain() {
        let clip = makeClip(duration: 200, volume: 0.5)
        let automation = dippingEnvelope()
        let lane = makeLane(clips: [clip], volume: 0.5, automation: automation)

        let table = AutomationGainTable(timeline: Timeline(audioLanes: [lane]))

        XCTAssertTrue(table.hasAutomation)

        let base: Float = 0.5 * 0.5
        for frame in [0, 25, 50, 75, 100, 150] {
            let expected = base * automation.linearGain(at: frame)
            XCTAssertEqual(table.gain(forClip: clip.id, at: frame), expected, accuracy: 0.0001, "at frame \(frame)")
        }
    }

    // MARK: - Inaudible lane still silent with an envelope

    func testMutedLaneIsSilentEveryFrameEvenWithEnvelope() {
        let clip = makeClip(duration: 200)
        let lane = makeLane(clips: [clip], isMuted: true, automation: dippingEnvelope())

        let table = AutomationGainTable(timeline: Timeline(audioLanes: [lane]))

        for frame in [0, 50, 100, 150] {
            XCTAssertEqual(table.gain(forClip: clip.id, at: frame), 0, "at frame \(frame)")
        }
    }

    func testSoloedOtherLaneSilencesThisOneEveryFrameEvenWithEnvelope() {
        let clip = makeClip(duration: 200)
        let lane = makeLane(clips: [clip], automation: dippingEnvelope())
        let soloedOther = makeLane(clips: [makeClip()], isSolo: true)

        let table = AutomationGainTable(timeline: Timeline(audioLanes: [lane, soloedOther]))

        for frame in [0, 50, 100, 150] {
            XCTAssertEqual(table.gain(forClip: clip.id, at: frame), 0, "at frame \(frame)")
        }
    }

    func testOutputDisabledLaneIsSilentEveryFrameEvenWithEnvelope() {
        let clip = makeClip(duration: 200)
        let lane = makeLane(clips: [clip], isOutputDisabled: true, automation: dippingEnvelope())

        let table = AutomationGainTable(timeline: Timeline(audioLanes: [lane]))

        for frame in [0, 50, 100, 150] {
            XCTAssertEqual(table.gain(forClip: clip.id, at: frame), 0, "at frame \(frame)")
        }
    }

    // MARK: - Non-standalone lane bypasses automation (plan §2.5)

    func testSplitChannelLaneWithEnvelopeIsBypassed() {
        let clip = makeClip(duration: 200, volume: 0.5)
        let automation = dippingEnvelope()
        let lane = makeLane(clips: [clip], volume: 0.4, splitChannel: .left, automation: automation)

        let table = AutomationGainTable(timeline: Timeline(audioLanes: [lane]))

        XCTAssertFalse(table.hasAutomation, "A linked lane's envelope must not count toward hasAutomation")
        let base: Float = 0.5 * 0.4
        XCTAssertEqual(table.gain(forClip: clip.id, at: 50), base, "must equal base gain, not base * linearGain")
    }

    func testOwnerVideoReelLaneWithEnvelopeIsBypassed() {
        let clip = makeClip(duration: 200, volume: 0.5)
        let automation = dippingEnvelope()
        let lane = makeLane(clips: [clip], volume: 0.4, ownerVideoReelId: UUID(), automation: automation)

        let table = AutomationGainTable(timeline: Timeline(audioLanes: [lane]))

        XCTAssertFalse(table.hasAutomation)
        let base: Float = 0.5 * 0.4
        XCTAssertEqual(table.gain(forClip: clip.id, at: 50), base)
    }

    // MARK: - Clip-level mute

    func testMutedClipIsSilentEvenOnAudibleAutomatedLane() {
        let mutedClip = makeClip(duration: 200, isMuted: true)
        let lane = makeLane(clips: [mutedClip], automation: dippingEnvelope())

        let table = AutomationGainTable(timeline: Timeline(audioLanes: [lane]))

        XCTAssertEqual(table.gain(forClip: mutedClip.id, at: 50), 0)
    }

    // MARK: - Unknown clip

    func testUnknownClipGainIsZero() {
        let table = AutomationGainTable(timeline: .empty)
        XCTAssertEqual(table.gain(forClip: UUID(), at: 0), 0)
    }

    func testUnknownClipIsNotKnown() {
        let clip = makeClip()
        let lane = makeLane(clips: [clip])
        let table = AutomationGainTable(timeline: Timeline(audioLanes: [lane]))

        XCTAssertTrue(table.knowsClip(clip.id))
        XCTAssertFalse(table.knowsClip(UUID()))
    }

    // MARK: - Batched lookup agrees with the single-clip lookup

    func testGainsAtFrameAgreesWithGainForClipForEveryClip() {
        let automatedClip1 = makeClip(duration: 200, volume: 0.6)
        let automatedClip2 = makeClip(duration: 200, volume: 0.3)
        let automatedLane = makeLane(
            clips: [automatedClip1, automatedClip2],
            volume: 0.9,
            automation: dippingEnvelope()
        )

        let unityClip = makeClip(duration: 200, volume: 0.7)
        let unityLane = makeLane(clips: [unityClip], volume: 1.0)

        let mutedClip = makeClip(duration: 200)
        let mutedLane = makeLane(clips: [mutedClip], isMuted: true, automation: dippingEnvelope())

        let unknownClipId = UUID()

        let timeline = Timeline(audioLanes: [automatedLane, unityLane, mutedLane])
        let table = AutomationGainTable(timeline: timeline)

        let clipIds = [automatedClip1.id, automatedClip2.id, unityClip.id, mutedClip.id, unknownClipId]

        for frame in [0, 30, 60, 100, 150] {
            let batched = table.gains(at: frame, forClips: clipIds)
            for clipId in clipIds {
                XCTAssertEqual(
                    batched[clipId],
                    table.gain(forClip: clipId, at: frame),
                    "clip \(clipId) at frame \(frame) disagrees with the single-clip lookup"
                )
            }
        }
    }

    func testAutomatedClipIdsOnlyIncludesClipsOnAutomatedLanes() {
        let automatedClip = makeClip(duration: 200)
        let automatedLane = makeLane(clips: [automatedClip], automation: dippingEnvelope())

        let unityClip = makeClip(duration: 200)
        let unityLane = makeLane(clips: [unityClip])

        let table = AutomationGainTable(timeline: Timeline(audioLanes: [automatedLane, unityLane]))

        XCTAssertEqual(Set(table.automatedClipIds()), [automatedClip.id])
    }

    func testMovingAClipToAnotherLaneReKeysItsGain() {
        // The table is rebuilt from the timeline, so a clip that has moved to
        // an automated lane picks up that lane's envelope and loses its old one.
        let clip = makeClip(duration: 200)
        let plainLane = makeLane(clips: [clip])
        let automatedLane = makeLane(automation: dippingEnvelope())

        let before = AutomationGainTable(timeline: Timeline(audioLanes: [plainLane, automatedLane]))
        XCTAssertEqual(before.gain(forClip: clip.id, at: 50), 1)
        XCTAssertFalse(before.automatedClipIds().contains(clip.id))

        var movedPlain = plainLane
        movedPlain.removeClip(id: clip.id)
        var movedAutomated = automatedLane
        movedAutomated.addClip(clip)

        let after = AutomationGainTable(timeline: Timeline(audioLanes: [movedPlain, movedAutomated]))
        XCTAssertEqual(after.gain(forClip: clip.id, at: 50), dippingEnvelope().linearGain(at: 50), accuracy: 0.0001)
        XCTAssertTrue(after.automatedClipIds().contains(clip.id))
    }

    func testAutomatedClipIdsIsEmptyWithNoAutomation() {
        let clip = makeClip()
        let lane = makeLane(clips: [clip])
        let table = AutomationGainTable(timeline: Timeline(audioLanes: [lane]))

        XCTAssertTrue(table.automatedClipIds().isEmpty)
    }

    // MARK: - Removing the last envelope

    func testRemovingTheLastEnvelopePointRestoresUnity() {
        var automation = dippingEnvelope()
        let clip = makeClip(duration: 200)
        var lane = makeLane(clips: [clip], automation: automation)

        var table = AutomationGainTable(timeline: Timeline(audioLanes: [lane]))
        XCTAssertTrue(table.hasAutomation)

        automation.removeAll()
        lane.automation = automation
        table = AutomationGainTable(timeline: Timeline(audioLanes: [lane]))

        XCTAssertFalse(table.hasAutomation)
        XCTAssertEqual(table.gain(forClip: clip.id, at: 50), 1.0)
    }
}
