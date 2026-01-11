import SwiftUI
import AppKit

// MARK: - Drop Target Overlay

/// Overlay displayed when media files are being dragged over the video player area.
///
/// Shows a dashed border with an icon and text prompt to indicate the drop zone is active.
///
/// - Parameter isTargeted: Binding that indicates whether a drag operation is currently targeting this area.
struct DropTargetOverlay: View {
    @Binding var isTargeted: Bool

    var body: some View {
        if isTargeted {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.accentColor.opacity(0.15))
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 4]))
                VStack(spacing: 12) {
                    Image(systemName: "arrow.down.doc.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.accentColor)
                    Text("Drop media to import")
                        .font(.headline)
                        .foregroundColor(.accentColor)
                }
            }
            .padding(8)
        }
    }
}

// MARK: - Loading Overlay

/// Overlay displayed while media is being loaded.
///
/// Shows a semi-transparent background with a progress spinner and "Loading media..." text.
///
/// - Parameter isLoading: Whether the loading overlay should be visible.
struct LoadingOverlay: View {
    let isLoading: Bool

    var body: some View {
        if isLoading {
            ZStack {
                Color.black.opacity(0.5)

                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))

                    Text("Loading media...")
                        .font(.headline)
                        .foregroundColor(.white)
                }
                .padding(32)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.black.opacity(0.7))
                )
            }
        }
    }
}

// MARK: - Playback Resize Handle

/// A draggable handle for resizing the playback area height.
///
/// Displays a thin horizontal line at the bottom of the video player that can be dragged
/// to adjust the playback height. Changes cursor to resize indicator on hover.
///
/// - Parameters:
///   - playbackHeight: Binding to the current playback area height (nil means natural height).
///   - playbackMeasuredHeight: The measured natural height of the playback area.
///   - minHeight: Minimum allowed height for the playback area.
///   - maxHeight: Maximum allowed height for the playback area.
///   - isResizing: Binding indicating whether a resize operation is in progress.
struct PlaybackResizeHandle: View {
    @Binding var playbackHeight: CGFloat?
    let playbackMeasuredHeight: CGFloat
    let minHeight: CGFloat
    let maxHeight: CGFloat
    @Binding var isResizing: Bool

    @State private var isHovering = false
    @State private var dragStartHeight: CGFloat = 0
    @State private var dragStartLocationY: CGFloat = 0
    @State private var didPushCursorForDrag = false

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 10)
            .contentShape(Rectangle())
            .overlay {
                Rectangle()
                    .fill(isResizing ? Color.accentColor : Color.white.opacity(0.25))
                    .frame(height: 1)
            }
            .onHover { hovering in
                guard !isResizing else { return }
                if hovering, !isHovering {
                    NSCursor.resizeUpDown.push()
                    isHovering = true
                } else if !hovering, isHovering {
                    NSCursor.pop()
                    isHovering = false
                }
            }
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        if !isResizing {
                            dragStartHeight = playbackHeight ?? playbackMeasuredHeight
                            dragStartLocationY = value.startLocation.y
                            isResizing = true
                            if !isHovering {
                                NSCursor.resizeUpDown.push()
                                didPushCursorForDrag = true
                            } else {
                                didPushCursorForDrag = false
                            }
                        }
                        let delta = value.location.y - dragStartLocationY
                        let proposedHeight = dragStartHeight + delta
                        playbackHeight = min(maxHeight, max(minHeight, proposedHeight))
                    }
                    .onEnded { _ in
                        isResizing = false
                        if didPushCursorForDrag {
                            NSCursor.pop()
                        }
                        didPushCursorForDrag = false
                    }
            )
    }
}

// MARK: - Full Screen Toggle Button

/// A circular button for entering or exiting full-screen mode.
///
/// Displays an arrow icon indicating the toggle direction, styled as a semi-transparent
/// circular button.
///
/// - Parameters:
///   - isFullScreen: Whether the app is currently in full-screen mode.
///   - action: Closure called when the button is tapped.
struct FullScreenToggleButton: View {
    let isFullScreen: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isFullScreen
                  ? "arrow.down.right.and.arrow.up.left"
                  : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white)
                .padding(10)
                .background(
                    Circle()
                        .fill(Color.black.opacity(0.6))
                )
        }
        .buttonStyle(.plain)
        .padding(20)
        .opacity(0.7)
        .help(isFullScreen ? "Exit Full Screen" : "Enter Full Screen")
    }
}

// MARK: - Previews

#Preview("Drop Target Overlay") {
    ZStack {
        Color.gray
        DropTargetOverlay(isTargeted: .constant(true))
    }
    .frame(width: 400, height: 300)
}

#Preview("Loading Overlay") {
    ZStack {
        Color.gray
        LoadingOverlay(isLoading: true)
    }
    .frame(width: 400, height: 300)
}

#Preview("Full Screen Toggle Button - Normal") {
    ZStack {
        Color.gray
        FullScreenToggleButton(isFullScreen: false, action: {})
    }
    .frame(width: 100, height: 100)
}

#Preview("Full Screen Toggle Button - Full Screen") {
    ZStack {
        Color.gray
        FullScreenToggleButton(isFullScreen: true, action: {})
    }
    .frame(width: 100, height: 100)
}
