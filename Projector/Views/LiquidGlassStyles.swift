//
//  LiquidGlassStyles.swift
//  Projector
//
//  Liquid Glass design system for macOS Tahoe (26+) with fallbacks.
//  Uses AppColors and AppAnimations from LayoutConstants.swift for consistency.
//

import SwiftUI
import AppKit

// MARK: - Glass Panel Background

/// A view modifier that applies Liquid Glass panel styling.
/// Uses native `.glassEffect()` on macOS 26+, falls back to NSVisualEffectView on older versions.
struct GlassPanelModifier: ViewModifier {
    var cornerRadius: CGFloat = PanelLayout.cornerRadius
    var borderOpacity: CGFloat = PanelLayout.borderOpacity

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .background {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(.clear)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
                }
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(Color.white.opacity(borderOpacity), lineWidth: PanelLayout.borderWidth)
                )
        } else {
            content
                .background(
                    ZStack {
                        LegacyVisualEffectBackground(cornerRadius: cornerRadius)
                        AppColors.glassFallback.opacity(0.85)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(Color.white.opacity(borderOpacity), lineWidth: PanelLayout.borderWidth)
                )
        }
    }
}

// MARK: - Glass Control Background

/// A view modifier for control groups (timecode, FPS displays, etc.)
struct GlassControlModifier: ViewModifier {
    var cornerRadius: CGFloat = 6
    var isHighlighted: Bool = false

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .background {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(.clear)
                        .glassEffect(
                            isHighlighted ? .regular.tint(.accentColor) : .clear,
                            in: RoundedRectangle(cornerRadius: cornerRadius)
                        )
                }
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(AppColors.borderLight, lineWidth: PanelLayout.borderWidth)
                )
        } else {
            content
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(AppColors.borderStrong, lineWidth: PanelLayout.borderWidth)
                )
        }
    }
}

// MARK: - Glass Button Style

/// A button style that applies Liquid Glass effects
struct GlassButtonStyle: ButtonStyle {
    var tint: Color?
    var cornerRadius: CGFloat = 6

    func makeBody(configuration: Configuration) -> some View {
        if #available(macOS 26, *) {
            configuration.label
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .background {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(.clear)
                        .glassEffect(
                            tint != nil ? .regular.tint(tint!) : .regular,
                            in: RoundedRectangle(cornerRadius: cornerRadius)
                        )
                }
                .opacity(configuration.isPressed ? 0.7 : 1.0)
                .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
                .animation(AppAnimations.quick, value: configuration.isPressed)
        } else {
            configuration.label
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(tint?.opacity(0.2) ?? Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(AppColors.borderLight, lineWidth: PanelLayout.borderWidth)
                )
                .opacity(configuration.isPressed ? 0.7 : 1.0)
        }
    }
}

// MARK: - Glass Transport Button Style

/// A button style for transport controls (play, stop, etc.)
struct GlassTransportButtonStyle: ButtonStyle {
    var isActive: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        if #available(macOS 26, *) {
            configuration.label
                .padding(Spacing.sm)
                .background {
                    Circle()
                        .fill(.clear)
                        .glassEffect(
                            isActive ? .regular.tint(.accentColor) : .regular,
                            in: Circle()
                        )
                }
                .opacity(configuration.isPressed ? 0.7 : 1.0)
                .scaleEffect(configuration.isPressed ? 0.9 : 1.0)
                .animation(AppAnimations.spring, value: configuration.isPressed)
        } else {
            configuration.label
                .padding(Spacing.sm)
                .background(
                    Circle()
                        .fill(isActive ? Color.accentColor.opacity(0.2) : Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    Circle()
                        .stroke(AppColors.borderLight, lineWidth: PanelLayout.borderWidth)
                )
                .opacity(configuration.isPressed ? 0.7 : 1.0)
        }
    }
}

// MARK: - Glass Action Button Style

/// A button style for action buttons (Import, Optimize, etc.)
struct GlassActionButtonStyle: ButtonStyle {
    var tint: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        if #available(macOS 26, *) {
            configuration.label
                .font(Typography.button)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .background {
                    Capsule()
                        .fill(.clear)
                        .glassEffect(.regular.tint(tint), in: Capsule())
                }
                .opacity(configuration.isPressed ? 0.8 : 1.0)
                .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
                .animation(AppAnimations.quick, value: configuration.isPressed)
        } else {
            configuration.label
                .font(Typography.button)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .background(
                    Capsule()
                        .fill(tint.opacity(0.15))
                )
                .overlay(
                    Capsule()
                        .stroke(tint.opacity(0.3), lineWidth: PanelLayout.borderWidth)
                )
                .opacity(configuration.isPressed ? 0.8 : 1.0)
        }
    }
}

// MARK: - Glass Panel Header Style

/// A view modifier for panel headers (accordion sections, etc.)
struct GlassPanelHeaderModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(height: PanelLayout.headerHeight)
            .padding(.horizontal, Spacing.md)
            .background(AppColors.overlayDark)
            .overlay(
                Rectangle()
                    .frame(height: PanelLayout.borderWidth)
                    .foregroundColor(AppColors.borderSubtle),
                alignment: .bottom
            )
    }
}

// MARK: - Glass Depth System

/// A view modifier that applies depth/shadow for layered panels
struct GlassDepthModifier: ViewModifier {
    let level: Int

    func body(content: Content) -> some View {
        content
            .shadow(
                color: Color.black.opacity(Double(level) * 0.1),
                radius: CGFloat(level * 2),
                x: 0,
                y: CGFloat(level)
            )
    }
}

// MARK: - View Extensions

extension View {
    /// Apply Liquid Glass panel background
    func glassPanel(cornerRadius: CGFloat = 8, borderOpacity: CGFloat = 0.2) -> some View {
        modifier(GlassPanelModifier(cornerRadius: cornerRadius, borderOpacity: borderOpacity))
    }

    /// Apply Liquid Glass control background
    func glassControl(cornerRadius: CGFloat = 6, isHighlighted: Bool = false) -> some View {
        modifier(GlassControlModifier(cornerRadius: cornerRadius, isHighlighted: isHighlighted))
    }

    /// Apply standard panel header styling
    func glassPanelHeader() -> some View {
        modifier(GlassPanelHeaderModifier())
    }

    /// Apply depth/shadow for layered panels
    ///
    /// - Parameter level: Depth level (1 = subtle, 2 = moderate, 3 = prominent)
    func glassDepth(level: Int) -> some View {
        modifier(GlassDepthModifier(level: level))
    }
}

// MARK: - Window Glass Background

/// A full-window glass background for the main content area
struct WindowGlassBackground: View {
    var body: some View {
        if #available(macOS 26, *) {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
        } else {
            ZStack {
                LegacyWindowVisualEffect()
                AppColors.glassFallback.opacity(0.95)
            }
            .ignoresSafeArea()
        }
    }
}

/// Full-window NSVisualEffectView for fallback
private struct LegacyWindowVisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .titlebar
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = .titlebar
        nsView.blendingMode = .behindWindow
    }
}

// MARK: - Legacy Visual Effect (Fallback for pre-macOS 26)

/// NSVisualEffectView wrapper for fallback styling
private struct LegacyVisualEffectBackground: NSViewRepresentable {
    var cornerRadius: CGFloat = 8

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = .hudWindow
        nsView.blendingMode = .behindWindow
        nsView.layer?.cornerRadius = cornerRadius
    }
}

// MARK: - Glass Icon Button Style

/// A button style for icon-only buttons (settings gear, close, etc.)
struct GlassIconButtonStyle: ButtonStyle {
    var size: CGFloat = 18
    var isActive: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: size, height: size)
            .padding(Spacing.sm)
            .background {
                if #available(macOS 26, *) {
                    Circle()
                        .fill(.clear)
                        .glassEffect(
                            isActive ? .regular.tint(.accentColor) : .clear,
                            in: Circle()
                        )
                } else {
                    Circle()
                        .fill(isActive ? Color.accentColor.opacity(0.2) : Color.clear)
                }
            }
            .overlay(
                Circle()
                    .stroke(configuration.isPressed ? AppColors.borderStrong : AppColors.borderSubtle, lineWidth: PanelLayout.borderWidth)
            )
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.9 : 1.0)
            .animation(AppAnimations.quick, value: configuration.isPressed)
    }
}

// MARK: - Glass Toggle Button Style

/// A button style for toggle buttons that show on/off state
struct GlassToggleButtonStyle: ButtonStyle {
    var isOn: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.button)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .foregroundColor(isOn ? .white : .secondary)
            .background {
                if #available(macOS 26, *) {
                    Capsule()
                        .fill(.clear)
                        .glassEffect(
                            isOn ? .regular.tint(.accentColor) : .clear,
                            in: Capsule()
                        )
                } else {
                    Capsule()
                        .fill(isOn ? Color.accentColor.opacity(0.3) : Color.clear)
                }
            }
            .overlay(
                Capsule()
                    .stroke(isOn ? Color.accentColor : AppColors.borderLight, lineWidth: PanelLayout.borderWidth)
            )
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(AppAnimations.quick, value: configuration.isPressed)
    }
}

// MARK: - Reduced Motion Modifier

/// A view modifier that respects the user's reduced motion preference.
///
/// ## Usage
/// ```swift
/// withAnimation(reduceMotion ? nil : AppAnimations.standard) {
///     isExpanded.toggle()
/// }
/// ```
struct ReducedMotionModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    let animation: Animation

    func body(content: Content) -> some View {
        content
            .animation(reduceMotion ? nil : animation, value: UUID())
    }
}

extension View {
    /// Applies animation only if reduced motion is not enabled
    func animationWithReducedMotion(_ animation: Animation) -> some View {
        modifier(ReducedMotionModifier(animation: animation))
    }
}

// MARK: - Color Extensions for Glass

extension Color {
    /// Subtle glass-friendly text color
    static var glassLabel: Color {
        Color.primary
    }

    /// Secondary glass-friendly text color
    static var glassSecondaryLabel: Color {
        Color.secondary
    }
}

// MARK: - Preview

#Preview("Glass Styles") {
    VStack(spacing: Spacing.xl) {
        // Panel
        VStack {
            Text("Glass Panel")
                .font(.headline)
            Text("Content goes here")
                .foregroundColor(.secondary)
        }
        .padding()
        .glassPanel()

        // Controls
        HStack(spacing: Spacing.md) {
            HStack {
                Text("TC:")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Text("01:00:00:00")
                    .font(.system(size: 12, design: .monospaced))
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .glassControl()

            HStack {
                Text("FPS:")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Text("24")
                    .font(.system(size: 12, design: .monospaced))
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .glassControl()
        }

        // Buttons
        HStack(spacing: Spacing.md) {
            Button("Import") {}
                .buttonStyle(GlassActionButtonStyle(tint: .accentColor))

            Button("Optimize") {}
                .buttonStyle(GlassActionButtonStyle(tint: .green))
        }

        // Transport
        HStack(spacing: Spacing.sm) {
            Button(action: {}) {
                Image(systemName: "play.fill")
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(GlassTransportButtonStyle(isActive: true))

            Button(action: {}) {
                Image(systemName: "stop.fill")
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(GlassTransportButtonStyle())
        }
    }
    .padding(Spacing.xxl)
    .frame(width: 400, height: 350)
    .background(Color.black.opacity(0.8))
}
