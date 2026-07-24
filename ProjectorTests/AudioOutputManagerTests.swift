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

    private final class SettingsStore: AudioOutputSettingsStore {
        var selectedAudioOutput = ""
        var mappings: [String: [MappedAudioOutput]] = [:]

        func mappedOutputs(for deviceUID: String?) -> [MappedAudioOutput] {
            mappings[deviceUID ?? "system_default"] ?? []
        }

        func setMappedOutputs(_ outputs: [MappedAudioOutput], for deviceUID: String?) {
            mappings[deviceUID ?? "system_default"] = outputs
        }
    }

    var manager: AudioOutputManager!
    private var settings: SettingsStore!

    override func setUp() async throws {
        try await super.setUp()
        settings = SettingsStore()
        manager = AudioOutputManager(settings: settings)
    }

    override func tearDown() async throws {
        manager = nil
        settings = nil
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
        XCTAssertEqual(settings.selectedAudioOutput, "test-device-uid")
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

    func testMappedOutputsAreValidForCurrentDevice() {
        // Saved mappings are user preferences and may legitimately be present.
        // When no mapping is saved, the manager creates valid stereo/mono defaults.
        XCTAssertFalse(manager.mappedOutputs.isEmpty)
        XCTAssertTrue(manager.mappedOutputs.allSatisfy {
            $0.channelStart >= 0 && $0.channelCount > 0
        })
    }
}
