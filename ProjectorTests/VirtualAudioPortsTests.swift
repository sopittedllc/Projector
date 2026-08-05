//
//  VirtualAudioPortsTests.swift
//  ProjectorTests
//
//  Finding a usable loopback device, and the release details used to fetch one.
//  Pure functions - no devices created, no network.
//

import XCTest
@testable import Projector

final class VirtualAudioPortsTests: XCTestCase {

    // MARK: - Helpers

    private func device(uid: String, name: String, channels: Int) -> AudioDevice {
        AudioDevice(id: 0, uid: uid, name: name, outputChannelCount: channels)
    }

    private var blackHole16: AudioDevice {
        device(uid: "BlackHole16ch_UID", name: "BlackHole 16ch", channels: 16)
    }

    private var blackHole2: AudioDevice {
        device(uid: "BlackHole2ch_UID", name: "BlackHole 2ch", channels: 2)
    }

    private var interface: AudioDevice {
        device(uid: "LynxAudioDevice-UID016016", name: "Aurora(n)-TB3", channels: 32)
    }

    // MARK: - Identification

    func testIdentifiesBlackHoleBuilds() {
        XCTAssertTrue(VirtualAudioPorts.isVirtualPortDevice(blackHole16))
        XCTAssertTrue(VirtualAudioPorts.isVirtualPortDevice(blackHole2))
    }

    func testDoesNotMistakeOtherDevicesForBlackHole() {
        XCTAssertFalse(VirtualAudioPorts.isVirtualPortDevice(interface))
        // Other loopback drivers are not interchangeable here - the channel map and
        // the DAW walkthrough are written against BlackHole specifically.
        XCTAssertFalse(VirtualAudioPorts.isVirtualPortDevice(
            device(uid: "Pro Tools Audio Bridge 16_UID", name: "Pro Tools Audio Bridge 16", channels: 16)
        ))
    }

    /// Matched on UID rather than display name, because a device can be renamed in
    /// Audio MIDI Setup but its UID is stable.
    func testMatchesOnUIDNotDisplayName() {
        let renamed = device(uid: "BlackHole16ch_UID", name: "Stems Bus", channels: 16)
        XCTAssertTrue(VirtualAudioPorts.isVirtualPortDevice(renamed))

        let impostor = device(uid: "SomethingElse_UID", name: "BlackHole 16ch", channels: 16)
        XCTAssertFalse(VirtualAudioPorts.isVirtualPortDevice(impostor))
    }

    // MARK: - Readiness

    func testReadyWhenAWideEnoughBuildIsInstalled() {
        guard case .ready(let found) = VirtualAudioPorts.readiness(in: [interface, blackHole16]) else {
            return XCTFail("Expected .ready")
        }
        XCTAssertEqual(found.uid, "BlackHole16ch_UID")
    }

    func testMissingWhenNoBuildIsInstalled() {
        XCTAssertEqual(VirtualAudioPorts.readiness(in: [interface]), .missing)
        XCTAssertEqual(VirtualAudioPorts.readiness(in: []), .missing)
    }

    /// The common trap: the 2-channel build carries one stereo stem, not the two
    /// Projector routes by default. Reported separately from "missing" because the
    /// user is not short of software, they have the wrong build.
    func testTwoChannelBuildIsReportedAsTooNarrow() {
        guard case .insufficientChannels(_, let found, let required) =
                VirtualAudioPorts.readiness(in: [interface, blackHole2]) else {
            return XCTFail("Expected .insufficientChannels")
        }
        XCTAssertEqual(found, 2)
        XCTAssertEqual(required, VirtualAudioPorts.minimumChannels)
    }

    /// A machine can carry several builds at once - installing the wide one leaves
    /// the narrow one in place. The widest has to win, or a leftover 2ch device
    /// would keep the feature switched off.
    func testPrefersTheWidestBuildWhenSeveralArePresent() {
        guard case .ready(let found) =
                VirtualAudioPorts.readiness(in: [blackHole2, interface, blackHole16]) else {
            return XCTFail("Expected .ready")
        }
        XCTAssertEqual(found.outputChannelCount, 16)
    }

    func testMinimumCoversTwoStereoStems() {
        XCTAssertEqual(VirtualAudioPorts.minimumChannels, 4)
        XCTAssertGreaterThanOrEqual(
            VirtualAudioPorts.preferredChannelCount,
            VirtualAudioPorts.minimumChannels
        )
    }
}

// MARK: - Release Details

final class BlackHoleReleaseTests: XCTestCase {

    // MARK: - Version Parsing

    func testStripsTheLeadingVFromATag() {
        XCTAssertEqual(BlackHoleRelease.version(fromTag: "v0.7.1"), "0.7.1")
        XCTAssertEqual(BlackHoleRelease.version(fromTag: "0.7.1"), "0.7.1")
    }

    func testRejectsTagsThatAreNotVersions() {
        // The version is interpolated straight into a URL path, so anything that is
        // not digits and dots must not get that far.
        XCTAssertNil(BlackHoleRelease.version(fromTag: "latest"))
        XCTAssertNil(BlackHoleRelease.version(fromTag: "v"))
        XCTAssertNil(BlackHoleRelease.version(fromTag: ""))
        XCTAssertNil(BlackHoleRelease.version(fromTag: "0.7.1/../../evil"))
    }

    // MARK: - URL Construction

    func testBuildsTheVendorURLForAVersion() {
        let url = BlackHoleRelease.downloadURL(forVersion: "0.7.1")
        XCTAssertEqual(url.host, "existential.audio")
        XCTAssertEqual(url.lastPathComponent, "BlackHole16ch-0.7.1.pkg")
        XCTAssertEqual(url.scheme, "https")
    }

    func testURLTracksThePreferredChannelCount() {
        XCTAssertTrue(
            BlackHoleRelease.downloadURL(forVersion: "1.0.0").lastPathComponent
                .contains("\(VirtualAudioPorts.preferredChannelCount)ch")
        )
    }

    // MARK: - Trust

    func testAcceptsTheVendorURL() {
        XCTAssertNoThrow(try BlackHoleInstaller.validate(BlackHoleRelease.fallbackDownloadURL))
    }

    func testRejectsAnotherHost() {
        let url = URL(string: "https://example.com/downloads/BlackHole16ch-0.7.1.pkg")!
        XCTAssertThrowsError(try BlackHoleInstaller.validate(url)) { error in
            XCTAssertEqual(
                error as? BlackHoleInstaller.InstallerError,
                .untrustedDownloadURL("example.com")
            )
        }
    }

    func testRejectsPlainHTTP() {
        let url = URL(string: "http://existential.audio/downloads/BlackHole16ch-0.7.1.pkg")!
        XCTAssertThrowsError(try BlackHoleInstaller.validate(url))
    }

    func testRejectsLookalikeHost() {
        let url = URL(string: "https://existential.audio.evil.test/BlackHole16ch-0.7.1.pkg")!
        XCTAssertThrowsError(try BlackHoleInstaller.validate(url))
    }
}
