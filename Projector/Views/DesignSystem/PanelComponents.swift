//
//  PanelComponents.swift
//  Projector
//
//  Reusable panel components that enforce consistent layout.
//  USE THESE instead of building panel structures ad-hoc.
//

import SwiftUI

// MARK: - Standard Panel Container

/// A reusable glass panel with header, optional divider, and content area.
/// Enforces consistent padding, sizing, and visual rhythm.
///
/// Usage:
/// ```swift
/// StandardPanel(
///     title: "Media",
///     titleIcon: "folder",
///     isExpanded: $isExpanded,
///     headerTrailing: { ImportButton() }
/// ) {
///     // Content goes here - automatically padded and centered
///     MediaGridView()
/// }
/// ```
struct StandardPanel<HeaderTrailing: View, Content: View>: View {
    let title: String
    var titleIcon: String? = nil
    var itemCount: Int? = nil
    @Binding var isExpanded: Bool
    let headerTrailing: () -> HeaderTrailing
    let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            // Header
            panelHeader

            // Content (only when expanded)
            if isExpanded {
                Divider()
                PanelContentArea {
                    content()
                }
            }
        }
        .glassPanel()
    }

    private var panelHeader: some View {
        HStack(spacing: Spacing.sm) {
            // Chevron
            Button(action: { withAnimation(AppAnimations.standard) { isExpanded.toggle() } }) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(Typography.icon)
                    .foregroundColor(.secondary)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)

            // Icon
            if let icon = titleIcon {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }

            // Title + count
            HStack(spacing: Spacing.xs) {
                Text(title)
                    .font(Typography.heading)
                    .foregroundColor(.primary)

                if let count = itemCount {
                    Text("(\(count))")
                        .font(Typography.body)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // Trailing content
            headerTrailing()
        }
        .frame(height: PanelLayout.headerHeight)
        .padding(.horizontal, Spacing.md)
    }
}

// MARK: - Panel Content Area

/// Wraps panel content with consistent padding and centering.
/// Empty states automatically center both horizontally and vertically.
struct PanelContentArea<Content: View>: View {
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(Spacing.md) // Equal padding on all sides
    }
}

// MARK: - Empty State View

/// Standard empty state presentation for panels.
/// Automatically centers content and uses consistent styling.
struct PanelEmptyState: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundColor(.secondary.opacity(0.5))

            Text(title)
                .font(Typography.heading)
                .foregroundColor(.secondary)

            Text(subtitle)
                .font(Typography.bodySmall)
                .foregroundColor(.secondary.opacity(0.7))
        }
    }
}

// MARK: - Three-Column Control Bar

/// A control bar with left, center, and right sections.
/// Center content is ALWAYS truly centered regardless of left/right width.
///
/// Usage:
/// ```swift
/// ThreeColumnBar(
///     left: { TimecodeControls() },
///     center: { TransportButtons() },
///     right: { SettingsButton() }
/// )
/// ```
struct ThreeColumnBar<Left: View, Center: View, Right: View>: View {
    let left: () -> Left
    let center: () -> Center
    let right: () -> Right

    var body: some View {
        HStack(spacing: 0) {
            // Left section - flexible width, left-aligned
            HStack { left() }
                .frame(maxWidth: .infinity, alignment: .leading)

            // Center section - intrinsic width, centered
            center()

            // Right section - flexible width, right-aligned
            HStack { right() }
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .glassPanel()
    }
}

// MARK: - Convenience Extensions

extension StandardPanel where HeaderTrailing == EmptyView {
    /// Creates a panel with no trailing header content.
    init(
        title: String,
        titleIcon: String? = nil,
        itemCount: Int? = nil,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.titleIcon = titleIcon
        self.itemCount = itemCount
        self._isExpanded = isExpanded
        self.headerTrailing = { EmptyView() }
        self.content = content
    }
}

// MARK: - Preview

#Preview("Panel Components") {
    VStack(spacing: Spacing.lg) {
        // Standard panel with content
        StandardPanel(
            title: "Media",
            titleIcon: "folder",
            itemCount: 0,
            isExpanded: .constant(true),
            headerTrailing: {
                Button("+ Import") {}
                    .buttonStyle(GlassActionButtonStyle())
            }
        ) {
            PanelEmptyState(
                icon: "film",
                title: "No media files",
                subtitle: "Drop files here or click Import"
            )
        }
        .frame(height: 180)

        // Three-column bar
        ThreeColumnBar(
            left: {
                HStack(spacing: Spacing.md) {
                    Text("Start TC: 00:00:00:00")
                    Text("Duration: 04:00:00:00")
                }
                .font(.system(size: 12, design: .monospaced))
            },
            center: {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "play.fill")
                    Image(systemName: "stop.fill")
                }
                .font(.system(size: 14))
            },
            right: {
                Image(systemName: "gearshape")
            }
        )
    }
    .padding(Spacing.lg)
    .frame(width: 800, height: 400)
    .background(Color.black.opacity(0.9))
}
