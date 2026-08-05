//
//  FloatingVideoPanel.swift
//  Projector
//
//  The standalone video player window.
//
//  NOTE: the filename is historical - this file used to host the pop-out
//  "floating panel". The player is now a permanent separate window and the
//  pop-out/pop-back machinery is gone. The filename is kept because only the
//  ProjectorQuickLook group is filesystem-synchronized in the pbxproj; renaming
//  the file would drop it from the build.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SwiftTimecodeCore

// MARK: - PlayerWindowController

/// Owns the standalone video player window.
///
/// The player is never embedded in the main window. This controller creates the
/// window once and keeps it for the app's lifetime:
///
/// - **Closing hides, it does not destroy.** `windowShouldClose` orders the
///   window out and returns `false`, so playback continues while the window is
///   away and reopening restores the exact same window and frame.
/// - **Pinning** raises the window to `.floating` and lets it join all Spaces
///   plus fullscreen Spaces, so it stays visible over a fullscreen DAW.
///
/// ## Usage
/// ```swift
/// PlayerWindowController.shared.configure(
///     playbackEngine: engine,
///     settings: settings,
///     onDropURLs: { urls in ... },
///     onDropProviders: { providers in ... }
/// )
/// PlayerWindowController.shared.show()
/// ```
@MainActor
final class PlayerWindowController: NSObject, ObservableObject {
    /// Whether the player is currently in its own window.
    ///
    /// The app renders exactly one video instance. An `AVPlayer` drives one
    /// `AVPlayerView` at a time - attach a second and the first goes black - so
    /// the inline view in the main window and this window are mutually
    /// exclusive, and the inline view watches this to know when to detach.
    @Published private(set) var isPoppedOut = false

    static let shared = PlayerWindowController()

    /// Default content size on first launch, before an autosaved frame exists.
    private static let defaultContentSize = NSSize(width: 640, height: 360)

    /// Smallest usable monitor size.
    private static let minContentSize = NSSize(width: 320, height: 180)

    /// Autosave key - AppKit persists the window's frame and screen under this.
    private static let frameAutosaveName = "PlayerWindow"

    private var window: NSWindow?
    private var playbackEngine: PlaybackEngine?
    private var settings: AppSettings?
    private var onDropURLs: (([URL]) -> Void)?
    private var onDropProviders: (([NSItemProvider]) -> Bool)?

    /// Shared drag state. Held because `PlayerWindowContent` reads it as an
    /// `@EnvironmentObject`, and this window hosts that content itself - a
    /// hosting view does not inherit the main window's environment, so without
    /// injecting it here the first drop onto the player traps.
    private var dragContext: DragContext?

    /// Called when the window is shown or hidden, so the project can record it.
    var onVisibilityChanged: ((Bool) -> Void)?

    /// Called when the user finishes moving or resizing the window.
    var onFrameChanged: ((CGRect) -> Void)?

    /// Whether the window is currently pinned above other applications.
    private(set) var isPinnedToFront: Bool = false

    private override init() {
        super.init()
    }

    // MARK: - Setup

    /// Supply the player's dependencies. Safe to call more than once; the
    /// window is created on the first call and reused afterwards.
    ///
    /// - Parameters:
    ///   - playbackEngine: Engine whose video output is displayed.
    ///   - settings: App settings driving the timecode overlay and pin state.
    ///   - onDropURLs: Handles media dragged from the app's own Media panel.
    ///   - onDropProviders: Handles files dragged in from Finder. Returns
    ///     whether the drop was accepted.
    func configure(
        playbackEngine: PlaybackEngine,
        settings: AppSettings,
        dragContext: DragContext,
        onDropURLs: @escaping ([URL]) -> Void,
        onDropProviders: @escaping ([NSItemProvider]) -> Bool
    ) {
        self.playbackEngine = playbackEngine
        self.settings = settings
        self.dragContext = dragContext
        self.onDropURLs = onDropURLs
        self.onDropProviders = onDropProviders

        if window == nil {
            createWindow()
        }
        applyPinnedState(settings.playerWindowPinnedToFront)
    }

    private func createWindow() {
        guard let playbackEngine, let settings, let dragContext else { return }

        // A regular NSWindow, not the old non-activating NSPanel: the player
        // has to be able to become key for native fullscreen and keyboard
        // transport control to work.
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.title = "Player"
        window.isReleasedWhenClosed = false   // closing hides; we keep the instance
        window.hidesOnDeactivate = false
        window.minSize = Self.minContentSize
        window.backgroundColor = .black
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.fullScreenPrimary]
        window.delegate = self

        // Hide the traffic lights: the hover overlay provides collapse, pin,
        // and fullscreen, and the coloured dots read as clutter over video.
        // The buttons are hidden, not removed - the window keeps its titled
        // style mask, so native fullscreen and window dragging still work.
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        let content = PlayerWindowContent(
            playbackEngine: playbackEngine,
            settings: settings,
            onTogglePin: { [weak self] in self?.togglePinnedToFront() },
            onToggleFullScreen: { [weak self] in self?.toggleFullScreen() },
            onCollapse: { [weak self] in self?.hide() },
            onDropURLs: { [weak self] urls in self?.onDropURLs?(urls) },
            onDropProviders: { [weak self] providers in self?.onDropProviders?(providers) ?? false }
        )
        window.contentView = NSHostingView(rootView: content.environmentObject(dragContext))

        // Restore the saved frame, or center on first run.
        window.setFrameAutosaveName(Self.frameAutosaveName)
        if window.frame.origin == .zero {
            window.center()
        }

        self.window = window
    }

    // MARK: - Visibility

    /// Show the player window, creating it if necessary, and bring it forward.
    /// Idempotent - safe to call when the window is already visible.
    func show() {
        if window == nil {
            createWindow()
            if let settings {
                applyPinnedState(settings.playerWindowPinnedToFront)
            }
        }
        window?.makeKeyAndOrderFront(nil)
        isPoppedOut = true
        onVisibilityChanged?(true)
    }

    /// Whether the window exists and is on screen.
    var isVisible: Bool {
        window?.isVisible ?? false
    }

    /// Toggle the player window's own native fullscreen.
    func toggleFullScreen() {
        window?.toggleFullScreen(nil)
    }

    /// Hide the player window. Playback is unaffected - this is the same
    /// outcome as the close button, exposed as an in-window control because the
    /// titlebar is transparent over the video.
    func hide() {
        window?.orderOut(nil)
        isPoppedOut = false
        onVisibilityChanged?(false)
    }

    /// Current window frame, for saving into the project.
    var currentFrame: CGRect? {
        window?.frame
    }

    /// Restore a previously saved frame.
    func restoreFrame(_ rect: CGRect) {
        guard let window, rect.width > 0, rect.height > 0 else { return }
        window.setFrame(rect, display: true)
    }

    // MARK: - Sizing to Media

    /// Largest fraction of the screen the player will claim when sizing itself
    /// to the media. A 4K clip would otherwise open larger than the display.
    private static let maxScreenFraction: CGFloat = 0.8

    /// Resize the player to the media's own dimensions.
    ///
    /// Scaled down to fit the screen and up to the window's minimum, but always
    /// on the media's aspect ratio, so the picture fills the window instead of
    /// sitting in letterbox bars. Native size is a ceiling - a 320x240 clip is
    /// not blown up to fill the display.
    ///
    /// Also sets `contentAspectRatio`, so the proportions survive the user
    /// resizing the window afterwards.
    ///
    /// - Parameter mediaSize: The media's *display* size, with any rotation
    ///   already applied.
    func sizeToMedia(_ mediaSize: CGSize) {
        guard mediaSize.width > 0, mediaSize.height > 0 else { return }
        if window == nil { createWindow() }
        guard let window, !window.styleMask.contains(.fullScreen) else { return }

        window.contentAspectRatio = mediaSize

        let visible = (window.screen ?? NSScreen.main)?.visibleFrame
            ?? CGRect(origin: .zero, size: Self.defaultContentSize)

        // One uniform scale for both axes - scaling them independently is what
        // produces a stretched picture.
        let fitScale = min(
            1.0,
            min(visible.width * Self.maxScreenFraction / mediaSize.width,
                visible.height * Self.maxScreenFraction / mediaSize.height)
        )
        // Then lift back up if that lands under the window's minimum.
        let minScale = max(
            Self.minContentSize.width / mediaSize.width,
            Self.minContentSize.height / mediaSize.height
        )
        let scale = max(fitScale, min(minScale, 1.0))
        let contentSize = NSSize(width: (mediaSize.width * scale).rounded(),
                                 height: (mediaSize.height * scale).rounded())

        // Anchor the top-left so the window grows downward rather than
        // appearing to jump when it changes size.
        let previous = window.frame
        var frame = window.frameRect(forContentRect: NSRect(origin: previous.origin, size: contentSize))
        frame.origin.y = previous.maxY - frame.height

        // Keep it on screen after the resize.
        frame.origin.x = min(max(frame.origin.x, visible.minX), max(visible.minX, visible.maxX - frame.width))
        frame.origin.y = min(max(frame.origin.y, visible.minY), max(visible.minY, visible.maxY - frame.height))

        window.setFrame(frame, display: true, animate: window.isVisible)
    }

    // MARK: - Pin to Foreground

    /// Turn "lock to foreground" on or off and persist the choice.
    func setPinnedToFront(_ pinned: Bool) {
        settings?.playerWindowPinnedToFront = pinned
        applyPinnedState(pinned)
    }

    func togglePinnedToFront() {
        setPinnedToFront(!isPinnedToFront)
    }

    /// Apply a pin state to the live window without touching persistence.
    private func applyPinnedState(_ pinned: Bool) {
        isPinnedToFront = pinned
        guard let window else { return }

        if pinned {
            // `.floating` clears other apps; joining all Spaces plus
            // `.fullScreenAuxiliary` is what keeps it visible over a
            // fullscreen app such as Logic or Cubase.
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        } else {
            window.level = .normal
            window.collectionBehavior = [.fullScreenPrimary]
        }

        NotificationCenter.default.post(name: .playerWindowPinDidChange, object: nil)
    }
}

// MARK: - NSWindowDelegate

extension PlayerWindowController: NSWindowDelegate {
    /// Hide instead of closing, so playback continues and the window can be
    /// brought back with its frame and state intact.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        isPoppedOut = false
        onVisibilityChanged?(false)
        return false
    }

    func windowDidResize(_ notification: Notification) {
        reportFrame()
    }

    func windowDidMove(_ notification: Notification) {
        reportFrame()
    }

    private func reportFrame() {
        // Don't record the fullscreen frame - restoring it later would open the
        // window sized to the whole display.
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        onFrameChanged?(window.frame)
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Posted when the player window's pin state changes, so menu items and
    /// any on-screen toggle can re-read it.
    static let playerWindowPinDidChange = Notification.Name("playerWindowPinDidChange")
}

// MARK: - PlayerWindowContent

/// SwiftUI content hosted inside the player window.
struct PlayerWindowContent: View {
    @ObservedObject var playbackEngine: PlaybackEngine
    @ObservedObject var settings: AppSettings
    let onTogglePin: () -> Void
    let onToggleFullScreen: () -> Void
    let onCollapse: () -> Void
    let onDropURLs: ([URL]) -> Void
    let onDropProviders: ([NSItemProvider]) -> Bool

    @EnvironmentObject private var dragContext: DragContext

    @State private var isHovered = false
    @State private var isDropTargeted = false

    var body: some View {
        ZStack {
            VideoContentViewForEngine(
                playbackEngine: playbackEngine,
                showTimecode: settings.showTimecodeOverlay,
                overlayPosition: settings.timecodeOverlayPosition,
                overlayOpacity: settings.timecodeOverlayOpacity
            )

            if isHovered {
                controlsOverlay
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .onHover { hovering in
            withAnimation(AppAnimations.quick) {
                isHovered = hovering
            }
        }
        .onDrop(of: [UTType.fileURL, UTType.url, UTType.projectorMediaItem], isTargeted: $isDropTargeted) { providers in
            // Same contract as the old embedded playback area: internal drags
            // carry their URLs in DragContext; Finder drags go through the
            // import coordinator.
            if dragContext.isDragging && !dragContext.mediaItems.isEmpty {
                onDropURLs(dragContext.mediaItems.map { $0.url })
                dragContext.end()
                return true
            }
            return onDropProviders(providers)
        }
        .overlay {
            DropTargetOverlay(isTargeted: $isDropTargeted)
        }
        .animation(AppAnimations.quick, value: isDropTargeted)
    }

    private var controlsOverlay: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()

                HStack(spacing: Spacing.sm) {
                    pinButton
                    FullScreenToggleButton(isFullScreen: false, action: onToggleFullScreen)
                    collapseButton
                }
            }
            .padding(Spacing.md)
        }
        .transition(.opacity)
    }

    /// Hides the window. The titlebar is transparent over the video, so the
    /// close button is easy to miss - this is the discoverable equivalent.
    private var collapseButton: some View {
        Button(action: onCollapse) {
            Image(systemName: "pip.exit")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white)
                .frame(width: 32, height: 32)
                .background(Color.white.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help("Collapse the player - playback continues")
        .accessibilityLabel("Collapse player window")
    }

    private var pinButton: some View {
        Button(action: onTogglePin) {
            Image(systemName: settings.playerWindowPinnedToFront ? "pin.fill" : "pin.slash")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(settings.playerWindowPinnedToFront ? AppColors.accent : .white)
                .frame(width: 32, height: 32)
                .background(Color.white.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        // Plain button over an opaque background, not a glassEffect surface,
        // so the system tooltip fires here.
        .help(settings.playerWindowPinnedToFront
              ? "Unlock from foreground"
              : "Keep this window in front of all apps")
        .accessibilityLabel(settings.playerWindowPinnedToFront
                            ? "Unlock player from foreground"
                            : "Lock player to foreground")
    }
}

// MARK: - Preview

#if DEBUG
struct PlayerWindowContent_Previews: PreviewProvider {
    static var previews: some View {
        PlayerWindowContent(
            playbackEngine: PlaybackEngine(),
            settings: AppSettings.shared,
            onTogglePin: {},
            onToggleFullScreen: {},
            onCollapse: {},
            onDropURLs: { _ in },
            onDropProviders: { _ in false }
        )
        .environmentObject(DragContext())
        .frame(width: 640, height: 360)
    }
}
#endif

// MARK: - InlineVideoArea

/// The video, shown in the main window.
///
/// One video instance exists in the app. An `AVPlayer` can only drive a single
/// `AVPlayerView` at a time - attaching a second blanks the first - so this view
/// renders the picture only while `PlayerWindowController.isPoppedOut` is false,
/// and stands down to a placeholder when the player is in its own window.
///
/// The transport controls sit *on* the video, revealed on hover, matching the
/// player window's own overlay. They replaced the separate controls bar that
/// used to run across the top of the main window: with the timecode readouts
/// moved into the timeline header, play/stop and pop-out were all that remained
/// of it, and a full-width bar for two buttons was mostly empty space.
struct InlineVideoArea: View {
    @ObservedObject var playbackEngine: PlaybackEngine
    @ObservedObject var midiSyncViewModel: MIDISyncViewModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var playerWindow: PlayerWindowController

    let onDropURLs: ([URL]) -> Void
    let onDropProviders: ([NSItemProvider]) -> Bool

    /// Offers to install a missing codec.
    ///
    /// Only the inline area carries this. The import alert is the primary way in; this
    /// is the way back for someone who dismissed it, and duplicating it in the popped
    /// out player as well would make three routes to the same sheet.
    let onInstallCodec: () -> Void

    @EnvironmentObject private var dragContext: DragContext

    @State private var isDropTargeted = false

    var body: some View {
        picture
        // Fills whatever the section authority gives the video column, rather
        // than naming a size. A fixed frame here would have won over the
        // column's own frame, pinning the picture at its reference 480x270 while
        // the column around it grew with the window.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [UTType.fileURL, UTType.url, UTType.projectorMediaItem], isTargeted: $isDropTargeted) { providers in
            // Same contract as the player window: internal drags carry their
            // URLs in DragContext, Finder drags go through the import path.
            if dragContext.isDragging && !dragContext.mediaItems.isEmpty {
                onDropURLs(dragContext.mediaItems.map { $0.url })
                dragContext.end()
                return true
            }
            return onDropProviders(providers)
        }
        .overlay {
            DropTargetOverlay(isTargeted: $isDropTargeted)
        }
        .animation(AppAnimations.quick, value: isDropTargeted)
    }

    private var picture: some View {
        ZStack {
            if playerWindow.isPoppedOut {
                poppedOutPlaceholder
            } else {
                VideoContentViewForEngine(
                    playbackEngine: playbackEngine,
                    showTimecode: settings.showTimecodeOverlay,
                    overlayPosition: settings.timecodeOverlayPosition,
                    overlayOpacity: settings.timecodeOverlayOpacity,
                    onInstallCodec: onInstallCodec
                )
            }

            // Always mounted, never visible: this carries the spacebar binding,
            // which has to survive the video being popped out and must not
            // depend on the hover overlay being on screen.
            Button(action: { playbackEngine.togglePlayback() }) { EmptyView() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(midiSyncViewModel.isExternallyControlled)
                .frame(width: 0, height: 0)
                .opacity(0)

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Controls overlay - always visible, bottom-right corner
        .overlay(alignment: .bottomTrailing) {
            if !playerWindow.isPoppedOut {
                HStack(spacing: 4) {
                    fullScreenButton
                    popOutButton
                }
                .padding(5)
            }
        }
    }

    // MARK: - Popped-Out Placeholder

    private var poppedOutPlaceholder: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "pip.exit")
                .font(Typography.iconLarge)
                .foregroundColor(AppColors.textTertiary)
            Text("Playing in a separate window")
                .font(Typography.bodySmall)
                .foregroundColor(AppColors.textTertiary)
        }
    }

    /// Run/stop state, and the control for it.
    ///
    /// Green play while running, red stop when not - the state is readable
    /// without hovering the icon. Disabled while an external device drives the
    /// transport: the DAW owns the playhead then, and a local toggle would be
    /// overwritten by the next incoming frame.
    private var playStopButton: some View {
        Button(action: { playbackEngine.togglePlayback() }) {
            Image(systemName: playbackEngine.isPlaying ? "play.fill" : "stop.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(playbackEngine.isPlaying ? AppColors.accentGreen : AppColors.error)
                .frame(width: 32, height: 32)
                .background(AppColors.overlayDarker)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topTrailing) {
                    // Slave-mode marker: without it a dead control is
                    // indistinguishable from a broken one.
                    if midiSyncViewModel.isExternallyControlled {
                        Image(systemName: "link")
                            .font(Typography.iconTiny)
                            .foregroundColor(.white.opacity(0.8))
                            .padding(3)
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(midiSyncViewModel.isExternallyControlled)
        .help(transportHelp)
        .accessibilityLabel(transportHelp)
    }

    private var transportHelp: String {
        let running = playbackEngine.isPlaying ? "Running" : "Stopped"
        guard midiSyncViewModel.isExternallyControlled else {
            return "\(running) - Space to \(playbackEngine.isPlaying ? "pause" : "play")"
        }
        return "\(running) - slaved to incoming MTC/MMC, local transport disabled"
    }

    /// Fills the display with the picture.
    ///
    /// Fullscreen needs a window of its own - inline, the video is one column of
    /// the main window's layout, so making *that* fullscreen would just enlarge
    /// the whole app. This pops the player out first and takes the new window
    /// fullscreen, which is what the button is understood to mean over video.
    private var fullScreenButton: some View {
        FullScreenToggleButton(isFullScreen: false) {
            playerWindow.show()
            // A frame later: the window has to exist and be ordered in before
            // AppKit will take it fullscreen.
            DispatchQueue.main.async {
                playerWindow.toggleFullScreen()
            }
        }
        .help("Play full screen")
        .accessibilityLabel("Play full screen")
    }

    /// Moves the video between this window and its own, never duplicating it.
    private var popOutButton: some View {
        Button(action: {
            if playerWindow.isPoppedOut {
                playerWindow.hide()
            } else {
                playerWindow.show()
            }
        }) {
            // Pop out: pip.enter; Pop in: pip.exit (inverse)
            Image(systemName: playerWindow.isPoppedOut
                  ? "pip.exit"
                  : "pip.enter")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white)
                .frame(width: 32, height: 32)
                .background(Color.white.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .help(playerWindow.isPoppedOut
              ? "Bring the video back into the main window"
              : "Pop the video out into its own window")
        .accessibilityLabel(playerWindow.isPoppedOut ? "Return video to main window" : "Pop video out")
    }
}

// MARK: - VideoFrameRateChip

/// Frame rate, shown over the picture.
///
/// Sits bottom-leading in both video overlays - inline and popped out - so it
/// travels with the picture rather than staying behind in the main window. It
/// describes the media being shown, so wherever that is, this belongs.
///
/// Sized to match the overlay buttons (32pt tall, same dark chip and corner
/// radius) so the overlay reads as one row of like elements.
struct VideoFrameRateChip: View {
    let frameRate: TimecodeFrameRate

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Text("FPS")
                .font(Typography.labelSmall)
                .foregroundColor(.white.opacity(0.6))

            Text(frameRate.displayName)
                .font(TransportTypography.value)
                .foregroundColor(.white)
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, Spacing.sm)
        .frame(height: 32)
        .background(AppColors.overlayDarker)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .help("Frame rate is set by the video file")
        .accessibilityLabel("Frame rate: \(frameRate.displayName) frames per second")
    }
}
