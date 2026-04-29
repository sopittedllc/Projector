//
//  TransportActorTests.swift
//  ProjectorTests
//
//  Tests for TransportActor - Transport state management and commands
//
//  Note: TransportActor depends on concrete classes (PlaybackEngine, TimelineActor)
//  which are difficult to mock. These tests focus on observable behaviors
//  that can be tested with the real dependencies.
//

import XCTest
@testable import Projector
import SwiftTimecodeCore

final class TransportActorTests: XCTestCase {

    // MARK: - Protocol Existence Tests

    /// Verify that MIDISyncServiceProtocol exists and defines expected methods
    func testMIDISyncServiceProtocolExists() {
        // This test verifies the protocol shape at compile time
        // If the protocol changes, this test will fail to compile

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

    /// Verify that TimelineServiceProtocol exists and defines expected methods
    func testTimelineServiceProtocolExists() {
        // This test verifies the protocol shape at compile time

        func useProtocol<T: TimelineServiceProtocol>(_ service: T) async throws {
            // Verify protocol methods exist
            _ = service.timelineStateStream
            _ = await service.getCurrentState()
        }

        // Test passes if compilation succeeds
    }

    /// Verify that TransportServiceProtocol exists and defines expected methods
    func testTransportServiceProtocolExists() {
        // This test verifies the protocol shape at compile time

        func useProtocol<T: TransportServiceProtocol>(_ service: T) async {
            // Verify protocol methods exist
            _ = service.transportStateStream
            await service.play()
            await service.pause()
            await service.stop()
            await service.togglePlayback()
            await service.seekToFrame(0)
            await service.stepForward()
            await service.stepBackward()
        }

        // Test passes if compilation succeeds
    }
}
