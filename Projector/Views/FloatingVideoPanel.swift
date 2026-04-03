//
//  FloatingVideoPanel.swift
//  Projector
//
//  Floating video window that pops out from the main interface.
//  Uses NSPanel for utility window behavior (non-activating, floats above).
//

import SwiftUI
import AppKit

// MARK: - FloatingVideoPanelController

/// Controller for the floating video panel window
///
/// This singleton manages the floating video window lifecycle.
/// The panel is non-activating (doesn't steal focus) and floats above
/// regular windows for convenient multi-monitor workflows.
///
/// ## Usage
/// ```swift
/// FloatingVideoPanelController.shared.showPanel(
///     playbackEngine: engine,
///     settings: settings,
///     onClose: { isVideoFloating = false }
/// )
/// ```
@MainActor
final class FloatingVideoPanelController {
    static let shared = FloatingVideoPanelController()

    private var panel: NSPanel?
    private var onCloseCallback: (() -> Void)?

    private init() {}

    /// Show the floating video panel
    /// - Parameters:
    ///   - playbackEngine: The playback engine to display video from
    ///   - settings: App settings for overlay configuration
    ///   - onClose: Callback when panel is closed
    func showPanel(
        playbackEngine: PlaybackEngine,
        settings: AppSettings,
        onClose: @escaping () -> Void
    ) {
        // Close existing panel if any
        closePanel()

        self.onCloseCallback = onClose

        // Create the panel with utility window style
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.title = "Video Monitor"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Set minimum size for usability
        panel.minSize = NSSize(width: 320, height: 180)

        // Apply appearance
        panel.backgroundColor = NSColor.black
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden

        // Create the SwiftUI content
        let content = FloatingVideoContent(
            playbackEngine: playbackEngine,
            settings: settings,
            onReturnToMain: { [weak self] in
                self?.closePanel()
            }
        )

        panel.contentView = NSHostingView(rootView: content)

        // Center on screen
        panel.center()

        // Set delegate to handle close button
        panel.delegate = FloatingPanelDelegate.shared
        FloatingPanelDelegate.shared.onClose = { [weak self] in
            self?.handlePanelClose()
        }

        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    /// Close the floating video panel
    func closePanel() {
        panel?.close()
        panel = nil
    }

    private func handlePanelClose() {
        panel = nil
        onCloseCallback?()
        onCloseCallback = nil
    }
}

// MARK: - Panel Delegate

/// Delegate to handle panel events
private class FloatingPanelDelegate: NSObject, NSWindowDelegate {
    static let shared = FloatingPanelDelegate()

    var onClose: (() -> Void)?

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

// MARK: - FloatingVideoContent

/// SwiftUI content for the floating video panel
struct FloatingVideoContent: View {
    @ObservedObject var playbackEngine: PlaybackEngine
    @ObservedObject var settings: AppSettings
    let onReturnToMain: () -> Void

    @State private var isHovered = false

    var body: some View {
        ZStack {
            // Video player
            VideoContentViewForEngine(
                playbackEngine: playbackEngine,
                showTimecode: settings.showTimecodeOverlay,
                overlayPosition: settings.timecodeOverlayPosition,
                overlayOpacity: settings.timecodeOverlayOpacity,
                extraTrailingPadding: 0
            )

            // Hover controls overlay
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
    }

    private var controlsOverlay: some View {
        VStack {
            Spacer()

            HStack {
                Spacer()

                // Return to main window button
                Button(action: onReturnToMain) {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "rectangle.portrait.and.arrow.left")
                            .font(.system(size: 12, weight: .medium))
                        Text("Return")
                            .font(Typography.buttonSmall)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.sm)
                    .background(AppColors.overlayDarker)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .padding(Spacing.md)
            }
        }
        .transition(.opacity)
    }
}

// MARK: - Preview

#if DEBUG
struct FloatingVideoContent_Previews: PreviewProvider {
    static var previews: some View {
        FloatingVideoContent(
            playbackEngine: PlaybackEngine(),
            settings: AppSettings.shared,
            onReturnToMain: {}
        )
        .frame(width: 640, height: 360)
    }
}
#endif
