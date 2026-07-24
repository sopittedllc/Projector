import SwiftUI
import AppKit

// MARK: - Helper Properties and Functions
extension ContentView {
    // MARK: - Computed Properties

    /// Minimum height for the playback view
    var playbackMinHeight: CGFloat {
        200
    }

    /// Minimum height for the lower panels area
    var lowerPanelsMinHeight: CGFloat {
        showFileManager ? 180 : 100
    }

    /// Message displayed in FPS conflict alert
    var fpsConflictMessage: String {
        guard let fps = pendingVideoFPS else { return "" }
        return "This video is \(fps.displayName) but the project is \(timelineManager.timeline.config.frameRate.displayName).\n\nChanging the project FPS will remove all existing video reels."
    }

    /// Maximum height for the playback view based on available space
    var playbackMaxHeight: CGFloat {
        let reservedHeight = vitalControlsHeight + lowerPanelsMinHeight
        if normalViewHeight > 0 {
            return max(playbackMinHeight, normalViewHeight - reservedHeight)
        }
        if playbackMeasuredHeight > 0 {
            return max(playbackMinHeight, playbackMeasuredHeight)
        }
        return CGFloat.greatestFiniteMagnitude
    }

    // MARK: - Helper Functions

    /// Dismiss timecode editing by removing first responder
    func dismissTimecodeEditing() {
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    /// Clamp playback height to valid range if needed
    func clampPlaybackHeightIfNeeded() {
        guard let height = playbackHeight else { return }
        let clamped = min(playbackMaxHeight, max(playbackMinHeight, height))
        if clamped != height {
            playbackHeight = clamped
        }
    }

    /// Enter full screen mode
    func enterFullScreen() {
        guard let window = NSApp.keyWindow else { return }
        isFullScreen = true
        window.toggleFullScreen(nil)
    }

    /// Exit full screen mode
    func exitFullScreen() {
        guard let window = NSApp.keyWindow else { return }
        isFullScreen = false
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
    }

    /// Grow the app window to `MainWindowLayout`'s expanded size after the first media import.
    ///
    /// The window opens at its small pre-import minimum (`ContentView`'s
    /// `.frame(minWidth:minHeight:)`). Once media is imported the timeline and media panels
    /// expand to show real content, so the window needs to grow to give them room. Anchors on
    /// the window's current top-left corner and clamps to the screen's visible frame so the
    /// window never grows off-screen or over the menu bar/dock.
    func growWindowForFirstImport() {
        guard let window = NSApp.mainWindow ?? NSApp.keyWindow ?? NSApp.windows.first,
              !window.styleMask.contains(.fullScreen) else { return }
        guard let screen = window.screen ?? NSScreen.main else { return }

        let visibleFrame = screen.visibleFrame
        let targetWidth = min(MainWindowLayout.expandedWidth, visibleFrame.width)
        let targetHeight = min(MainWindowLayout.expandedHeight, visibleFrame.height)

        var newFrame = window.frame
        guard newFrame.width < targetWidth || newFrame.height < targetHeight else { return }

        let heightDelta = max(0, targetHeight - newFrame.height)
        newFrame.size.width = max(newFrame.width, targetWidth)
        newFrame.size.height = max(newFrame.height, targetHeight)
        // NSWindow's origin is its bottom-left corner; keep the top edge anchored while
        // growing downward by shifting the origin down by the added height.
        newFrame.origin.y -= heightDelta

        if newFrame.origin.y < visibleFrame.minY {
            newFrame.origin.y = visibleFrame.minY
        }
        if newFrame.maxX > visibleFrame.maxX {
            newFrame.origin.x = max(visibleFrame.minX, visibleFrame.maxX - newFrame.width)
        }

        window.setFrame(newFrame, display: true, animate: true)
    }

    /// Grow the window taller by `delta` points, anchored at its top-left and
    /// clamped to the screen's visible frame.
    ///
    /// Used when the timeline panel auto-grows for new lanes: without this the
    /// panel's extra height just squeezes the other panels inside a fixed
    /// window. Growth only - the window never shrinks when lanes are removed,
    /// so a size the user chose by hand is left alone.
    func growWindow(byAdditionalHeight delta: CGFloat) {
        guard delta > 0,
              let window = NSApp.mainWindow ?? NSApp.keyWindow ?? NSApp.windows.first,
              !window.styleMask.contains(.fullScreen) else { return }
        guard let screen = window.screen ?? NSScreen.main else { return }

        let visibleFrame = screen.visibleFrame
        var newFrame = window.frame
        let targetHeight = min(newFrame.height + delta, visibleFrame.height)
        let heightDelta = targetHeight - newFrame.height
        guard heightDelta > 0 else { return }

        newFrame.size.height = targetHeight
        // NSWindow's origin is its bottom-left corner; keep the top edge
        // anchored while growing downward.
        newFrame.origin.y -= heightDelta
        if newFrame.origin.y < visibleFrame.minY {
            newFrame.origin.y = visibleFrame.minY
        }

        window.setFrame(newFrame, display: true, animate: true)
    }

    // MARK: - AlertCoordinator Helpers

    /// Show the save project sheet via AlertCoordinator
    func showSaveProjectSheetViaCoordinator() {
        let service = persistenceService
        alerts.show(.saveProject(content: AnyView(
            SaveProjectSheet(onSave: { url in
                service.handleProjectSave(to: url)
            })
        )))
    }
}
