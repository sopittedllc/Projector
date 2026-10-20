//
//  LaneLevelTests.swift
//  ProjectorTests
//
//  Tests for the per-lane level control: the dB/linear model, the playback
//  gain split, the gain table, the manager's clamp, persistence and undo.
//

import XCTest
@testable import Projector
import SwiftTimecodeCore

@MainActor
final class LaneLevelTests: XCTestCase {

    // MARK: - Model

    func testUnityIsZeroDBAndRoundTrips() {
        XCTAssertEqual(LaneLevel.linear(fromDB: 0), 1.0)
        XCTAssertEqual(LaneLevel.dB(fromLinear: 1.0), 0, accuracy: 1e-6)
    }

    func testMaximumIsPlusTwelveDB() {
        XCTAssertEqual(LaneLevel.maxLinear, 3.981, accuracy: 0.001)
        XCTAssertEqual(LaneLevel.linear(fromDB: 40), LaneLevel.maxLinear, accuracy: 1e-6, "Above the maximum clamps")
        XCTAssertEqual(LaneLevel.dB(fromLinear: 100), LaneLevel.maxDB, accuracy: 1e-6)
    }

    func testFloorAndBelowIsSilent() {
        XCTAssertEqual(LaneLevel.linear(fromDB: LaneLevel.floorDB), 0)
        XCTAssertEqual(LaneLevel.linear(fromDB: -.infinity), 0)
        XCTAssertEqual(LaneLevel.dB(fromLinear: 0), -.infinity)
        XCTAssertGreaterThan(LaneLevel.linear(fromDB: LaneLevel.floorDB + 0.5), 0)
    }

    func testSliderMappingIsLinearInDecibelsWithSilentBottomStop() {
        XCTAssertEqual(LaneLevel.linear(fromPosition: 0), 0, "Bottom stop is silence")
        XCTAssertEqual(LaneLevel.linear(fromPosition: 1), LaneLevel.maxLinear, accuracy: 1e-5)

        // Halfway between -60 and +12 is -24 dB.
        let half = LaneLevel.linear(fromPosition: 0.5)
        XCTAssertEqual(LaneLevel.dB(fromLinear: half), -24, accuracy: 0.05)

        // Position of unity sits at (0 - floor) / (max - floor) and maps back to exactly 1.0.
        let unityPosition = LaneLevel.position(fromLinear: 1.0)
        XCTAssertEqual(unityPosition, 60.0 / 72.0, accuracy: 1e-6)
        XCTAssertEqual(LaneLevel.linear(fromPosition: unityPosition), 1.0)
    }

    func testSteppedDBRoundsToTheStepAndKeepsUnityExact() {
        XCTAssertEqual(LaneLevel.linear(fromSteppedDB: 0.04), 1.0)
        XCTAssertEqual(LaneLevel.linear(fromSteppedDB: 3.04), LaneLevel.linear(fromDB: 3.0), accuracy: 1e-6)
        XCTAssertEqual(LaneLevel.linear(fromSteppedDB: -75), 0)
    }

    func testReadoutFormat() {
        XCTAssertEqual(LaneLevel.readout(fromLinear: 0), "\u{2212}\u{221E}")
        XCTAssertEqual(LaneLevel.readout(fromLinear: 1), "0.0 dB")
        XCTAssertEqual(LaneLevel.readout(fromLinear: LaneLevel.linear(fromDB: 3)), "+3.0 dB")
        XCTAssertEqual(LaneLevel.readout(fromLinear: LaneLevel.linear(fromDB: -6)), "\u{2212}6.0 dB")
        XCTAssertEqual(LaneLevel.readout(fromLinear: LaneLevel.maxLinear), "+12.0 dB")
    }

    func testClampedLinear() {
        XCTAssertEqual(LaneLevel.clampedLinear(-1), 0)
        XCTAssertEqual(LaneLevel.clampedLinear(2), 2)
        XCTAssertEqual(LaneLevel.clampedLinear(10), LaneLevel.maxLinear)
        XCTAssertEqual(LaneLevel.clampedLinear(.nan), 1)
    }

    // MARK: - Playback split

    func testSplitBelowUnityStaysOnThePlayer() {
        let split = LaneLevel.splitPlaybackGain(totalLinear: 0.4)
        XCTAssertEqual(split.playerVolume, 0.4)
        XCTAssertEqual(split.boostDB, 0)
    }

    func testSplitAboveUnityGoesToTheBoostStage() {
        let split = LaneLevel.splitPlaybackGain(totalLinear: LaneLevel.maxLinear)
        XCTAssertEqual(split.playerVolume, 1)
        XCTAssertEqual(split.boostDB, 12, accuracy: 1e-4)
    }

    func testSplitProductIsTheTotal() {
        for total: Float in [0, 0.001, 0.5, 1, 1.5, 2.5, LaneLevel.maxLinear] {
            let split = LaneLevel.splitPlaybackGain(totalLinear: total)
            let product = split.playerVolume * VolumeAutomation.linearVolume(fromDB: split.boostDB)
            XCTAssertEqual(product, total, accuracy: total * 1e-5 + 1e-7, "total \(total)")
            XCTAssertLessThanOrEqual(split.playerVolume, 1)
            XCTAssertGreaterThanOrEqual(split.boostDB, 0)
        }
    }

    func testSplitOfSilenceAndNonsenseIsSilent() {
        XCTAssertEqual(LaneLevel.splitPlaybackGain(totalLinear: 0).playerVolume, 0)
        XCTAssertEqual(LaneLevel.splitPlaybackGain(totalLinear: .nan).playerVolume, 0)
        XCTAssertEqual(LaneLevel.splitPlaybackGain(totalLinear: .nan).boostDB, 0)
    }

    func testSplitBoostIsCapped() {
        XCTAssertEqual(LaneLevel.splitPlaybackGain(totalLinear: 1000).boostDB, LaneLevel.maxBoostDB)
    }

    // MARK: - Gain table

    func testGainTableBaseGainIncludesALaneLevelAboveUnity() {
        let clip = AudioClip(
            sourceURL: URL(fileURLWithPath: "/tmp/LaneLevelTests-clip.wav"),
            timelineStartFrame: 0,
            durationFrames: 100,
            volume: 0.5
        )
        let boosted = LaneLevel.linear(fromDB: 6)
        let lane = AudioLane(name: "Lane", clips: [clip], volume: boosted)

        let table = AutomationGainTable(timeline: Timeline(audioLanes: [lane]))

        XCTAssertEqual(table.gain(forClip: clip.id, at: 0), 0.5 * boosted, accuracy: 1e-6)
    }

    func testGainTableStacksLaneLevelOverAutomation() {
        let clip = AudioClip(
            sourceURL: URL(fileURLWithPath: "/tmp/LaneLevelTests-clip.wav"),
            timelineStartFrame: 0,
            durationFrames: 200
        )
        var automation = VolumeAutomation()
        automation.insert(frame: 0, gainDB: -6)
        let boosted = LaneLevel.linear(fromDB: 6)
        let lane = AudioLane(name: "Lane", clips: [clip], volume: boosted, automation: automation)

        let table = AutomationGainTable(timeline: Timeline(audioLanes: [lane]))

        // +6 dB level over a -6 dB envelope is unity.
        XCTAssertEqual(table.gain(forClip: clip.id, at: 50), 1.0, accuracy: 1e-5)
    }

    // MARK: - Manager

    private func makeManager() -> (TimelineManager, UUID) {
        let startTC = Timecode(.components(h: 0, m: 0, s: 0, f: 0), at: .fps24, by: .clamping)
        let endTC = Timecode(.components(h: 0, m: 6, s: 56, f: 16), at: .fps24, by: .clamping)
        let config = TimelineConfig(startTimecode: startTC, endTimecode: endTC, frameRate: .fps24)
        let manager = TimelineManager(timeline: Timeline(config: config, videoReels: [], audioLanes: []))
        return (manager, manager.addAudioLane(name: "Dialogue").id)
    }

    func testManagerClampsToTheNewRange() {
        let (manager, laneId) = makeManager()

        manager.setLaneVolume(id: laneId, volume: 2.0)
        XCTAssertEqual(manager.timeline.audioLanes[0].volume, 2.0, "Above unity is now allowed")

        manager.setLaneVolume(id: laneId, volume: 50)
        XCTAssertEqual(manager.timeline.audioLanes[0].volume, LaneLevel.maxLinear)

        manager.setLaneVolume(at: 0, volume: -3)
        XCTAssertEqual(manager.timeline.audioLanes[0].volume, 0)

        manager.setLaneVolume(at: 0, volume: 99)
        XCTAssertEqual(manager.timeline.audioLanes[0].volume, LaneLevel.maxLinear)
    }

    // MARK: - Persistence

    func testProjectSavedAtUnityDecodesAsZeroDB() throws {
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

        XCTAssertEqual(decoded.volume, 1.0)
        XCTAssertEqual(decoded.levelDB, 0, accuracy: 1e-6)
    }

    func testBoostedLevelSurvivesARoundTrip() throws {
        let boosted = LaneLevel.linear(fromDB: 9)
        let lane = AudioLane(name: "Music", volume: boosted)

        let decoded = try JSONDecoder().decode(AudioLane.self, from: JSONEncoder().encode(lane))

        XCTAssertEqual(decoded.volume, boosted)
        XCTAssertEqual(decoded.levelDB, 9, accuracy: 0.001)
    }

    // MARK: - Undo

    func testLevelUndoRedoCyclesBetweenTheTwoValues() {
        let (manager, laneId) = makeManager()
        let undoManager = UndoManager()
        let boosted = LaneLevel.linear(fromDB: 6)

        LaneLevelUndo.register(on: undoManager, manager: manager, laneId: laneId, from: 1.0, to: boosted)
        undoManager.endUndoGrouping()
        manager.setLaneVolume(id: laneId, volume: boosted)

        for _ in 0..<2 {
            undoManager.undo()
            XCTAssertEqual(manager.timeline.audioLanes[0].volume, 1.0)
            undoManager.redo()
            XCTAssertEqual(manager.timeline.audioLanes[0].volume, boosted)
        }
    }

    func testLevelUndoIgnoresAnUnchangedLevel() {
        let (manager, laneId) = makeManager()
        let undoManager = UndoManager()

        LaneLevelUndo.register(on: undoManager, manager: manager, laneId: laneId, from: 1.0, to: 1.0)

        XCTAssertFalse(undoManager.canUndo)
    }
}
