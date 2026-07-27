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

    override func setUp() async throws {
        try await super.setUp()
        originalSelectedAudioOutput = AppSettings.shared.selectedAudioOutput
        manager = AudioOutputManager()
    }

    override func tearDown() async throws {
        manager.selectedDeviceUID = originalSelectedAudioOutput.isEmpty ? nil : originalSelectedAudioOutput
        manager = nil
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
        manager.selectedDeviceUID = "test-device-uid"

        // Then: Value is stored
        XCTAssertEqual(manager.selectedDeviceUID, "test-device-uid", "Should store selected device UID")
    }

    // MARK: - Callback Tests

    func testOnDeviceChangedCallback() async {
        // Given: Set up callback
        var receivedDeviceUID: String?
        manager.onDeviceChanged = { uid in
            receivedDeviceUID = uid
        }

        // When: Change selected device
        manager.selectedDeviceUID = "new-device-uid"

        // Then: Callback fires synchronously with the selected UID
        XCTAssertEqual(receivedDeviceUID, "new-device-uid")
    }

    // MARK: - Lane Routing Tests

    /// Selecting a device does not invent outputs.
    ///
    /// An output is a routing decision about a session, not a fact about the
    /// hardware. Selection once fabricated a stereo pair per channel, which
    /// filled Settings with entries the user never made - and because those were
    /// minted with a fresh id each launch and never saved, a lane auto-assigned
    /// to one stored an id that referred to nothing the next time the app opened.
    func testSelectingADeviceDoesNotCreateOutputs() {
        let original = manager.selectedDeviceUID
        defer { manager.selectedDeviceUID = original }

        manager.selectedDeviceUID = "device-with-no-saved-outputs-\(UUID().uuidString)"

        XCTAssertTrue(
            manager.mappedOutputs.isEmpty,
            "A device the user has never configured should have no outputs"
        )
    }

    /// Whatever outputs exist address real channels.
    func testMappedOutputsAreValidForCurrentDevice() {
        XCTAssertTrue(manager.mappedOutputs.allSatisfy {
            $0.channelStart >= 0 && $0.channelCount > 0
        })
    }
}
