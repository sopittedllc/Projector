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
        let reservedHeight = videoAreaHeight + lowerPanelsMinHeight
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
        // The measured value already includes the video area's own padding -
        // the GeometryReader sits in a `.background` applied after it - so no
        // chrome is added here. The fallback covers the frames before the first
        // measurement lands and is derived from the same constant, not a guess.
        let video = videoAreaHeight > 0
            ? videoAreaHeight
            : MainWindowLayout.inlineVideoHeight + Spacing.md + Spacing.sm

        // Prefer the measured height of the panel stack. It accounts for
        // whatever is actually on screen - the optimization banner, a collapsed
        // Settings section, a hidden media panel - none of which a constant can
        // track. Falls back to an estimate only before the first measurement.
        // The taller of the two columns, not their sum: the video sits beside
        // the panels now. Summing them made the window grow by the video's
        // height for content that no longer stacks above anything.
        if panelsContentHeight > 0 {
            return max(video, panelsContentHeight)
        }

        let settings = PanelLayout.headerHeight
        let timeline = timelineViewModel.currentHeight
        let media = showFileManager ? FileManagerLayout.expandedHeight : 0
        let panels = settings
            + Spacing.md + timeline
            + Spacing.md + media
            + Spacing.md * 2
        return max(video, panels)
    }

    /// Resize the window so the current panels fit, without letting it creep.
    ///
    /// Sets an absolute target rather than accumulating deltas, so repeated
    /// calls converge instead of compounding. Resizes in **both** directions:
    /// deleting lanes shrinks the panel, and without a matching shrink here the
    /// window kept a screenful of empty space. Bounded below by the default
    /// window height so an emptied timeline can't collapse the window, and
    /// above by the screen's visible height.
    // MARK: - Window Sizing Authority
    //
    // One place decides how big the window is and where the panel scroller
    // sits. These rules hold at all times; anything that changes layout calls
    // `syncWindowToContent()` and lets them re-apply, rather than nudging the
    // window itself:
    //
    //  1. HEIGHT FOLLOWS CONTENT. The target is the taller of the two columns -
    //     the fixed video column, or the panel stack - plus window chrome,
    //     clamped to [`minimumHeight`, the screen's visible height]. It shrinks
    //     as readily as it grows, so collapsing a panel reclaims the space.
    //
    //  2. WIDTH IS NEVER THE PROBLEM. `mainWindowMinWidth` covers the video
    //     column plus the widest panel header, so panel content never has to
    //     compress. Width is not adjusted here - only defended by that minimum.
    //
    //  3. THE PANEL STACK SCROLLS ONLY WHEN IT MUST. If the window is at screen
    //     height and content still overflows, the scroller earns its keep.
    //     Otherwise the offset is forced to zero.
    //
    //  4. A STALE OFFSET IS A BUG, NOT A PREFERENCE. Collapsing a panel shrinks
    //     the content under a scroller that keeps its old offset, which is what
    //     leaves panels stranded half off-screen. Rule 3 is therefore re-applied
    //     after every resize, not only when a panel expands.
    //
    //  5. THE VIDEO COLUMN IS FIXED. It never participates in vertical growth;
    //     the space beneath it is left empty by design.
    //
    //  6. NO SCROLLER UNLESS IT IS EARNED. Rule 1 means the window normally
    //     grows or shrinks to fit, so the scroller has nothing to do - but a
    //     live NSScrollView still flashes its indicator whenever the content
    //     resizes under it, which reads as a glitch during every collapse.
    //     Scrolling is enabled once the window reaches the screen ceiling, and
    //     that test reads the window, never the content: measuring content
    //     inside the scroll view to decide whether it should scroll is circular.
    //
    //  7. PANELS ARE BOUNDED, SO THE WINDOW DOES NOT HAVE TO BE. The top row and
    //     the timeline each have a height ceiling and scroll inside it. Between
    //     them they are sized to fit a 13" laptop, so reaching rule 6 at all is
    //     the exception rather than the normal state.

    /// Bring the window and the panel scroller into line with the current
    /// content. Safe to call as often as layout changes, and from any context.
    ///
    /// Deferred to the next runloop turn on purpose. Callers include SwiftUI
    /// `onChange` handlers, which run inside the view graph's update pass -
    /// resizing the window from there re-enters SwiftUI mid-layout and crashes
    /// (EXC_BAD_ACCESS through `NSHostingView.layout()`). Hopping out first
    /// means no caller has to know where it is being called from.
    func syncWindowToContent() {
        DispatchQueue.main.async { applyWindowSync() }
    }

    private func applyWindowSync() {
        guard let window = mainAppWindow,
              !window.styleMask.contains(.fullScreen),
              let screen = window.screen ?? NSScreen.main else { return }

        let visibleFrame = screen.visibleFrame
        // Window height includes the titlebar, which isn't part of content.
        let chrome = window.frame.height - window.contentLayoutRect.height
        let target = min(
            max(idealMainWindowContentHeight + chrome, MainWindowLayout.minimumHeight),
            visibleFrame.height
        )

        // Rule 6: the scroller is offered once the window is against the screen
        // ceiling, because that is the point at which growing further is no
        // longer an option.
        //
        // Deliberately decided from the window, not from the content. Asking
        // "is the content taller than the viewport" is circular: that height is
        // measured inside the scroll view, so disabling scrolling makes the
        // content report as fitting, which keeps scrolling disabled. That is
        // what left a full timeline unscrollable with its top cut off.
        let needsScroller = target >= visibleFrame.height - 1
        if panelsCanScroll != needsScroller {
            panelsCanScroll = needsScroller
        }

        var frame = window.frame
        // 2pt deadband: keeps rounding from ping-ponging the window.
        if abs(target - frame.height) > 2 {
            let delta = target - frame.height
            frame.size.height = target
            // NSWindow's origin is bottom-left; keep the top edge anchored so
            // the window grows downward and shrinks upward from the same corner.
            frame.origin.y -= delta
            if frame.origin.y < visibleFrame.minY {
                frame.origin.y = visibleFrame.minY
            }
            // `animator()` rather than `animate: true`: the latter drives the
            // animation from a nested run loop, which is the other half of the
            // re-entrancy problem above. This animates off the main runloop
            // without blocking or nesting.
            window.animator().setFrame(frame, display: true)
        }

        normalizePanelScroll()
    }

    /// Rules 3 and 4: the panel stack sits at the top unless it genuinely has
    /// more content than the window can show.
    ///
    /// Applied twice - immediately, and again once any resize animation has
    /// settled - because the content height that decides "does this fit" is
    /// still changing on the first pass.
    func normalizePanelScroll() {
        func normalize() {
            guard let sv = panelsScrollView else { return }
            let overflow = (sv.documentView?.frame.height ?? 0) - sv.contentView.bounds.height
            let maxOffset = max(0, overflow)
            let clamped = min(sv.contentView.bounds.origin.y, maxOffset)
            let target = maxOffset <= 0 ? 0 : clamped
            guard abs(sv.contentView.bounds.origin.y - target) > 0.5 else { return }
            sv.contentView.setBoundsOrigin(NSPoint(x: 0, y: target))
            sv.reflectScrolledClipView(sv.contentView)
        }
        DispatchQueue.main.async { normalize() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { normalize() }
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
