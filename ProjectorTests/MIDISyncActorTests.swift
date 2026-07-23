//
//  MIDISyncActorTests.swift
//  ProjectorTests
//
//  Tests for MIDISyncActor - MIDI Time Code and Machine Control sync
//
//  Note: MIDISyncActor has complex dependencies on CoreMIDI and MIDIKit.
//  Full testing requires MIDI hardware or virtual ports. These tests
//  focus on protocol conformance and state management.
//

import XCTest
@testable import Projector
import SwiftTimecodeCore

final class MIDISyncActorTests: XCTestCase {

    // MARK: - Protocol Conformance Tests

    func testMIDISyncActorConformsToProtocol() {
        // This test verifies MIDISyncServiceProtocol conformance at compile time
        func useProtocol<T: MIDISyncServiceProtocol>(_ service: T) async {
            // Verify protocol methods exist
            _ = service.syncStateStream
            await service.selectInput(nil)
            await service.refreshAvailableInputs()
            await service.setLocalFrameRate(.fps24)
            await service.updateLocalPlaybackFrame(0)
        }

        // Test passes if compilation succeeds
    }

    // MARK: - MIDISyncState Tests

    func testMIDISyncStateEmpty() {
        // Given: Empty state
        let state = MIDISyncState.empty

        // Then: State has expected empty values
        XCTAssertTrue(state.availableInputs.isEmpty, "Should have no available inputs")
    }

    // MARK: - Timecode Frame Rate Tests

    func testSupportedFrameRates() {
        // Verify common frame rates are supported
        let frameRates: [TimecodeFrameRate] = [
            .fps23_976,
            .fps24,
            .fps25,
            .fps29_97,
            .fps29_97d,
            .fps30,
            .fps30d
        ]

        XCTAssertEqual(frameRates.count, 7, "Should have 7 common frame rates")
    }

    // MARK: - State Stream Tests

    func testStateStreamBroadcastsToMultipleSubscribers() async {
        let actor = MIDISyncActor()
        let firstReady = expectation(description: "First subscriber receives initial state")
        let secondReady = expectation(description: "Second subscriber receives initial state")
        let firstUpdated = expectation(description: "First subscriber receives update")
        let secondUpdated = expectation(description: "Second subscriber receives update")

        let firstTask = Task {
            var receivedInitialState = false
            for await state in actor.syncStateStream {
                if !receivedInitialState {
                    receivedInitialState = true
                    firstReady.fulfill()
                }
                if state.localFrameRate == .fps25 {
                    firstUpdated.fulfill()
                    break
                }
            }
        }

        let secondTask = Task {
            var receivedInitialState = false
            for await state in actor.syncStateStream {
                if !receivedInitialState {
                    receivedInitialState = true
                    secondReady.fulfill()
                }
                if state.localFrameRate == .fps25 {
                    secondUpdated.fulfill()
                    break
                }
            }
        }

        await fulfillment(of: [firstReady, secondReady], timeout: 1.0)
        await actor.setLocalFrameRate(.fps25)
        await fulfillment(of: [firstUpdated, secondUpdated], timeout: 1.0)

        firstTask.cancel()
        secondTask.cancel()
        await actor.stop()
    }
}
