//
//  AggregateDeviceTests.swift
//  ProjectorTests
//
//  The aggregate description dictionary. Built and inspected without creating a
//  real device on the machine running the tests.
//

import CoreAudio
import XCTest
@testable import Projector

final class AggregateDeviceTests: XCTestCase {

    private let interfaceUID = "LynxAudioDevice-UID016016"
    private let virtualUID = "BlackHole16ch_UID"

    private func description() -> [String: Any] {
        AggregateDeviceManager.description(
            name: "Projector + Interface",
            interfaceUID: interfaceUID,
            virtualUID: virtualUID
        )
    }

    private func subDevices() -> [[String: Any]] {
        description()[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]] ?? []
    }

    // MARK: - Identity

    func testCarriesStableUID() {
        // Fixed so a second run rebuilds the same device instead of leaving a trail
        // of near-identical aggregates in Audio MIDI Setup.
        XCTAssertEqual(
            description()[kAudioAggregateDeviceUIDKey] as? String,
            AggregateDeviceManager.aggregateUID
        )
    }

    func testNameSaysWhatItIsBuiltFrom() {
        XCTAssertEqual(
            AggregateDeviceManager.aggregateName(interfaceName: "Aurora(n)-TB3"),
            "Projector + Aurora(n)-TB3"
        )
    }

    // MARK: - Channel Map

    /// Sub-device order *is* the channel map: CoreAudio concatenates channels in list
    /// order. The interface has to come first so its channels stay where the user's
    /// speakers already are, with the virtual device above them.
    func testInterfaceComesFirstAndVirtualSecond() {
        let devices = subDevices()
        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices.first?[kAudioSubDeviceUIDKey] as? String, interfaceUID)
        XCTAssertEqual(devices.last?[kAudioSubDeviceUIDKey] as? String, virtualUID)
    }

    // MARK: - Clock

    func testInterfaceIsTheClockMaster() {
        XCTAssertEqual(
            description()[kAudioAggregateDeviceMainSubDeviceKey] as? String,
            interfaceUID
        )
    }

    /// The virtual device has no hardware clock. Without drift compensation the two
    /// halves of the aggregate slide apart over the length of a reel, which is the
    /// exact failure this application exists to prevent.
    func testOnlyTheVirtualDeviceIsDriftCompensated() {
        let devices = subDevices()
        XCTAssertEqual(devices.first?[kAudioSubDeviceDriftCompensationKey] as? Int, 0)
        XCTAssertEqual(devices.last?[kAudioSubDeviceDriftCompensationKey] as? Int, 1)
    }

    func testDriftQualityIsSetOnTheVirtualDevice() {
        // Within CoreAudio's documented 0...0x7F range, and not the minimum.
        guard let quality = subDevices().last?[kAudioSubDeviceDriftCompensationQualityKey] as? Int else {
            return XCTFail("Expected a drift compensation quality")
        }
        XCTAssertGreaterThan(quality, 0)
        XCTAssertLessThanOrEqual(quality, 0x7F)
    }

    func testInterfaceCarriesNoDriftQuality() {
        // Nothing to compensate against - it is the clock.
        XCTAssertNil(subDevices().first?[kAudioSubDeviceDriftCompensationQualityKey])
    }

    // MARK: - Visibility

    /// A private aggregate is invisible to other processes, which would defeat the
    /// entire purpose - the DAW has to see it - and CoreAudio's private flag is
    /// documented as unreliable besides.
    func testDeviceIsPublic() {
        XCTAssertEqual(description()[kAudioAggregateDeviceIsPrivateKey] as? Int, 0)
    }

    /// Not stacked: sub-devices sit side by side as separate channels rather than
    /// being summed on top of each other. Stacking would mix the stems into the
    /// speaker feed.
    func testDeviceIsNotStacked() {
        XCTAssertEqual(description()[kAudioAggregateDeviceIsStackedKey] as? Int, 0)
    }
}

// MARK: - Channel Map

/// Where each output lands on the aggregate. An off-by-one here does not fail
/// loudly - it sends a stem to the wrong pair of channels, so the DAW records
/// silence or the room hears music it should not.
final class AggregateChannelMapTests: XCTestCase {

    // MARK: - Which Side Each Output Lands On

    /// Monitoring stays on the interface's first pair whatever its width, so the room
    /// keeps hearing the reel.
    func testMonitoringStaysOnTheInterface() {
        for width in [2, 8, 16, 32, 64] {
            let map = AggregateChannelMap(interfaceChannelCount: width)
            XCTAssertEqual(map.stereoOutFirstChannel, 1)
            XCTAssertFalse(map.reachesDAW(firstChannel: map.stereoOutFirstChannel))
        }
    }

    /// The stems must never land on the interface, or they play out of the speakers -
    /// audible reference audio over the mix, which is worse than silence.
    func testStemsNeverLandOnTheInterface() {
        for width in [1, 2, 8, 16, 32, 64] {
            let map = AggregateChannelMap(interfaceChannelCount: width)
            XCTAssertGreaterThan(map.dialogueEffectsFirstChannel, width)
            XCTAssertGreaterThan(map.musicFirstChannel, width)
            XCTAssertTrue(map.reachesDAW(firstChannel: map.dialogueEffectsFirstChannel))
            XCTAssertTrue(map.reachesDAW(firstChannel: map.musicFirstChannel))
        }
    }

    // MARK: - Layout

    /// The stems begin immediately above the interface, which is where the loopback
    /// device's own channel 1 lands once CoreAudio concatenates the two.
    func testStemsStackJustAboveTheInterface() {
        let map = AggregateChannelMap(interfaceChannelCount: 32)
        XCTAssertEqual(map.dialogueEffectsFirstChannel, 33)
        XCTAssertEqual(map.musicFirstChannel, 35)
    }

    func testStemsDoNotOverlapEachOther() {
        for width in [2, 8, 16, 32, 64] {
            let map = AggregateChannelMap(interfaceChannelCount: width)
            XCTAssertEqual(map.musicFirstChannel - map.dialogueEffectsFirstChannel, 2)
        }
    }

    /// The narrow case is the one most likely to be got wrong: a 2-channel interface
    /// means the stems start at 3, not at some fixed high number.
    func testNarrowInterfacePullsTheStemsDown() {
        let map = AggregateChannelMap(interfaceChannelCount: 2)
        XCTAssertEqual(map.stereoOutFirstChannel, 1)
        XCTAssertEqual(map.dialogueEffectsFirstChannel, 3)
        XCTAssertEqual(map.musicFirstChannel, 5)
    }

    // MARK: - What The DAW Is Told

    /// The aggregate calls it channel 33; a DAW reading the loopback device calls it
    /// input 1. Getting this conversion wrong sends the user to the wrong input and
    /// they hear silence with nothing obviously broken.
    func testLoopbackChannelsAreCountedFromTheLoopbackDevice() {
        let map = AggregateChannelMap(interfaceChannelCount: 32)
        XCTAssertEqual(map.loopbackChannel(forAggregateChannel: map.dialogueEffectsFirstChannel), 1)
        XCTAssertEqual(map.loopbackChannel(forAggregateChannel: map.musicFirstChannel), 3)
    }

    /// The DAW-facing numbers are the same whatever the interface's width - only the
    /// aggregate numbering shifts.
    func testLoopbackChannelsAreIndependentOfInterfaceWidth() {
        for width in [2, 8, 32, 64] {
            let map = AggregateChannelMap(interfaceChannelCount: width)
            XCTAssertEqual(map.loopbackChannel(forAggregateChannel: map.dialogueEffectsFirstChannel), 1)
            XCTAssertEqual(map.loopbackChannel(forAggregateChannel: map.musicFirstChannel), 3)
        }
    }

    // MARK: - Room To Grow

    /// Outputs added later continue up the loopback side rather than dropping back
    /// onto the interface, so a new port reaches the DAW like the stems do.
    func testAdditionalOutputsContinueOnTheDAWSide() {
        let map = AggregateChannelMap(interfaceChannelCount: 32)
        XCTAssertEqual(map.firstAdditionalChannel, 37)
        XCTAssertTrue(map.reachesDAW(firstChannel: map.firstAdditionalChannel))
    }

    /// Two stereo stems, so four loopback channels - exactly the floor
    /// ``VirtualAudioPorts/minimumChannels`` enforces before offering the feature.
    /// If these drift apart, setup is offered on a device too narrow to carry it.
    func testRequiredChannelsMatchTheReadinessFloor() {
        XCTAssertEqual(AggregateChannelMap.requiredVirtualChannels, 4)
        XCTAssertEqual(
            AggregateChannelMap.requiredVirtualChannels,
            VirtualAudioPorts.minimumChannels
        )
    }

    /// The seeded layout has to fit inside the build Projector installs, with room
    /// left over for the outputs a user adds afterwards.
    func testSeededLayoutLeavesRoomForMoreOutputs() {
        let map = AggregateChannelMap(interfaceChannelCount: 32)
        let highestSeeded = map.loopbackChannel(forAggregateChannel: map.musicFirstChannel + 1)
        XCTAssertLessThan(highestSeeded, VirtualAudioPorts.preferredChannelCount)

        let firstFree = map.loopbackChannel(forAggregateChannel: map.firstAdditionalChannel)
        let pairsRemaining = (VirtualAudioPorts.preferredChannelCount - firstFree + 1) / 2
        XCTAssertGreaterThanOrEqual(
            pairsRemaining, 5,
            "A 16-channel build should leave several stereo outputs' worth of room"
        )
    }
}
