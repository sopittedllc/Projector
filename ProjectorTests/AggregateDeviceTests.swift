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
            name: AggregateDeviceManager.aggregateName,
            interfaceUID: interfaceUID,
            virtualUID: virtualUID
        )
    }

    /// A 16-channel loopback device with a 32-channel interface above it.
    private let map = AggregateChannelMap(virtualChannelCount: 16, interfaceChannelCount: 32)

    /// The layout Projector built before the stems moved to the low channels. Still on
    /// machines that set up early, and still has to be described correctly.
    private let legacyMap = AggregateChannelMap(
        virtualChannelCount: 16,
        interfaceChannelCount: 32,
        virtualComesFirst: false
    )

    private func origin() -> AggregateChannelOrigin {
        AggregateChannelOrigin(
            map: map,
            interfaceName: "Aurora(n)-TB3",
            virtualName: AggregateDeviceManager.virtualHalfName,
            totalChannelCount: 48
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

    /// Fixed rather than built from the interface: the user hunts for one string in
    /// their DAW's device menu, and it has to be the same string every time.
    func testNameIsStableAcrossRebuilds() {
        XCTAssertEqual(AggregateDeviceManager.aggregateName, "Projector Aggregate Device")
        XCTAssertEqual(
            description()[kAudioAggregateDeviceNameKey] as? String,
            AggregateDeviceManager.aggregateName
        )
    }

    // MARK: - Channel Origin

    /// Numbered as the DAW numbers them. The interface's own channel 1 is the
    /// aggregate's 17, and 17 is what the user has to type.
    func testInterfaceChannelsAreNamedAfterTheInterface() {
        XCTAssertEqual(
            origin().label(firstChannel: 17, channelCount: 2),
            "Aurora(n)-TB3 17-18"
        )
    }

    /// The stems lead, so their aggregate numbers are their DAW port numbers - the
    /// point of the reorder, and why no conversion appears here any more.
    func testVirtualChannelsRestartAtTheLoopbackDevice() {
        XCTAssertEqual(
            origin().label(firstChannel: 1, channelCount: 2),
            "Projector Virtual 1-2"
        )
        XCTAssertEqual(
            origin().label(firstChannel: 3, channelCount: 2),
            "Projector Virtual 3-4"
        )
    }

    /// A mono output names one channel, not a range of one.
    func testMonoChannelIsNamedSingly() {
        XCTAssertEqual(origin().label(firstChannel: 17, channelCount: 1), "Aurora(n)-TB3 17")
        XCTAssertEqual(origin().label(firstChannel: 1, channelCount: 1), "Projector Virtual 1")
    }

    /// The boundary: the last interface channel still belongs to the interface, and the
    /// first channel above it has crossed over.
    func testHalvesDivideAtTheInterfaceChannelCount() {
        XCTAssertEqual(origin().label(firstChannel: 16, channelCount: 1), "Projector Virtual 16")
        XCTAssertEqual(origin().label(firstChannel: 17, channelCount: 1), "Aurora(n)-TB3 17")
    }

    // MARK: - Channel Names Shown to the DAW

    private func output(_ name: String, firstChannel: Int, channelCount: Int) -> MappedAudioOutput {
        MappedAudioOutput(
            name: name,
            channelStart: firstChannel - 1,
            channelCount: channelCount
        )
    }

    /// A DAW shows these against a stereo pair, where L and R are the distinction that
    /// matters and a number is not.
    func testStereoOutputIsNamedLeftAndRight() {
        let stem = output("DX/SFX", firstChannel: 1, channelCount: 2)
        XCTAssertEqual(VirtualPortLabels.name(for: stem, channelOffset: 0), "DX/SFX L")
        XCTAssertEqual(VirtualPortLabels.name(for: stem, channelOffset: 1), "DX/SFX R")
    }

    /// A mono output is just its name - there is no side to disambiguate.
    func testMonoOutputCarriesItsNameAlone() {
        let stem = output("Cue", firstChannel: 1, channelCount: 1)
        XCTAssertEqual(VirtualPortLabels.name(for: stem, channelOffset: 0), "Cue")
    }

    /// Wider than stereo: numbered, because L/R stops meaning anything.
    func testWideOutputIsNumbered() {
        let stem = output("Stems", firstChannel: 1, channelCount: 4)
        XCTAssertEqual(VirtualPortLabels.name(for: stem, channelOffset: 0), "Stems 1")
        XCTAssertEqual(VirtualPortLabels.name(for: stem, channelOffset: 3), "Stems 4")
    }

    /// No port is left generic. A channel carrying nothing still says which device it
    /// belongs to, in the same words the settings rows use — a DAW that finds no name
    /// invents one from the device, which is how forty-eight identical rows happen.
    func testUnassignedChannelsStillNameTheirDevice() {
        XCTAssertEqual(origin().label(firstChannel: 23, channelCount: 1), "Aurora(n)-TB3 23")
        XCTAssertEqual(origin().label(firstChannel: 8, channelCount: 1), "Projector Virtual 8")
    }

    /// The interface half is described by the interface, never by what Projector sends
    /// there. Those channels are the user's own hardware and reach the room, not the DAW.
    func testInterfaceOutputsAreNotLabelledAsStems() {
        let map = origin().map
        XCTAssertTrue(map.reachesDAW(firstChannel: 1))
        XCTAssertFalse(map.reachesDAW(firstChannel: 17))
    }

    // MARK: - Channel Map

    /// Sub-device order *is* the channel map: CoreAudio concatenates channels in list
    /// order. The loopback device leads so the stems are a DAW's first inputs - with a
    /// 32-channel interface ahead of them they landed on 33-36, which no host made
    /// findable and Cubase actively obscured by ignoring channel names.
    func testVirtualComesFirstSoStemsAreTheLowChannels() {
        let devices = subDevices()
        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices.first?[kAudioSubDeviceUIDKey] as? String, virtualUID)
        XCTAssertEqual(devices.last?[kAudioSubDeviceUIDKey] as? String, interfaceUID)
    }

    /// Order is not the clock. The interface stays the time source wherever it sits in
    /// the list - conflating the two is what made the order look fixed.
    func testOrderDoesNotChangeTheClockMaster() {
        XCTAssertEqual(
            description()[kAudioAggregateDeviceMainSubDeviceKey] as? String,
            interfaceUID
        )
        XCTAssertNotEqual(
            subDevices().first?[kAudioSubDeviceUIDKey] as? String,
            description()[kAudioAggregateDeviceMainSubDeviceKey] as? String
        )
    }

    // MARK: - Where Things Land

    func testStemsStartAtChannelOne() {
        XCTAssertEqual(map.dialogueEffectsFirstChannel, 1)
        XCTAssertEqual(map.musicFirstChannel, 3)
        XCTAssertEqual(map.firstAdditionalChannel, 5)
    }

    /// The number to quote when telling someone where their own hardware begins.
    func testInterfaceBeginsAboveTheLoopbackHalf() {
        XCTAssertEqual(map.interfaceFirstChannel, 17)
        XCTAssertEqual(map.stereoOutFirstChannel, 17)
    }

    /// What Projector quotes is what the DAW lists, now that the stems lead.
    func testLoopbackNumberingMatchesTheAggregate() {
        XCTAssertEqual(map.loopbackChannel(forAggregateChannel: 1), 1)
        XCTAssertEqual(map.loopbackChannel(forAggregateChannel: 3), 3)
    }

    /// A device built before the stems moved is still described correctly, because the
    /// order is read back from it rather than assumed.
    func testLegacyLayoutIsStillDescribedCorrectly() {
        XCTAssertEqual(legacyMap.interfaceFirstChannel, 1)
        XCTAssertEqual(legacyMap.stereoOutFirstChannel, 1)
        XCTAssertEqual(legacyMap.dialogueEffectsFirstChannel, 33)
        XCTAssertEqual(legacyMap.loopbackChannel(forAggregateChannel: 33), 1)
        XCTAssertTrue(legacyMap.reachesDAW(firstChannel: 33))
        XCTAssertFalse(legacyMap.reachesDAW(firstChannel: 1))
    }

    /// The interface half never counts as reaching the DAW, at either end of its range.
    func testInterfaceChannelsNeverReachTheDAW() {
        XCTAssertTrue(map.reachesDAW(firstChannel: 16))
        XCTAssertFalse(map.reachesDAW(firstChannel: 17))
        XCTAssertFalse(map.reachesDAW(firstChannel: 48))
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

    /// A map for a loopback device of the given width, with a 32-channel interface.
    private func map(virtualChannels: Int) -> AggregateChannelMap {
        AggregateChannelMap(virtualChannelCount: virtualChannels, interfaceChannelCount: 32)
    }

    /// Monitoring stays on the interface's first pair whatever the loopback width, so
    /// the room keeps hearing the reel - it just no longer sits at channel 1.
    func testMonitoringStaysOnTheInterface() {
        for width in [4, 8, 16, 64] {
            let map = map(virtualChannels: width)
            XCTAssertEqual(map.stereoOutFirstChannel, width + 1)
            XCTAssertFalse(map.reachesDAW(firstChannel: map.stereoOutFirstChannel))
        }
    }

    /// The stems must never land on the interface, or they play out of the speakers -
    /// audible reference audio over the mix, which is worse than silence.
    func testStemsNeverLandOnTheInterface() {
        for width in [4, 8, 16, 64] {
            let map = map(virtualChannels: width)
            XCTAssertLessThan(map.dialogueEffectsFirstChannel, map.interfaceFirstChannel)
            XCTAssertLessThan(map.musicFirstChannel, map.interfaceFirstChannel)
            XCTAssertTrue(map.reachesDAW(firstChannel: map.dialogueEffectsFirstChannel))
            XCTAssertTrue(map.reachesDAW(firstChannel: map.musicFirstChannel))
        }
    }

    // MARK: - Layout

    /// The whole point of the loopback half leading: a DAW opening the device finds the
    /// stems on its first inputs instead of hunting past the interface for them.
    func testStemsStartAtTheFirstChannel() {
        let map = map(virtualChannels: 16)
        XCTAssertEqual(map.dialogueEffectsFirstChannel, 1)
        XCTAssertEqual(map.musicFirstChannel, 3)
    }

    func testStemsDoNotOverlapEachOther() {
        for width in [4, 8, 16, 64] {
            let map = map(virtualChannels: width)
            XCTAssertEqual(map.musicFirstChannel - map.dialogueEffectsFirstChannel, 2)
        }
    }

    /// The stems keep the same channels whatever the interface's width. That is what
    /// makes "assign to inputs 1-4" a sentence Projector can print for everybody.
    func testStemChannelsDoNotDependOnTheInterface() {
        for interfaceWidth in [2, 8, 32, 64] {
            let map = AggregateChannelMap(
                virtualChannelCount: 16,
                interfaceChannelCount: interfaceWidth
            )
            XCTAssertEqual(map.dialogueEffectsFirstChannel, 1)
            XCTAssertEqual(map.musicFirstChannel, 3)
        }
    }

    /// Where the user's own hardware begins - the number Projector quotes so nobody
    /// patches their interface's channel 1 expecting the device's channel 1.
    func testInterfaceBeginsAboveTheLoopbackHalf() {
        XCTAssertEqual(map(virtualChannels: 16).interfaceFirstChannel, 17)
        XCTAssertEqual(map(virtualChannels: 4).interfaceFirstChannel, 5)
    }

    // MARK: - What The DAW Is Told

    /// Now an identity, and deliberately so: the number Projector shows is the number
    /// the DAW lists. Before the reorder these differed by the interface's width, which
    /// is precisely how a user ended up patching the wrong input.
    func testLoopbackNumbersMatchTheAggregateNumbers() {
        let map = map(virtualChannels: 16)
        XCTAssertEqual(map.loopbackChannel(forAggregateChannel: map.dialogueEffectsFirstChannel), 1)
        XCTAssertEqual(map.loopbackChannel(forAggregateChannel: map.musicFirstChannel), 3)
    }

    /// The DAW-facing numbers are the same whatever the interface's width.
    func testLoopbackChannelsAreIndependentOfInterfaceWidth() {
        for width in [2, 8, 32, 64] {
            let map = AggregateChannelMap(virtualChannelCount: 16, interfaceChannelCount: width)
            XCTAssertEqual(map.loopbackChannel(forAggregateChannel: map.dialogueEffectsFirstChannel), 1)
            XCTAssertEqual(map.loopbackChannel(forAggregateChannel: map.musicFirstChannel), 3)
        }
    }

    /// The interface's own channel 1 is the aggregate's channel 17, and saying so is the
    /// only way a user finds their own inputs again.
    func testInterfaceChannelsAreCountedFromTheInterface() {
        let map = map(virtualChannels: 16)
        XCTAssertEqual(map.interfaceChannel(forAggregateChannel: 17), 1)
        XCTAssertEqual(map.interfaceChannel(forAggregateChannel: 48), 32)
    }

    // MARK: - Room To Grow

    /// Outputs added later continue up the loopback side rather than dropping back
    /// onto the interface, so a new port reaches the DAW like the stems do.
    func testAdditionalOutputsContinueOnTheDAWSide() {
        let map = map(virtualChannels: 16)
        XCTAssertEqual(map.firstAdditionalChannel, 5)
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
        let map = map(virtualChannels: 16)
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
