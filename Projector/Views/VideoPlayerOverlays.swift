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
            }
            .padding(Spacing.sm)
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

                VStack(spacing: Spacing.lg) {
                    ProgressView()
                        .scaleEffect(1.5)
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))

                    Text("Loading media...")
                        .font(.headline)
                        .foregroundColor(.white)
                }
                .padding(Spacing.xxl)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.black.opacity(0.7))
                )
            }
        }
    }
}

// The main window's one draggable boundary is ContentView's section splitter,
// which stores a share of the window rather than a fixed height.

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
