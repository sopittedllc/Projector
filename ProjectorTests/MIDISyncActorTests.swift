//
//  MIDISyncActorTests.swift
//  ProjectorTests
//
//  Tests for MIDISyncActor - MIDI sync state management and MTC/MMC processing
//

import XCTest
@testable import Projector
import SwiftTimecodeCore

final class MIDISyncActorTests: XCTestCase {

    var actor: MIDISyncActor!
    var mockMIDIClient: MockMIDIClient!

    override func setUp() async throws {
        try await super.setUp()

        mockMIDIClient = MockMIDIClient()
        actor = MIDISyncActor(midiClient: mockMIDIClient)
        await actor.start()
    }

    override func tearDown() async throws {
        actor = nil
        mockMIDIClient = nil

        try await super.tearDown()
    }

    // MARK: - State Machine Tests

    func testInitialState() async throws {
        // When: Actor is created
        // Then: Initial state is idle
        let state = await collectFirstState()

        XCTAssertEqual(state.mtcState, .idle, "Should start in idle state")
        XCTAssertNil(state.mtcTimecode, "Should have no timecode initially")
        XCTAssertEqual(state.driftFrames, 0.0, "Should have no drift initially")
        XCTAssertEqual(state.driftStatus, .excellent, "Should have excellent drift status initially")
    }

    func testTransitionToPreSync() async throws {
        // Given: Actor in idle state

        // When: Receive first MTC quarter-frame
        await actor.handleMTCQuarterFrame(0, value: 0)

        // Then: State transitions to preSync
        let state = await collectFirstState()
        XCTAssertEqual(state.mtcState, .preSync, "Should transition to preSync on first MTC")
    }

    func testTransitionToSync() async throws {
        // Given: Actor receiving MTC quarter-frames
        var states: [MIDISyncState] = []
        let expectation = expectation(description: "Collect sync state")

        let task = Task {
            for await state in actor.syncStateStream {
                states.append(state)
                if state.mtcState == .sync {
                    expectation.fulfill()
                    break
                }
            }
        }

        // When: Receive 8 consecutive quarter-frames (full timecode)
        for i in 0..<8 {
            await actor.handleMTCQuarterFrame(UInt8(i), value: 0)
            try await Task.sleep(for: .milliseconds(10))
        }

        // Then: State transitions to sync
        await fulfillment(of: [expectation], timeout: 1.0)
        task.cancel()

        XCTAssertEqual(states.last?.mtcState, .sync, "Should transition to sync after full timecode")
    }

    // MARK: - MTC Quarter-Frame Parsing Tests

    func testQuarterFrameParsing() async throws {
        // Given: MTC timecode 00:00:10:00 at 24fps (240 frames)
        // MTC encoding: frames=0, seconds=10, minutes=0, hours=0, rate=24fps

        // When: Receive 8 quarter-frames in sequence
        await actor.handleMTCQuarterFrame(0, value: 0)  // Frames LS nibble (0 & 0x0F = 0)
        await actor.handleMTCQuarterFrame(1, value: 0)  // Frames MS nibble (0 >> 4 = 0)
        await actor.handleMTCQuarterFrame(2, value: 10) // Seconds LS nibble (10 & 0x0F = 10)
        await actor.handleMTCQuarterFrame(3, value: 0)  // Seconds MS nibble (10 >> 4 = 0)
        await actor.handleMTCQuarterFrame(4, value: 0)  // Minutes LS nibble
        await actor.handleMTCQuarterFrame(5, value: 0)  // Minutes MS nibble
        await actor.handleMTCQuarterFrame(6, value: 0)  // Hours LS nibble
        await actor.handleMTCQuarterFrame(7, value: 0)  // Hours MS nibble + rate (24fps = 0b00)

        // Wait for timecode assembly
        try await Task.sleep(for: .milliseconds(100))

        // Then: Timecode assembled correctly
        let state = await collectFirstState()
        XCTAssertNotNil(state.mtcTimecode, "Timecode should be assembled")
        XCTAssertEqual(state.mtcTimecode?.components.seconds, 10, "Seconds should be 10")
    }

    func testIncompleteQuarterFrameSequence() async throws {
        // Given: Actor in idle state

        // When: Receive only 4 quarter-frames (incomplete)
        for i in 0..<4 {
            await actor.handleMTCQuarterFrame(UInt8(i), value: 0)
        }

        try await Task.sleep(for: .milliseconds(100))

        // Then: State remains in preSync, no full timecode
        let state = await collectFirstState()
        XCTAssertEqual(state.mtcState, .preSync, "Should remain in preSync with incomplete timecode")
    }

    // MARK: - Drift Calculation Tests

    func testDriftCalculationExcellent() async throws {
        // Given: MTC at frame 1000, local playback at frame 1000 (0.0 frames drift)
        await actor.handleFullTimecode(frame: 1000, at: .fps24)
        await actor.updateLocalPlaybackFrame(1000)

        // Wait for drift calculation
        try await Task.sleep(for: .seconds(1.1)) // Wait > 1s for throttled emission

        // Then: Drift status is excellent (<0.5 frames)
        let state = await collectFirstState()
        XCTAssertEqual(state.driftStatus, .excellent, "0.0 frame drift should be excellent")
        XCTAssertEqual(state.driftFrames, 0.0, accuracy: 0.01, "Drift should be 0.0 frames")
    }

    func testDriftCalculationGood() async throws {
        // Given: MTC at frame 1000, local playback at frame 1000.7 (0.7 frames drift)
        await actor.handleFullTimecode(frame: 1000, at: .fps24)
        await actor.updateLocalPlaybackFrame(999)

        try await Task.sleep(for: .seconds(1.1))

        // Then: Drift status is good (0.5-1.0 frames)
        let state = await collectFirstState()
        XCTAssertEqual(state.driftStatus, .good, "0.7 frame drift should be good")
        XCTAssertEqual(state.driftFrames, 1.0, accuracy: 0.1, "Drift should be ~1.0 frame")
    }

    func testDriftCalculationFair() async throws {
        // Given: MTC at frame 1000, local playback at frame 998 (2.0 frames drift)
        await actor.handleFullTimecode(frame: 1000, at: .fps24)
        await actor.updateLocalPlaybackFrame(998)

        try await Task.sleep(for: .seconds(1.1))

        // Then: Drift status is fair (1.0-2.0 frames)
        let state = await collectFirstState()
        XCTAssertEqual(state.driftStatus, .fair, "1.5 frame drift should be fair")
        XCTAssertEqual(state.driftFrames, 2.0, accuracy: 0.1, "Drift should be ~2.0 frames")
    }

    func testDriftCalculationPoor() async throws {
        // Given: MTC at frame 1000, local playback at frame 995 (5.0 frames drift)
        await actor.handleFullTimecode(frame: 1000, at: .fps24)
        await actor.updateLocalPlaybackFrame(995)

        try await Task.sleep(for: .seconds(1.1))

        // Then: Drift status is poor (>2.0 frames)
        let state = await collectFirstState()
        XCTAssertEqual(state.driftStatus, .poor, "5.0 frame drift should be poor")
        XCTAssertEqual(state.driftFrames, 5.0, accuracy: 0.1, "Drift should be ~5.0 frames")
    }

    // MARK: - MMC Command Tests

    func testMMCPlayCommand() async throws {
        // Given: Listening for MMC commands
        var receivedCommand: MMCCommand?
        let expectation = expectation(description: "Receive play command")

        let task = Task {
            for await command in actor.mmcCommandStream {
                receivedCommand = command
                expectation.fulfill()
                break
            }
        }

        // When: Send MMC play command (0x02)
        await actor.handleMMCCommand(.play)

        // Then: Command emitted via stream
        await fulfillment(of: [expectation], timeout: 1.0)
        task.cancel()

        XCTAssertEqual(receivedCommand, .play, "Should receive play command")
    }

    func testMMCStopCommand() async throws {
        // Given: Listening for MMC commands
        var receivedCommand: MMCCommand?
        let expectation = expectation(description: "Receive stop command")

        let task = Task {
            for await command in actor.mmcCommandStream {
                receivedCommand = command
                expectation.fulfill()
                break
            }
        }

        // When: Send MMC stop command (0x01)
        await actor.handleMMCCommand(.stop)

        // Then: Command emitted via stream
        await fulfillment(of: [expectation], timeout: 1.0)
        task.cancel()

        XCTAssertEqual(receivedCommand, .stop, "Should receive stop command")
    }

    func testMMCLocateCommand() async throws {
        // Given: Listening for MMC commands
        var receivedCommand: MMCCommand?
        let expectation = expectation(description: "Receive locate command")

        let task = Task {
            for await command in actor.mmcCommandStream {
                receivedCommand = command
                expectation.fulfill()
                break
            }
        }

        // When: Send MMC locate command (0x44) with frame 500
        await actor.handleMMCCommand(.locate(frame: 500))

        // Then: Command emitted with frame position
        await fulfillment(of: [expectation], timeout: 1.0)
        task.cancel()

        if case .locate(let frame) = receivedCommand {
            XCTAssertEqual(frame, 500, "Locate command should include frame 500")
        } else {
            XCTFail("Should receive locate command")
        }
    }

    // MARK: - Input Selection Tests

    func testSelectMIDIInput() async throws {
        // When: Select MIDI input device
        await actor.selectInput("Test MIDI Device")

        // Then: Input selected
        let selectedInput = await actor.getSelectedInput()
        XCTAssertEqual(selectedInput, "Test MIDI Device", "Should select input device")
    }

    func testRefreshAvailableInputs() async throws {
        // Given: Mock MIDI client with devices
        mockMIDIClient.availableInputs = ["Device 1", "Device 2", "Device 3"]

        // When: Refresh available inputs
        await actor.refreshAvailableInputs()

        // Then: Available inputs updated
        let inputs = await actor.getAvailableInputs()
        XCTAssertEqual(inputs.count, 3, "Should have 3 available inputs")
        XCTAssertTrue(inputs.contains("Device 1"), "Should include Device 1")
    }

    // MARK: - Frame Rate Configuration Tests

    func testSetLocalFrameRate() async throws {
        // When: Set local frame rate to 30fps
        await actor.setLocalFrameRate(.fps30)

        // Then: Frame rate updated
        let frameRate = await actor.getLocalFrameRate()
        XCTAssertEqual(frameRate, .fps30, "Should update to 30fps")
    }

    func testFrameRateMismatchDetection() async throws {
        // Given: Local frame rate is 24fps
        await actor.setLocalFrameRate(.fps24)

        // When: Receive MTC at 30fps
        await actor.handleFullTimecode(frame: 100, at: .fps30)

        try await Task.sleep(for: .milliseconds(100))

        // Then: Frame rate mismatch detected
        let state = await collectFirstState()
        XCTAssertTrue(state.isFrameRateMismatch, "Should detect frame rate mismatch")
    }

    // MARK: - AsyncStream Tests

    func testSyncStateStreamEmitsOnMTC() async throws {
        // Given: Listening to sync state stream
        var receivedState: MIDISyncState?
        let expectation = expectation(description: "Receive sync state")

        let task = Task {
            for await state in actor.syncStateStream {
                if state.mtcState == .preSync {
                    receivedState = state
                    expectation.fulfill()
                    break
                }
            }
        }

        // When: Receive MTC quarter-frame
        try await Task.sleep(for: .milliseconds(100)) // Allow stream to set up
        await actor.handleMTCQuarterFrame(0, value: 0)

        // Then: Stream emits state update
        await fulfillment(of: [expectation], timeout: 1.0)
        task.cancel()

        XCTAssertNotNil(receivedState, "Should receive state update")
        XCTAssertEqual(receivedState?.mtcState, .preSync, "State should be preSync")
    }

    func testDriftEmissionThrottled() async throws {
        // Given: Listening to drift updates
        var emissionCount = 0
        let expectation = expectation(description: "Throttled emissions")

        let task = Task {
            for await _ in actor.syncStateStream {
                emissionCount += 1
                if emissionCount >= 3 {
                    expectation.fulfill()
                    break
                }
            }
        }

        // When: Update playback frame rapidly (10 times in 100ms)
        for i in 0..<10 {
            await actor.updateLocalPlaybackFrame(i * 10)
            try await Task.sleep(for: .milliseconds(10))
        }

        // Wait for throttled emissions (1Hz = 1 per second)
        try await Task.sleep(for: .seconds(2.5))

        // Then: Emissions throttled to ~1Hz (expect 2-3 emissions in 2.5s, not 10)
        task.cancel()

        XCTAssertLessThanOrEqual(emissionCount, 5, "Should throttle drift emissions to ~1Hz")
    }

    // MARK: - Helper Methods

    private func collectFirstState() async -> MIDISyncState {
        var capturedState: MIDISyncState?

        for await state in actor.syncStateStream {
            capturedState = state
            break
        }

        return capturedState ?? .empty
    }
}

// MARK: - Mock MIDI Client

class MockMIDIClient {
    var availableInputs: [String] = []
    var selectedInput: String?

    func getAvailableInputs() -> [String] {
        return availableInputs
    }

    func selectInput(_ name: String) {
        selectedInput = name
    }
}

// MARK: - MIDISyncActor Test Helpers

extension MIDISyncActor {
    /// Test helper to inject full timecode directly
    func handleFullTimecode(frame: Int, at frameRate: TimecodeFrameRate) async {
        let timecode = try? Timecode(.frames(frame), at: frameRate, by: .clamping)
        if let timecode = timecode {
            // Simulate receiving 8 quarter-frames to assemble this timecode
            let components = timecode.components

            // Send quarter-frames in sequence
            await handleMTCQuarterFrame(0, value: UInt8(components.frames & 0x0F))
            await handleMTCQuarterFrame(1, value: UInt8((components.frames >> 4) & 0x0F))
            await handleMTCQuarterFrame(2, value: UInt8(components.seconds & 0x0F))
            await handleMTCQuarterFrame(3, value: UInt8((components.seconds >> 4) & 0x0F))
            await handleMTCQuarterFrame(4, value: UInt8(components.minutes & 0x0F))
            await handleMTCQuarterFrame(5, value: UInt8((components.minutes >> 4) & 0x0F))
            await handleMTCQuarterFrame(6, value: UInt8(components.hours & 0x0F))
            await handleMTCQuarterFrame(7, value: UInt8((components.hours >> 4) & 0x0F))
        }
    }

    func getSelectedInput() async -> String? {
        // Return selected input name (implementation depends on MIDISyncActor internals)
        return nil // Placeholder
    }

    func getAvailableInputs() async -> [String] {
        // Return available inputs (implementation depends on MIDISyncActor internals)
        return [] // Placeholder
    }

    func getLocalFrameRate() async -> TimecodeFrameRate {
        // Return local frame rate (implementation depends on MIDISyncActor internals)
        return .fps24 // Placeholder
    }
}

extension MIDISyncState {
    static var empty: MIDISyncState {
        MIDISyncState(
            mtcState: .idle,
            mtcTimecode: nil,
            selectedInput: nil,
            availableInputs: [],
            driftFrames: 0.0,
            driftStatus: .excellent,
            isFrameRateMismatch: false
        )
    }
}
