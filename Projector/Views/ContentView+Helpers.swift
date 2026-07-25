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

    // NOTE: enterFullScreen/exitFullScreen were removed here along with the
    // main window's video-fullscreen mode. The player is its own window now and
    // uses native fullscreen (green traffic light, or the button in its hover
    // overlay). The old observers listened for fullscreen notifications from
    // ANY window, so the player going fullscreen would have flipped the main
    // window into video mode.

    /// Grow the window vertically so newly added lanes and media are visible.
    ///
    /// Ceiling'd, which is the whole point: the earlier version had no bound,
    /// so a multi-file drop added several lanes, each nudging the window taller
    /// until it filled the display. Growth stops at
    /// `MainWindowLayout.expandedHeight`, never shrinks the window, and never
    /// touches a window the user has already made taller than that ceiling.
    /// Height the main window's content wants, given the panels currently on
    /// screen.
    ///
    /// Derived from the panels themselves rather than a fixed constant: the old
    /// version grew the window by whatever delta the timeline had just gained
    /// and stopped at a hardcoded ceiling, which both undershot (media panel
    /// clipped once several lanes existed) and, before the ceiling, overshot
    /// (window crept to fill the display over repeated drops).
    var idealMainWindowContentHeight: CGFloat {
        let transport = vitalControlsHeight > 0 ? vitalControlsHeight : 60
        let transportChrome = Spacing.md + Spacing.sm

        // Prefer the measured height of the panel stack. It accounts for
        // whatever is actually on screen - the optimization banner, a collapsed
        // Settings section, a hidden media panel - none of which a constant can
        // track. Falls back to an estimate only before the first measurement.
        if panelsContentHeight > 0 {
            return transport + transportChrome + panelsContentHeight
        }

        let settings = PanelLayout.headerHeight
        let timeline = timelineViewModel.currentHeight
        let media = showFileManager ? FileManagerLayout.expandedHeight : 0
        return transport
            + transportChrome
            + settings
            + Spacing.md + timeline
            + Spacing.md + media
            + Spacing.md * 2
    }

    /// Resize the window so the current panels fit, without letting it creep.
    ///
    /// Sets an absolute target rather than accumulating deltas, so repeated
    /// calls converge instead of compounding. Resizes in **both** directions:
    /// deleting lanes shrinks the panel, and without a matching shrink here the
    /// window kept a screenful of empty space. Bounded below by the default
    /// window height so an emptied timeline can't collapse the window, and
    /// above by the screen's visible height.
    func fitWindowToContent() {
        guard let window = mainAppWindow,
              !window.styleMask.contains(.fullScreen),
              let screen = window.screen ?? NSScreen.main else { return }

        let visibleFrame = screen.visibleFrame
        // Window height includes the titlebar, which isn't part of content.
        let chrome = window.frame.height - window.contentLayoutRect.height
        let target = min(
            max(idealMainWindowContentHeight + chrome, MainWindowLayout.defaultHeight),
            visibleFrame.height
        )

        var frame = window.frame
        // 2pt deadband: keeps rounding from ping-ponging the window.
        guard abs(target - frame.height) > 2 else { return }

        let delta = target - frame.height
        frame.size.height = target
        // NSWindow's origin is bottom-left; keep the top edge anchored so the
        // window grows downward and shrinks upward from the same corner.
        frame.origin.y -= delta
        if frame.origin.y < visibleFrame.minY {
            frame.origin.y = visibleFrame.minY
        }
        window.setFrame(frame, display: true, animate: true)
    }

    // MARK: - Window & Layout State

    /// Resolve the main window, however it is currently keyed.
    var mainAppWindow: NSWindow? {
        NSApp.mainWindow ?? NSApp.keyWindow ?? NSApp.windows.first { $0.canBecomeMain }
    }

    /// Give the main window its default size on first launch.
    ///
    /// Applied only when the project has no saved frame, so it never fights a
    /// size the user chose.
    func applyDefaultMainWindowSizeIfNeeded() {
        guard projectDocument.uiState.mainWindowFrame == nil,
              let window = mainAppWindow,
              !window.styleMask.contains(.fullScreen),
              let screen = window.screen ?? NSScreen.main else { return }

        let visibleFrame = screen.visibleFrame
        var frame = window.frame
        frame.size.width = min(MainWindowLayout.defaultWidth, visibleFrame.width)
        frame.size.height = min(MainWindowLayout.defaultHeight, visibleFrame.height)
        window.setFrame(frame, display: true)
        window.center()
    }

    /// Restore the main window frame saved with the project, clamped so a frame
    /// saved on a larger or differently-arranged display stays reachable.
    func restoreMainWindowFrame(_ saved: ProjectUIState.WindowFrame) {
        guard let window = mainAppWindow,
              !window.styleMask.contains(.fullScreen) else { return }

        var rect = saved.cgRect
        guard rect.width > 0, rect.height > 0 else { return }

        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            rect.size.width = min(rect.width, visible.width)
            rect.size.height = min(rect.height, visible.height)
            rect.origin.x = min(max(rect.origin.x, visible.minX), visible.maxX - rect.width)
            rect.origin.y = min(max(rect.origin.y, visible.minY), visible.maxY - rect.height)
        }
        window.setFrame(rect, display: true)
    }

    /// Record the main window's frame into the project's UI state.
    func captureMainWindowFrame() {
        guard let window = mainAppWindow,
              !window.styleMask.contains(.fullScreen) else { return }
        projectDocument.updateUIState { $0.mainWindowFrame = .init(window.frame) }
    }

    /// Apply the layout saved with the current project: window frames, panel
    /// expansion, and timeline height.
    ///
    /// Each value is only written when it differs, so this doesn't fight
    /// in-flight animations or retrigger the observers that write state back.
    func applySavedUIState() {
        let state = projectDocument.uiState

        if let frame = state.mainWindowFrame {
            restoreMainWindowFrame(frame)
        }

        if timelineViewModel.isExpanded != state.timelineExpanded {
            timelineViewModel.isExpanded = state.timelineExpanded
        }
        if let height = state.timelineExpandedHeight,
           timelineViewModel.expandedHeight != CGFloat(height) {
            timelineViewModel.setExpandedHeight(CGFloat(height))
        }
        if isSettingsExpanded != state.settingsExpanded {
            isSettingsExpanded = state.settingsExpanded
        }

        let player = PlayerWindowController.shared
        if let frame = state.playerWindowFrame {
            player.restoreFrame(frame.cgRect)
        }
        player.setPinnedToFront(state.playerWindowPinned)
        if state.playerWindowVisible {
            player.show()
        }
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
