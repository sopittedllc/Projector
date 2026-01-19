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

    /// Open the cues window as a separate window
    func openCuesWindow() {
        // Check if window is already open
        if showCuesWindow { return }

        let projectName = projectDocument.fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
        let manager = timelineManager
        let engine = playbackEngine

        let cuesView = CuesWindowView(
            timelineManager: manager,
            projectName: projectName,
            onSeekToCue: { frame in
                engine.seekToFrame(frame)
            }
        )

        let hostingController = NSHostingController(rootView: cuesView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Cues - \(projectName)"
        window.setContentSize(NSSize(width: 700, height: 400))
        window.styleMask = NSWindow.StyleMask([.titled, .closable, .resizable, .miniaturizable])
        window.minSize = NSSize(width: 500, height: 250)
        window.center()

        // Track window close
        showCuesWindow = true
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            Task { @MainActor in
                self.showCuesWindow = false
            }
        }

        window.makeKeyAndOrderFront(nil as AnyObject?)
    }
}
