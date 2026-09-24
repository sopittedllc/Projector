// The inline player, resizable monitor, and single-display presentation.
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SwiftTimecodeCore

@MainActor
final class PlayerWindowController: NSObject, ObservableObject {
    static let shared = PlayerWindowController()
    @Published private(set) var isPoppedOut = false
    @Published private(set) var isPresentingFullScreen = false

    private(set) var window: PlayerVideoWindow?
    private(set) var fullScreenView: FullScreenVideoView?
    private var fullScreenHost: NSWindow?
    private var fullScreenKeyMonitor: Any?
    private weak var presentationSource: NSWindow?
    private weak var popOutSource: NSWindow?
    private var presentingPopOut = false
    private var playbackEngine: PlaybackEngine?
    private var settings: AppSettings?
    private var midiSyncViewModel: MIDISyncViewModel?
    private var dragContext: DragContext?
    private var onDropURLs: (([URL]) -> Void)?
    private var onDropProviders: (([NSItemProvider]) -> Bool)?
    private var savedWindowFrame: CGRect?
    private(set) var isPinnedToFront = false
    var onVisibilityChanged: ((Bool) -> Void)?
    var onFrameChanged: ((CGRect) -> Void)?

    override init() { super.init() }

    func configure(playbackEngine: PlaybackEngine, settings: AppSettings,
                   midiSyncViewModel: MIDISyncViewModel, dragContext: DragContext,
                   onDropURLs: @escaping ([URL]) -> Void,
                   onDropProviders: @escaping ([NSItemProvider]) -> Bool) {
        self.playbackEngine = playbackEngine
        self.settings = settings
        self.midiSyncViewModel = midiSyncViewModel
        self.dragContext = dragContext
        self.onDropURLs = onDropURLs
        self.onDropProviders = onDropProviders
        setPinnedToFront(settings.playerWindowPinnedToFront)
    }

    private func togglePlayback() {
        guard midiSyncViewModel?.isExternallyControlled == false else { return }
        playbackEngine?.togglePlayback()
    }

    private func createWindow() {
        guard let playbackEngine, let settings, let dragContext else { return }
        let window = PlayerVideoWindow(
            contentRect: CGRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Player"
        window.identifier = NSUserInterfaceItemIdentifier("player-pop-out")
        window.isReleasedWhenClosed = false
        window.contentMinSize = CGSize(width: 320, height: 180)
        window.backgroundColor = .black
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.fullScreenPrimary]
        window.delegate = self
        window.onTogglePlayback = { [weak self] in self?.togglePlayback() }
        window.onFullScreen = { [weak self, weak window] in
            guard let self, let window else { return }
            self.showFullScreen(from: window)
        }
        // Retain the standard green button and route it to the same presentation
        // as the inline Full Screen action. AppKit still owns normal window chrome.
        window.standardWindowButton(.zoomButton)?.target = window
        window.standardWindowButton(.zoomButton)?.action = #selector(PlayerVideoWindow.toggleFullScreen(_:))
        window.setPlayerContent(PlayerWindowContent(
            playbackEngine: playbackEngine, settings: settings, playerWindow: self,
            onTogglePin: { [weak self] in self?.togglePinnedToFront() },
            onDropURLs: { [weak self] in self?.onDropURLs?($0) },
            onDropProviders: { [weak self] in self?.onDropProviders?($0) ?? false }
        ).environmentObject(dragContext))
        self.window = window
        applyPinnedState()
    }

    /// Explicit view ownership determines the screen, never a stale key window.
    func show(from source: NSWindow? = nil) {
        popOutSource = source ?? NSApp.mainWindow
        let screen = source?.screen ?? NSApp.mainWindow?.screen ?? NSScreen.main
        show(on: screen)
    }

    func show(on screen: NSScreen?) {
        if window == nil { createWindow() }
        guard let window, let screen else { return }
        if !window.isVisible {
            let visible = screen.visibleFrame
            let size = savedWindowFrame?.size ?? window.frameRect(
                forContentRect: CGRect(x: 0, y: 0, width: 640, height: 360)).size
            let fitted = CGSize(width: min(max(size.width, 320), visible.width),
                                height: min(max(size.height, 202), visible.height))
            window.setFrame(CGRect(x: visible.midX - fitted.width / 2,
                                   y: visible.midY - fitted.height / 2,
                                   width: fitted.width, height: fitted.height), display: false)
        }
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        isPoppedOut = true
        onVisibilityChanged?(true)
    }

    var isVisible: Bool { window?.isVisible ?? false }
    var currentFrame: CGRect? { savedWindowFrame ?? window?.frame }

    func restoreFrame(_ rect: CGRect) {
        guard rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite,
              rect.width >= 320, rect.height >= 202 else { return }
        savedWindowFrame = rect
        window?.setFrame(rect, display: false)
    }

    func hide() {
        window?.orderOut(nil)
        isPoppedOut = false
        onVisibilityChanged?(false)
    }

    /// Independent, temporary presentation. No pop-out is created by this action.
    func showFullScreen(from source: NSWindow) {
        guard let screen = source.screen, let playbackEngine, let settings else { return }
        dismissFullScreen()
        let surface = FullScreenVideoView(frame: screen.frame)
        surface.onDismiss = { [weak self] in self?.dismissFullScreen() }
        let hosting = NSHostingView(rootView: VideoContentView(
            playbackEngine: playbackEngine, showTimecode: settings.showTimecodeOverlay,
            overlayPosition: settings.timecodeOverlayPosition,
            overlayOpacity: settings.timecodeOverlayOpacity))
        if #available(macOS 13.0, *) { hosting.sizingOptions = [] }
        surface.installVideo(hosting)
        // NSView restores to this host on exit. It is never ordered onscreen,
        // so Escape cannot expose a resized or newly created pop-out window.
        let host = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                            backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.delegate = self
        host.contentView = surface
        fullScreenHost = host
        fullScreenView = surface
        presentingPopOut = source === window
        presentationSource = presentingPopOut ? popOutSource : source
        if presentingPopOut { hide() }
        let entered = surface.enterFullScreenMode(screen, withOptions: [
            .fullScreenModeAllScreens: false,
            .fullScreenModeApplicationPresentationOptions:
                NSApplication.PresentationOptions([.autoHideDock, .autoHideMenuBar]).rawValue
        ])
        guard entered else {
            fullScreenView = nil
            fullScreenHost = nil
            if source === window { show(on: screen) }
            return
        }
        surface.window?.title = "Fullscreen Player"
        surface.window?.identifier = NSUserInterfaceItemIdentifier("player-full-screen")
        surface.window?.delegate = self
        surface.window?.makeKeyAndOrderFront(nil)
        isPresentingFullScreen = true
        if presentingPopOut {
            // The standard button's tracking completes after its action returns.
            // Hide the monitor after AppKit has finished that tracking cycle.
            DispatchQueue.main.async { [weak self, weak surface] in
                guard let self, let surface, self.fullScreenView === surface else { return }
                self.window?.orderOut(nil)
            }
        }
        fullScreenKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.fullScreenView?.window else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if (event.keyCode == 53 && modifiers.isEmpty)
                || (event.charactersIgnoringModifiers == "w" && modifiers == .command) {
                self.dismissFullScreen()
                return nil
            }
            if event.keyCode == 49 && modifiers.isEmpty {
                if !event.isARepeat { self.togglePlayback() }
                return nil
            }
            return event
        }
    }

    func dismissFullScreen() {
        guard let surface = fullScreenView else { return }
        if let monitor = fullScreenKeyMonitor { NSEvent.removeMonitor(monitor) }
        fullScreenKeyMonitor = nil
        if surface.isInFullScreenMode { surface.exitFullScreenMode(options: nil) }
        fullScreenHost?.orderOut(nil)
        fullScreenView = nil
        fullScreenHost = nil
        isPresentingFullScreen = false
        if presentingPopOut { hide() }
        presentingPopOut = false
        presentationSource?.makeKeyAndOrderFront(nil)
        presentationSource = nil
    }

    func setPinnedToFront(_ pinned: Bool) {
        settings?.playerWindowPinnedToFront = pinned
        isPinnedToFront = pinned
        applyPinnedState()
        NotificationCenter.default.post(name: .playerWindowPinDidChange, object: nil)
    }

    func togglePinnedToFront() { setPinnedToFront(!isPinnedToFront) }

    private func applyPinnedState() {
        window?.level = isPinnedToFront ? .floating : .normal
        window?.collectionBehavior = isPinnedToFront
            ? [.canJoinAllSpaces, .fullScreenPrimary] : [.fullScreenPrimary]
    }
}

extension PlayerWindowController: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === window { hide() } else { dismissFullScreen() }
        return false
    }

    func windowDidResize(_ notification: Notification) { reportFrame(notification) }
    func windowDidMove(_ notification: Notification) { reportFrame(notification) }

    private func reportFrame(_ notification: Notification) {
        guard let window, notification.object as? NSWindow === window else { return }
        savedWindowFrame = window.frame
        onFrameChanged?(window.frame)
    }
}

/// A view-based, single-screen presentation with native AppKit traffic lights.
/// No application-wide fullscreen Space or black shielding windows are requested.
final class FullScreenVideoView: NSView {
    var onDismiss: (() -> Void)?
    private let controls = NSVisualEffectView()
    private var topTrackingArea: NSTrackingArea?
    private(set) var closeButton: NSButton!
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        controls.material = .titlebar
        controls.blendingMode = .withinWindow
        controls.state = .active
        controls.isHidden = true
        for (index, kind) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let button = NSWindow.standardWindowButton(kind, for: [.titled, .closable, .miniaturizable, .resizable]) else { continue }
            button.setFrameOrigin(CGPoint(x: 12 + index * 20, y: 12))
            button.target = self
            button.action = #selector(dismissPresentation)
            button.isEnabled = kind != .miniaturizeButton
            controls.addSubview(button)
            if kind == .closeButton {
                closeButton = button
                button.setAccessibilityIdentifier("player-full-screen-close")
                button.setAccessibilityLabel("Close Fullscreen Player")
            }
        }
        addSubview(controls)
    }

    required init?(coder: NSCoder) { nil }

    func installVideo(_ view: NSView) {
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view, positioned: .below, relativeTo: controls)
    }

    override func layout() {
        super.layout()
        controls.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 40)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let topTrackingArea { removeTrackingArea(topTrackingArea) }
        let area = NSTrackingArea(rect: CGRect(x: 0, y: 0, width: bounds.width, height: 40),
                                  options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        topTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { controls.isHidden = false }
    override func mouseExited(with event: NSEvent) { controls.isHidden = true }
    var areControlsVisible: Bool { !controls.isHidden }
    @objc private func dismissPresentation() { onDismiss?() }
}

/// Captures the window that actually owns the inline controls.
struct PlayerSourceWindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void
    func makeNSView(context: Context) -> SourceView {
        let view = SourceView()
        view.onWindow = onWindow
        return view
    }
    func updateNSView(_ nsView: SourceView, context: Context) {}
    final class SourceView: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let owner = window
            DispatchQueue.main.async { [weak self] in self?.onWindow?(owner) }
        }
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
    @ObservedObject var playerWindow: PlayerWindowController
    let onTogglePin: () -> Void
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
                }
            }
            .padding(Spacing.md)
        }
        .transition(.opacity)
    }

    private var pinButton: some View {
        Button(action: onTogglePin) {
            Image(systemName: settings.playerWindowPinnedToFront ? "pin.fill" : "pin.slash")
                .font(Typography.buttonLarge)
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
            playerWindow: .shared,
            onTogglePin: {},
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
    @State private var sourceWindow: NSWindow?

    var body: some View {
        picture
        .background(PlayerSourceWindowReader { sourceWindow = $0 })
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
            VideoContentViewForEngine(
                playbackEngine: playbackEngine,
                showTimecode: settings.showTimecodeOverlay,
                overlayPosition: settings.timecodeOverlayPosition,
                overlayOpacity: settings.timecodeOverlayOpacity,
                onInstallCodec: onInstallCodec
            )

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
            HStack(spacing: Spacing.xs) {
                fullScreenButton
                popOutButton
            }
            .padding(CompactControlLayout.overlayPadding)
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
                .font(Typography.buttonLarge)
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
                            .padding(CompactControlLayout.badgeInset)
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

    /// Fullscreen presentation is independent of the resizable pop-out.
    private var fullScreenButton: some View {
        FullScreenToggleButton(isFullScreen: false) {
            guard let sourceWindow else { return }
            playerWindow.showFullScreen(from: sourceWindow)
        }
        .help("Full Screen")
        .accessibilityLabel("Full Screen")
        .accessibilityIdentifier("player-enter-full-screen")
    }

    /// Shows or hides the additional video window.
    private var popOutButton: some View {
        Button(action: {
            if playerWindow.isPoppedOut {
                playerWindow.hide()
            } else {
                playerWindow.show(from: sourceWindow)
            }
        }) {
            // Pop out: pip.enter; Pop in: pip.exit (inverse)
            Image(systemName: playerWindow.isPoppedOut
                  ? "pip.exit"
                  : "pip.enter")
                .font(Typography.buttonLarge)
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
              ? "Hide the separate player window"
              : "Pop the video out into its own window")
        .accessibilityLabel(playerWindow.isPoppedOut ? "Hide separate player" : "Pop video out")
        .accessibilityIdentifier("player-pop-out-button")
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
        .frame(height: TransportLayout.frameRatePillHeight)
        .background(AppColors.overlayDarker)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .help("Frame rate is set by the video file")
        .accessibilityLabel("Frame rate: \(frameRate.displayName) frames per second")
    }
}

/// Handles transport before any focused view can consume the spacebar.
final class PlayerVideoWindow: NSWindow {
    var onTogglePlayback: (() -> Void)?
    var onFullScreen: (() -> Void)?

    override func toggleFullScreen(_ sender: Any?) { onFullScreen?() }

    /// The window owns sizing; SwiftUI content fills the bounds it receives.
    /// Content-derived constraints can otherwise feed back into window sizing
    /// when the titlebar and display-sized frame change together.
    func setPlayerContent<Content: View>(_ content: Content) {
        let hostingView = NSHostingView(rootView: content)
        if #available(macOS 13.0, *) {
            hostingView.sizingOptions = []
        }
        contentView = hostingView
    }

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown,
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            if event.keyCode == 49 {
                if !event.isARepeat { onTogglePlayback?() }
                return
            }

        }
        super.sendEvent(event)
    }
}
