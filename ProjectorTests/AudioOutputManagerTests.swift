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
    var mockAudioEngine: MockAudioEngine!

    override func setUp() async throws {
        try await super.setUp()

        mockAudioEngine = MockAudioEngine()
        manager = AudioOutputManager(audioEngine: mockAudioEngine)
    }

    override func tearDown() async throws {
        manager = nil
        mockAudioEngine = nil

        try await super.tearDown()
    }

    // MARK: - Device Enumeration Tests

    func testGetAvailableOutputDevices() {
        // When: Enumerate devices
        let devices = manager.getAvailableOutputDevices()

        // Then: Devices returned (at minimum, built-in output)
        XCTAssertGreaterThanOrEqual(devices.count, 1, "Should have at least built-in output")
        XCTAssertTrue(devices.contains(where: { $0.name == "Built-in Output" }), "Should include built-in output")
    }

    func testDeviceChannelCounts() {
        // When: Get device channel counts
        let devices = manager.getAvailableOutputDevices()

        // Then: Built-in device has 2 channels (stereo)
        let builtIn = devices.first(where: { $0.name == "Built-in Output" })
        XCTAssertNotNil(builtIn, "Should find built-in device")
        XCTAssertEqual(builtIn?.channelCount, 2, "Built-in should have 2 channels")
    }

    // MARK: - Device Selection Tests

    func testSelectOutputDevice() {
        // Given: Available devices
        let devices = manager.getAvailableOutputDevices()
        let device = devices.first!

        // When: Select device
        manager.selectOutputDevice(device.uid)

        // Then: Device selected
        XCTAssertEqual(manager.currentOutputDevice?.uid, device.uid, "Should select device")
    }

    func testSelectNonexistentDeviceFallsBack() {
        // When: Select invalid device UID
        manager.selectOutputDevice("invalid-device-uid")

        // Then: Falls back to built-in
        XCTAssertEqual(manager.currentOutputDevice?.name, "Built-in Output", "Should fall back to built-in")
    }

    // MARK: - Routing Configuration Tests

    func testMapLaneToStereoOutput() {
        // Given: Lane ID and stereo output (channels 0-1)
        let laneId = UUID()

        // When: Map lane to outputs 0-1
        manager.setLaneOutputMapping(laneId: laneId, outputChannels: [0, 1])

        // Then: Mapping stored
        let mapping = manager.getLaneOutputMapping(laneId: laneId)
        XCTAssertEqual(mapping, [0, 1], "Should map to channels 0-1")
    }

    func testMapLaneToCustomChannels() {
        // Given: Lane ID
        let laneId = UUID()

        // When: Map to outputs 4-5
        manager.setLaneOutputMapping(laneId: laneId, outputChannels: [4, 5])

        // Then: Mapping stored
        let mapping = manager.getLaneOutputMapping(laneId: laneId)
        XCTAssertEqual(mapping, [4, 5], "Should map to channels 4-5")
    }

    func testMapMonoLaneToSingleChannel() {
        // Given: Mono lane
        let laneId = UUID()

        // When: Map to single channel (2)
        manager.setLaneOutputMapping(laneId: laneId, outputChannels: [2])

        // Then: Mapping stored
        let mapping = manager.getLaneOutputMapping(laneId: laneId)
        XCTAssertEqual(mapping, [2], "Should map to channel 2")
    }

    // MARK: - Mute/Solo Matrix Tests

    func testMuteMatrix() {
        // Given: 3 lanes, lane 2 is muted
        let lane1 = UUID()
        let lane2 = UUID()
        let lane3 = UUID()

        manager.setLaneMuted(laneId: lane2, muted: true)

        // When: Calculate mute matrix
        let matrix = manager.calculateMuteMatrix(lanes: [lane1, lane2, lane3])

        // Then: Lane 2 muted, others not muted
        XCTAssertFalse(matrix[lane1] ?? false, "Lane 1 should not be muted")
        XCTAssertTrue(matrix[lane2] ?? false, "Lane 2 should be muted")
        XCTAssertFalse(matrix[lane3] ?? false, "Lane 3 should not be muted")
    }

    func testSoloMatrix() {
        // Given: 3 lanes, lane 2 is soloed
        let lane1 = UUID()
        let lane2 = UUID()
        let lane3 = UUID()

        manager.setLaneSolo(laneId: lane2, solo: true)

        // When: Calculate solo matrix
        let matrix = manager.calculateSoloMatrix(lanes: [lane1, lane2, lane3])

        // Then: Only lane 2 is playing (solo wins)
        let effectiveMute1 = manager.getEffectiveMute(laneId: lane1, soloMatrix: matrix)
        let effectiveMute2 = manager.getEffectiveMute(laneId: lane2, soloMatrix: matrix)
        let effectiveMute3 = manager.getEffectiveMute(laneId: lane3, soloMatrix: matrix)

        XCTAssertTrue(effectiveMute1, "Lane 1 should be effectively muted (not soloed)")
        XCTAssertFalse(effectiveMute2, "Lane 2 should not be muted (soloed)")
        XCTAssertTrue(effectiveMute3, "Lane 3 should be effectively muted (not soloed)")
    }

    func testMultipleSoloLanes() {
        // Given: 3 lanes, lanes 1 and 3 are soloed
        let lane1 = UUID()
        let lane2 = UUID()
        let lane3 = UUID()

        manager.setLaneSolo(laneId: lane1, solo: true)
        manager.setLaneSolo(laneId: lane3, solo: true)

        // When: Calculate solo matrix
        let matrix = manager.calculateSoloMatrix(lanes: [lane1, lane2, lane3])

        // Then: Lanes 1 and 3 play, lane 2 is muted
        let effectiveMute1 = manager.getEffectiveMute(laneId: lane1, soloMatrix: matrix)
        let effectiveMute2 = manager.getEffectiveMute(laneId: lane2, soloMatrix: matrix)
        let effectiveMute3 = manager.getEffectiveMute(laneId: lane3, soloMatrix: matrix)

        XCTAssertFalse(effectiveMute1, "Lane 1 should play (soloed)")
        XCTAssertTrue(effectiveMute2, "Lane 2 should be muted (not soloed)")
        XCTAssertFalse(effectiveMute3, "Lane 3 should play (soloed)")
    }

    // MARK: - Volume Control Tests

    func testSetLaneVolume() {
        // Given: Lane ID
        let laneId = UUID()

        // When: Set volume to 75%
        manager.setLaneVolume(laneId: laneId, volume: 0.75)

        // Then: Volume stored
        let volume = manager.getLaneVolume(laneId: laneId)
        XCTAssertEqual(volume, 0.75, accuracy: 0.01, "Volume should be 75%")
    }

    func testVolumeClampingAtZero() {
        // Given: Lane ID
        let laneId = UUID()

        // When: Set negative volume
        manager.setLaneVolume(laneId: laneId, volume: -0.5)

        // Then: Clamped to 0
        let volume = manager.getLaneVolume(laneId: laneId)
        XCTAssertEqual(volume, 0.0, accuracy: 0.01, "Volume should be clamped to 0")
    }

    func testVolumeClampingAtOne() {
        // Given: Lane ID
        let laneId = UUID()

        // When: Set volume >100%
        manager.setLaneVolume(laneId: laneId, volume: 1.5)

        // Then: Clamped to 1.0
        let volume = manager.getLaneVolume(laneId: laneId)
        XCTAssertEqual(volume, 1.0, accuracy: 0.01, "Volume should be clamped to 1.0")
    }

    // MARK: - Channel Validation Tests

    func testValidateRoutingWithinDeviceChannels() {
        // Given: Device with 6 channels
        let device = AudioOutputDevice(uid: "test-device", name: "6-Channel Interface", channelCount: 6)
        manager.selectOutputDevice(device.uid)

        let laneId = UUID()

        // When: Map to outputs 4-5 (valid)
        let isValid = manager.validateRouting(laneId: laneId, outputChannels: [4, 5])

        // Then: Valid
        XCTAssertTrue(isValid, "Routing to channels 4-5 should be valid on 6-channel device")
    }

    func testRejectRoutingBeyondDeviceChannels() {
        // Given: Device with 2 channels (built-in)
        let device = AudioOutputDevice(uid: "built-in", name: "Built-in Output", channelCount: 2)
        manager.selectOutputDevice(device.uid)

        let laneId = UUID()

        // When: Map to outputs 4-5 (invalid)
        let isValid = manager.validateRouting(laneId: laneId, outputChannels: [4, 5])

        // Then: Invalid
        XCTAssertFalse(isValid, "Routing to channels 4-5 should be invalid on 2-channel device")
    }

    // MARK: - Device Change Notification Tests

    func testDeviceChangeNotification() async throws {
        // Given: Listening for device changes
        var receivedNotification = false
        let expectation = expectation(description: "Device change notification")

        let task = Task {
            for await _ in manager.deviceChangeNotifications {
                receivedNotification = true
                expectation.fulfill()
                break
            }
        }

        // When: Device change occurs (simulate)
        try await Task.sleep(for: .milliseconds(100))
        await manager.simulateDeviceChange()

        // Then: Notification received
        await fulfillment(of: [expectation], timeout: 1.0)
        task.cancel()

        XCTAssertTrue(receivedNotification, "Should receive device change notification")
    }

    // MARK: - Default Routing Tests

    func testDefaultRoutingAssignment() {
        // Given: 3 lanes without explicit routing
        let lane1 = UUID()
        let lane2 = UUID()
        let lane3 = UUID()

        // When: Get default routing
        let defaultRouting1 = manager.getDefaultRouting(for: lane1, laneIndex: 0)
        let defaultRouting2 = manager.getDefaultRouting(for: lane2, laneIndex: 1)
        let defaultRouting3 = manager.getDefaultRouting(for: lane3, laneIndex: 2)

        // Then: Sequential stereo pairs
        XCTAssertEqual(defaultRouting1, [0, 1], "Lane 1 → Outputs 1-2 (channels 0-1)")
        XCTAssertEqual(defaultRouting2, [2, 3], "Lane 2 → Outputs 3-4 (channels 2-3)")
        XCTAssertEqual(defaultRouting3, [4, 5], "Lane 3 → Outputs 5-6 (channels 4-5)")
    }
}

// MARK: - Mock Classes

class MockAudioEngine {
    var outputNode: AVAudioOutputNode {
        AVAudioOutputNode()
    }
}

// MARK: - AudioOutputManager Test Helpers

extension AudioOutputManager {
    func getAvailableOutputDevices() -> [AudioOutputDevice] {
        // Placeholder - return mock devices
        return [
            AudioOutputDevice(uid: "built-in", name: "Built-in Output", channelCount: 2)
        ]
    }

    func selectOutputDevice(_ uid: String) {
        // Placeholder
    }

    var currentOutputDevice: AudioOutputDevice? {
        // Placeholder
        return AudioOutputDevice(uid: "built-in", name: "Built-in Output", channelCount: 2)
    }

    func setLaneOutputMapping(laneId: UUID, outputChannels: [Int]) {
        // Placeholder
    }

    func getLaneOutputMapping(laneId: UUID) -> [Int] {
        // Placeholder
        return []
    }

    func setLaneMuted(laneId: UUID, muted: Bool) {
        // Placeholder
    }

    func setLaneSolo(laneId: UUID, solo: Bool) {
        // Placeholder
    }

    func calculateMuteMatrix(lanes: [UUID]) -> [UUID: Bool] {
        // Placeholder
        return [:]
    }

    func calculateSoloMatrix(lanes: [UUID]) -> [UUID: Bool] {
        // Placeholder
        return [:]
    }

    func getEffectiveMute(laneId: UUID, soloMatrix: [UUID: Bool]) -> Bool {
        // Placeholder - check if any lane is soloed and this lane is not in solo matrix
        let anySoloed = soloMatrix.values.contains(true)
        return anySoloed && (soloMatrix[laneId] != true)
    }

    func setLaneVolume(laneId: UUID, volume: Double) {
        // Placeholder
    }

    func getLaneVolume(laneId: UUID) -> Double {
        // Placeholder
        return 1.0
    }

    func validateRouting(laneId: UUID, outputChannels: [Int]) -> Bool {
        // Check if all channels are within device limits
        guard let device = currentOutputDevice else { return false }
        return outputChannels.allSatisfy { $0 < device.channelCount }
    }

    var deviceChangeNotifications: AsyncStream<Void> {
        AsyncStream { continuation in
            // Placeholder
            continuation.finish()
        }
    }

    func simulateDeviceChange() async {
        // Placeholder for testing
    }

    func getDefaultRouting(for laneId: UUID, laneIndex: Int) -> [Int] {
        // Default: sequential stereo pairs
        let baseChannel = laneIndex * 2
        return [baseChannel, baseChannel + 1]
    }
}

struct AudioOutputDevice {
    let uid: String
    let name: String
    let channelCount: Int
}
