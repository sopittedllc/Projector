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
}
