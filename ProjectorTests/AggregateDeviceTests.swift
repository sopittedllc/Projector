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
