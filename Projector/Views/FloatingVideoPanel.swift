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
final class PlayerWindowController: NSObject {
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
        onDropURLs: @escaping ([URL]) -> Void,
        onDropProviders: @escaping ([NSItemProvider]) -> Bool
    ) {
        self.playbackEngine = playbackEngine
        self.settings = settings
        self.onDropURLs = onDropURLs
        self.onDropProviders = onDropProviders

        if window == nil {
            createWindow()
        }
        applyPinnedState(settings.playerWindowPinnedToFront)
    }

    private func createWindow() {
        guard let playbackEngine, let settings else { return }

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
        window.contentView = NSHostingView(rootView: content)

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
                overlayOpacity: settings.timecodeOverlayOpacity,
                extraTrailingPadding: 0
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
                .padding(Spacing.md)
            }
        }
        .transition(.opacity)
    }

    /// Hides the window. The titlebar is transparent over the video, so the
    /// close button is easy to miss - this is the discoverable equivalent.
    private var collapseButton: some View {
        Button(action: onCollapse) {
            Image(systemName: "chevron.down.circle")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white)
                .frame(width: 32, height: 32)
                .background(AppColors.overlayDarker)
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
                .background(AppColors.overlayDarker)
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
