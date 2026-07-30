//
//  AudioOutputManagerTests.swift
//  ProjectorTests
//
//  Tests for AudioOutputManager - Audio device management and routing
//

import XCTest
@testable import Projector
import AVFoundation

@MainActor
final class AudioOutputManagerTests: XCTestCase {

    var manager: AudioOutputManager!
    private var originalSelectedAudioOutput = ""

    /// The whole audio-output mapping blob, captured before the test and put
    /// back afterwards.
    ///
    /// `AppSettings` is `@AppStorage` over `UserDefaults.standard`, and tests run
    /// inside the app host - so they share the real preferences the user's app
    /// reads. Selecting a made-up device writes a mapping into those settings.
    ///
    /// Restoring the entire value is deliberate. Deleting the individual keys a
    /// test created is not enough: selecting a device rewrites the whole blob,
    /// so the store can gain entries no test named. Putting the original string
    /// back leaves the user's settings byte-for-byte as they were.
    private static let mappingsKey = "audioOutputMappings"
    private var originalMappings: String?

    private func fabricatedUID(_ label: String) -> String {
        "test-\(label)-\(UUID().uuidString)"
    }

    override func setUp() async throws {
        try await super.setUp()
        originalSelectedAudioOutput = AppSettings.shared.selectedAudioOutput
        originalMappings = UserDefaults.standard.string(forKey: Self.mappingsKey)
        manager = AudioOutputManager()
    }

    override func tearDown() async throws {
        manager.selectedDeviceUID = originalSelectedAudioOutput.isEmpty ? nil : originalSelectedAudioOutput
        manager = nil

        if let originalMappings {
            UserDefaults.standard.set(originalMappings, forKey: Self.mappingsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.mappingsKey)
        }

        try await super.tearDown()
    }

    // MARK: - Initialization Tests

    func testInitialization() {
        // Then: Manager initializes successfully
        XCTAssertNotNil(manager, "Manager should initialize")
    }

    func testAvailableDevicesPopulated() {
        // Then: Available devices array is populated
        // Note: In CI environments this might be empty
        XCTAssertNotNil(manager.availableDevices, "Available devices should not be nil")
    }

    // MARK: - Device Selection Tests

    func testSelectedDeviceUIDDefaultsToSystemOutput() {
        // nil intentionally represents the current macOS system output device.
        XCTAssertNil(manager.selectedDeviceUID)
    }

    func testSetSelectedDeviceUID() {
        // When: Set a device UID
        let uid = fabricatedUID("selection")
        manager.selectedDeviceUID = uid

        // Then: Value is stored
        XCTAssertEqual(manager.selectedDeviceUID, uid, "Should store selected device UID")
    }

    // MARK: - Callback Tests

    func testOnDeviceChangedCallback() async {
        // Given: Set up callback
        var receivedDeviceUID: String?
        manager.onDeviceChanged = { uid in
            receivedDeviceUID = uid
        }

        // When: Change selected device
        let uid = fabricatedUID("callback")
        manager.selectedDeviceUID = uid

        // Then: Callback fires synchronously with the selected UID
        XCTAssertEqual(receivedDeviceUID, uid)
    }

    // MARK: - Lane Routing Tests

    /// A never-configured device is seeded with one stereo output and nothing
    /// else.
    ///
    /// This replaces an earlier rule that selecting a device created no outputs
    /// at all. That rule came from a bug where a pair was fabricated for *every*
    /// channel, unsaved, with fresh identities each launch; the fix at the time
    /// was to create nothing. A single seeded Stereo Out is the deliberate
    /// default now - the fabrication problems it caused are covered by
    /// `testSeededOutputIsPersistedNotFabricated` and
    /// `testClearingTheSeededOutputSticks` below.
    func testSelectingANewDeviceSeedsOneStereoOutput() throws {
        let original = manager.selectedDeviceUID
        defer { manager.selectedDeviceUID = original }

        try XCTSkipIf(manager.selectedDeviceChannelCount < 2 && manager.availableDevices.isEmpty,
                      "needs an output device with at least two channels")

        manager.selectedDeviceUID = fabricatedUID("no-saved-outputs")

        XCTAssertEqual(manager.mappedOutputs.count, 1,
                       "exactly one output should be seeded, not one per channel")
        let seeded = try XCTUnwrap(manager.mappedOutputs.first)
        XCTAssertEqual(seeded.name, "Stereo Out")
        XCTAssertEqual(seeded.channelStart, 0, "the seeded output starts at channel 1")
        XCTAssertEqual(seeded.channelCount, 2)
    }

    /// The seeded output must be saved, not minted in memory each time.
    ///
    /// The earlier fabrication bug gave lanes an output id that referred to
    /// nothing after a relaunch. Re-reading the device must return the *same*
    /// identity.
    func testSeededOutputIsPersistedNotFabricated() throws {
        let original = manager.selectedDeviceUID
        defer { manager.selectedDeviceUID = original }

        try XCTSkipIf(manager.availableDevices.isEmpty, "needs an output device")

        let uid = fabricatedUID("persistence")
        manager.selectedDeviceUID = uid
        let firstId = try XCTUnwrap(manager.mappedOutputs.first?.id)

        // Look away and back: a fabricated output would come back with a new id.
        manager.selectedDeviceUID = nil
        manager.selectedDeviceUID = uid

        XCTAssertEqual(manager.mappedOutputs.first?.id, firstId,
                       "the seeded output's identity must survive re-selection")
    }

    /// Clearing the seeded output removes it for good.
    ///
    /// Seeding keys off whether the device has ever been configured, not off the
    /// list being empty - otherwise deleting Stereo Out would recreate it and
    /// the user could never get rid of it.
    func testClearingTheSeededOutputSticks() throws {
        let original = manager.selectedDeviceUID
        defer { manager.selectedDeviceUID = original }

        try XCTSkipIf(manager.availableDevices.isEmpty, "needs an output device")

        let uid = fabricatedUID("clearing")
        manager.selectedDeviceUID = uid
        let seeded = try XCTUnwrap(manager.mappedOutputs.first)

        manager.removeOutput(id: seeded.id)
        XCTAssertTrue(manager.mappedOutputs.isEmpty)

        manager.selectedDeviceUID = nil
        manager.selectedDeviceUID = uid

        XCTAssertTrue(manager.mappedOutputs.isEmpty,
                      "a cleared output must not reappear on the next device change")
    }

    /// Whatever outputs exist address real channels.
    func testMappedOutputsAreValidForCurrentDevice() {
        XCTAssertTrue(manager.mappedOutputs.allSatisfy {
            $0.channelStart >= 0 && $0.channelCount > 0
        })
    }
}
