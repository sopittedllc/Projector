//
//  PlaybackEngineTests.swift
//  ProjectorTests
//
//  Tests for PlaybackEngine - Video/audio playback control
//
//  Note: PlaybackEngine has complex dependencies on AVFoundation
//  and requires actual media files. These tests focus on verifying
//  public API and observable behaviors.
//

import XCTest
import AppKit
import SwiftUI
import AVFoundation
@testable import Projector
import SwiftTimecodeCore

@MainActor
final class PlaybackEngineTests: XCTestCase {

    // MARK: - Initialization Tests

    func testPlaybackEngineInitialization() {
        // Given: Empty timeline
        let timeline = Timeline.empty

        // When: Create playback engine
        let engine = PlaybackEngine(timeline: timeline)

        // Then: Engine initializes with correct defaults
        XCTAssertNotNil(engine)
        XCTAssertFalse(engine.isPlaying, "Should not be playing initially")
    }

    func testPlaybackEngineTimeline() {
        // Given: Timeline
        let timeline = Timeline.empty

        // When: Create engine and check timeline
        let engine = PlaybackEngine(timeline: timeline)

        // Then: Timeline is set
        XCTAssertEqual(engine.timeline.config.frameRate, .fps24)
    }

    // MARK: - Frame Rate Tests

    func testTimelineFrameRateDefault() {
        // Given: Engine with default timeline
        let engine = PlaybackEngine(timeline: .empty)

        // Then: Timeline frame rate is 24fps
        XCTAssertEqual(engine.timeline.config.frameRate, .fps24, "Should default to 24fps")
    }

    // MARK: - Playback State Tests

    func testInitialPlaybackState() {
        // Given: New engine
        let engine = PlaybackEngine(timeline: .empty)

        // Then: Should not be playing
        XCTAssertFalse(engine.isPlaying)
    }

    // MARK: - Current Frame Tests

    func testInitialCurrentFrame() {
        // Given: New engine
        let engine = PlaybackEngine(timeline: .empty)

        // Then: Should start at frame 0
        XCTAssertEqual(engine.currentFrame, 0)
    }

    // MARK: - External Chase Reconciliation

    func testPreStopDrainCannotOverrideRecentLocate() {
        XCTAssertFalse(
            PlaybackEngine.acceptsMTCFrame(
                19_081,
                afterLocate: 19_052,
                elapsed: 0.018,
                framesPerSecond: 24
            )
        )
    }

    func testLocatedPositionAndRealTimeAdvanceAreAccepted() {
        XCTAssertTrue(
            PlaybackEngine.acceptsMTCFrame(
                19_052,
                afterLocate: 19_052,
                elapsed: 0.018,
                framesPerSecond: 24
            )
        )
        XCTAssertTrue(
            PlaybackEngine.acceptsMTCFrame(
                19_058,
                afterLocate: 19_052,
                elapsed: 0.25,
                framesPerSecond: 24
            )
        )
    }

    func testHoldRequiresForwardRealTimeMovementToRelease() {
        XCTAssertFalse(
            PlaybackEngine.isRollingAfterHold(
                from: 19_052,
                to: 19_052,
                elapsed: 0.25,
                framesPerSecond: 24
            )
        )
        XCTAssertTrue(
            PlaybackEngine.isRollingAfterHold(
                from: 19_052,
                to: 19_058,
                elapsed: 0.25,
                framesPerSecond: 24
            )
        )
        XCTAssertFalse(
            PlaybackEngine.isRollingAfterHold(
                from: 19_052,
                to: 19_081,
                elapsed: 0.25,
                framesPerSecond: 24
            )
        )
    }
}

@MainActor
final class PlayerPresentationTests: XCTestCase {
    func testFullScreenUsesSourceDisplayAndClosesWithoutCreatingPopOut() async throws {
        let engine = PlaybackEngine(timeline: .empty)
        let controller = PlayerWindowController()
        controller.configure(playbackEngine: engine, settings: .shared,
                             midiSyncViewModel: MIDISyncViewModel(service: MIDISyncActor()),
                             dragContext: DragContext(), onDropURLs: { _ in }, onDropProviders: { _ in false })
        defer { controller.dismissFullScreen(); controller.hide(); engine.cleanup() }
        XCTAssertFalse(NSScreen.screens.isEmpty)
        for screen in NSScreen.screens {
            let source = NSWindow(contentRect: CGRect(x: screen.visibleFrame.midX - 320,
                                                     y: screen.visibleFrame.midY - 180,
                                                     width: 640, height: 360),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            source.isReleasedWhenClosed = false
            source.orderFront(nil)
            defer { source.orderOut(nil) }
            let originalFrame = source.frame
            let existingWindows = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
            controller.showFullScreen(from: source)
            try await Task.sleep(nanoseconds: 200_000_000)
            let surface = try XCTUnwrap(controller.fullScreenView)
            XCTAssertTrue(surface.isInFullScreenMode)
            XCTAssertEqual(surface.window?.screen, screen)
            XCTAssertEqual(surface.window?.frame, screen.frame)
            XCTAssertNil(controller.window, "Main fullscreen must never create a pop-out")
            XCTAssertFalse(controller.isPoppedOut)
            XCTAssertFalse(surface.areControlsVisible)
            XCTAssertTrue(source.isVisible)
            XCTAssertEqual(source.frame, originalFrame)
            let additionalWindows = NSApp.windows.filter { $0.isVisible && !existingWindows.contains(ObjectIdentifier($0)) }
            XCTAssertEqual(additionalWindows.count, 1, "No black shielding windows on other displays")
            surface.closeButton.performClick(nil)
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertFalse(controller.isPresentingFullScreen)
            XCTAssertNil(controller.fullScreenView)
            XCTAssertNil(controller.window)
            XCTAssertTrue(source.isVisible)
        }
    }

    func testPopOutHasNormalChromeAndFullscreenClosesWithoutRestoringIt() async throws {
        let engine = PlaybackEngine(timeline: .empty)
        let controller = PlayerWindowController()
        controller.configure(playbackEngine: engine, settings: .shared,
                             midiSyncViewModel: MIDISyncViewModel(service: MIDISyncActor()),
                             dragContext: DragContext(), onDropURLs: { _ in }, onDropProviders: { _ in false })
        defer { controller.dismissFullScreen(); controller.hide(); engine.cleanup() }
        for screen in NSScreen.screens {
            controller.show(on: screen)
            let window = try XCTUnwrap(controller.window)
            XCTAssertEqual(window.screen, screen)
            XCTAssertEqual(window.contentView?.bounds.size, CGSize(width: 640, height: 360))
            XCTAssertTrue(window.styleMask.contains(.resizable))
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                XCTAssertFalse(try XCTUnwrap(window.standardWindowButton(kind)).isHidden)
            }
            let normalFrame = window.frame
            window.standardWindowButton(.zoomButton)?.performClick(nil)
            for _ in 0..<40 {
                if controller.isPresentingFullScreen && !window.isVisible { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTAssertTrue(controller.isPresentingFullScreen)
            XCTAssertFalse(controller.isPoppedOut, "Pop-out visibility state must be false during presentation")
            XCTAssertFalse(window.isVisible, "Source window \(window.windowNumber) remains visible; controller owns \(controller.window?.windowNumber ?? -1)")
            XCTAssertEqual(controller.fullScreenView?.window?.screen, screen)
            controller.fullScreenView?.closeButton.performClick(nil)
            for _ in 0..<40 {
                if !controller.isPresentingFullScreen && !window.isVisible { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTAssertFalse(controller.isPresentingFullScreen)
            XCTAssertFalse(window.isVisible, "Exit must not reopen the normal pop-out")
            XCTAssertEqual(window.frame, normalFrame)
            controller.show(on: screen)
            XCTAssertEqual(window.frame.size, normalFrame.size)
            window.performClose(nil)
            XCTAssertFalse(controller.isVisible)
        }
    }

    func testBothVideoSurfacesBecomeReadyWithTheSamePlayer() async throws {
        let url = try await TestVideoFileFactory.makeBlackMovie(duration: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = AVPlayer(url: url)
        let surfaces = [VideoSurfaceView(frame: NSRect(x: 0, y: 0, width: 320, height: 240)),
                        VideoSurfaceView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))]
        let windows = surfaces.map { surface in
            let window = NSWindow(contentRect: surface.frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = surface
            surface.playerLayer.player = player
            window.orderFront(nil)
            return window
        }
        defer {
            player.pause()
            surfaces.forEach { $0.playerLayer.player = nil }
            windows.forEach { $0.orderOut(nil) }
        }
        player.play()
        for _ in 0..<100 {
            if surfaces.allSatisfy({ $0.playerLayer.isReadyForDisplay }) { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(surfaces[0].playerLayer.isReadyForDisplay, "Inline picture must remain available")
        XCTAssertTrue(surfaces[1].playerLayer.isReadyForDisplay, "Pop-out must display the same player")
    }

    func testPopOutSpacebarRoutesOnceToSharedTransport() throws {
        let window = PlayerVideoWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
                                       styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var toggles = 0
        window.onTogglePlayback = { toggles += 1 }
        func key(_ code: UInt16, repeating: Bool = false) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                          timestamp: 0, windowNumber: window.windowNumber,
                                          context: nil, characters: code == 49 ? " " : "\u{1b}",
                                          charactersIgnoringModifiers: code == 49 ? " " : "\u{1b}",
                                          isARepeat: repeating, keyCode: code))
        }
        window.sendEvent(try key(49))
        window.sendEvent(try key(49, repeating: true))
        XCTAssertEqual(toggles, 1)
        XCTAssertTrue(window.canBecomeKey)
    }
}
