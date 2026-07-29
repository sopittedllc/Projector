import SwiftUI
import AppKit

// MARK: - Helper Properties and Functions
extension ContentView {
    // MARK: - Computed Properties

    /// Message displayed in FPS conflict alert
    var fpsConflictMessage: String {
        guard let fps = pendingVideoFPS else { return "" }
        return "This video is \(fps.displayName) but the project is \(timelineManager.timeline.config.frameRate.displayName).\n\nChanging the project FPS will remove all existing video reels."
    }

    // MARK: - Helper Functions

    /// Dismiss timecode editing by removing first responder
    func dismissTimecodeEditing() {
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    // Fullscreen belongs to the player window, which uses the native control
    // (green traffic light, or the button in its hover overlay). The main window
    // has no video-fullscreen mode of its own.

    // MARK: - Window Sizing Authority
    //
    // The window's size is an *input* now, not an output. `SectionLayout` turns
    // it into every section's size (see the rules on that type), so this file
    // has one job left: give the window a legal size to start from and keep it
    // inside the screen. It does not resize the window in response to content,
    // and nothing here may start doing so again:
    //
    //  1. THE USER'S SIZE WINS. A window the user dragged to a size is never
    //     resized back. That is the whole reason the old authority had to go -
    //     it recomputed the window's height from measured panel content, which
    //     silently undid every manual resize the moment a lane was added.
    //
    //  2. MINIMUMS COME FROM THE SECTIONS. `mainWindowMinWidth` and
    //     `mainWindowMinHeight` are the window sizes at which every section is
    //     simultaneously at its own minimum. Because the window cannot go below
    //     them, the content is guaranteed to fit - which is what let the panel
    //     stack's scroll view, its offset normalization and the "is a scroller
    //     earned" test all be deleted.
    //
    //  3. NOTHING MEASURES ITSELF. Sections are told their size and never report
    //     one back. The removed version needed a 2pt deadband and two deferred
    //     passes precisely because it read content it had just sized.
    //
    //  4. RESIZE OFF THE VIEW GRAPH. What remains that does touch the window -
    //     the first-launch default and the saved-frame restore - still runs from
    //     `onAppear` rather than mid-update. Resizing a window synchronously from
    //     inside a SwiftUI update re-enters the view graph and crashes
    //     (EXC_BAD_ACCESS through `NSHostingView.layout()`); there is a crash
    //     report from exactly that path.

    // MARK: - Window & Layout State

    /// Resolve the main window, however it is currently keyed.
    var mainAppWindow: NSWindow? {
        NSApp.mainWindow ?? NSApp.keyWindow ?? NSApp.windows.first { $0.canBecomeMain }
    }

    /// Give the main window its default size on first launch.
    ///
    /// Applied only when the project has no saved frame, so it never fights a
    /// size the user chose.
    func applyDefaultMainWindowSizeIfNeeded(attempt: Int = 0) {
        guard projectDocument.uiState.mainWindowFrame == nil else { return }

        // The window does not exist yet on the first `onAppear` - `mainAppWindow`
        // resolves through NSApp.mainWindow/keyWindow, and neither is set that
        // early - so this silently did nothing and the window kept whatever size
        // SwiftUI gave it. That was survivable while the default was narrower
        // than SwiftUI's choice; it stopped being so once the video moved
        // alongside the panels and the default had to be wider. Retry briefly
        // rather than firing once into a nil window.
        guard let window = mainAppWindow,
              !window.styleMask.contains(.fullScreen),
              let screen = window.screen ?? NSScreen.main else {
            guard attempt < Self.windowLookupAttempts else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                applyDefaultMainWindowSizeIfNeeded(attempt: attempt + 1)
            }
            return
        }

        // `SectionLayout.defaultWindowSize` is the size that produces the
        // reference proportions exactly, so the window opens showing the layout
        // as designed rather than growing into it over the first few frames.
        let visibleFrame = screen.visibleFrame
        let ideal = SectionLayout.defaultWindowSize
        let minimum = SectionLayout.minimumWindowSize
        var frame = window.frame
        frame.size.width = max(minimum.width, min(ideal.width, visibleFrame.width))
        frame.size.height = max(minimum.height, min(ideal.height, visibleFrame.height))
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

        // Rule 2: a frame saved before the minimums changed - or on a display
        // that could hold less - still has to be one the sections can be laid
        // out in, so it is floored as well as capped.
        let minimum = SectionLayout.minimumWindowSize
        rect.size.width = max(rect.width, minimum.width)
        rect.size.height = max(rect.height, minimum.height)

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
    /// expansion, and the section split.
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
        // A share restores correctly onto any window size; the absolute timeline
        // height projects used to save does not, which is why that field is now
        // read only as a fallback for projects saved before the split existed.
        let restoredShare = state.topRowShare.map { CGFloat($0) }
            ?? state.timelineExpandedHeight.map { savedTimelineHeight in
                SectionLayout.share(
                    forTopRowHeight: SectionLayout.referenceContentSize.height
                        - SectionLayout.gap - CGFloat(savedTimelineHeight),
                    in: SectionLayout.referenceContentSize.height
                )
            }
        if let restoredShare, topRowShare != restoredShare {
            topRowShare = restoredShare
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

    // MARK: - New Project

    /// Handle creating a new project, prompting to save unsaved changes first.
    func handleNewProject() {
        guard projectDocument.hasUnsavedChanges else {
            resetToNewProject()
            return
        }

        // Prompt to save unsaved changes
        let alert = NSAlert()
        alert.messageText = "Save changes to your project?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()

        switch response {
        case .alertFirstButtonReturn: // Save
            if persistenceService.saveProject() {
                resetToNewProject()
            } else {
                // No file URL, show Save As then reset
                let service = persistenceService
                alerts.show(.saveProject(content: AnyView(
                    SaveProjectSheet(onSave: { url in
                        service.handleProjectSave(to: url)
                        self.resetToNewProject()
                    })
                )))
            }

        case .alertSecondButtonReturn: // Don't Save
            resetToNewProject()

        case .alertThirdButtonReturn: // Cancel
            break

        default:
            break
        }
    }

    /// Reset to a fresh empty project.
    private func resetToNewProject() {
        // Reset the project document
        projectDocument.newProject()

        // Sync timeline manager with the new empty timeline
        timelineManager.timeline = projectDocument.timeline
        timelineManager.currentFrame = 0
        timelineManager.markClean()

        // Clear the media library
        mediaLibrary.load(items: [])

        // Reset playback
        playbackEngine.stop()
        playbackEngine.timeline = timelineManager.timeline

        // Clear waveform cache
        waveformCache.clearAll()

        debugPrint("ContentView: reset to new project")
    }

    // MARK: - Cue List Export

    /// Handle export cue list action - shows save panel then exports.
    func handleExportCueList() {
        Task {
            do {
                // First detect cues to validate there's something to export
                let cues = try await cueListExportService.detectCues(
                    in: timelineManager.timeline.audioLanes,
                    frameRate: timelineManager.timeline.config.frameRate.fps,
                    startTimecodeFrames: timelineManager.timeline.config.startTimecode.frameCount.wholeFrames,
                    config: .default
                )

                // Show save panel on main thread
                await MainActor.run {
                    let savePanel = NSSavePanel()
                    savePanel.allowedContentTypes = [.commaSeparatedText]
                    savePanel.nameFieldStringValue = "CueList.csv"
                    savePanel.title = "Export Cue List"
                    savePanel.prompt = "Export"

                    let response = savePanel.runModal()
                    guard response == .OK, let url = savePanel.url else { return }

                    Task {
                        do {
                            try await cueListExportService.exportToCSV(cues: cues, to: url)
                            debugPrint("ContentView: exported \(cues.count) cues to \(url.path)")
                        } catch let error as CueListExportError {
                            showCueListError(error.message)
                        } catch {
                            showCueListError(error.localizedDescription)
                        }
                    }
                }
            } catch let error as CueListExportError {
                await MainActor.run {
                    showCueListError(error.message)
                }
            } catch {
                await MainActor.run {
                    showCueListError(error.localizedDescription)
                }
            }
        }
    }

    /// Shows an error alert for cue list export failures.
    private func showCueListError(_ message: String) {
        cueListExportError = message
        showCueListExportError = true
    }
}
