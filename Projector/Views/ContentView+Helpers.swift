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
