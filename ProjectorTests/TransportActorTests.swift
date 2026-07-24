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

@MainActor
final class TransportActorTests: XCTestCase {

    private actor StubMIDISyncService: MIDISyncServiceProtocol {
        nonisolated var syncStateStream: AsyncStream<MIDISyncState> { AsyncStream { _ in } }
        nonisolated var mtcUpdateStream: AsyncStream<MTCUpdate> { AsyncStream { _ in } }
        nonisolated var mmcCommandStream: AsyncStream<MMCCommandEvent> { AsyncStream { _ in } }
        func selectInput(_ name: String?) async {}
        func refreshAvailableInputs() async {}
        func setLocalFrameRate(_ frameRate: TimecodeFrameRate) async {}
        func updateLocalPlaybackFrame(_ frame: Int) async {}
    }

    // MARK: - Protocol Existence Tests

    /// Verify that MIDISyncServiceProtocol exists and defines expected methods
    func testMIDISyncServiceProtocolExists() {
        // This test verifies the protocol shape at compile time
        // If the protocol changes, this test will fail to compile

        func useProtocol<T: MIDISyncServiceProtocol>(_ service: T) async {
            // Verify protocol methods exist
            _ = service.syncStateStream
            _ = service.mtcUpdateStream
            _ = service.mmcCommandStream
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

    func testSeekToTimecodeRespectsNonZeroTimelineStart() async {
        let frameRate = TimecodeFrameRate.fps24
        let start = Timecode(.components(h: 1, m: 0, s: 0, f: 0), at: frameRate, by: .clamping)
        let end = Timecode(.components(h: 1, m: 1, s: 0, f: 0), at: frameRate, by: .clamping)
        let timeline = Timeline(config: TimelineConfig(
            startTimecode: start,
            endTimecode: end,
            frameRate: frameRate
        ))
        let manager = TimelineManager(timeline: timeline)
        let engine = PlaybackEngine(timeline: timeline)
        let transport = TransportActor(
            playbackEngine: engine,
            timelineActor: TimelineActor(timelineManager: manager),
            midiSyncService: StubMIDISyncService()
        )

        await transport.seekToTimecode(timeline.config.timecode(at: 240))

        XCTAssertEqual(engine.currentFrame, 240)
        XCTAssertEqual(engine.currentTimecode, timeline.config.timecode(at: 240))
    }
}
