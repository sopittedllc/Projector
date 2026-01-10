//
//  LiquidGlassStyles.swift
//  Projector
//
//  Liquid Glass design system for macOS Tahoe (26+) with fallbacks.
//

import SwiftUI
import AppKit

// MARK: - Glass Panel Background

/// A view modifier that applies Liquid Glass panel styling.
/// Uses native `.glassEffect()` on macOS 26+, falls back to NSVisualEffectView on older versions.
struct GlassPanelModifier: ViewModifier {
    var cornerRadius: CGFloat = 8
    var borderOpacity: CGFloat = 0.2

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
                        .stroke(Color.white.opacity(borderOpacity), lineWidth: 1)
                )
        } else {
            content
                .background(
                    ZStack {
                        LegacyVisualEffectBackground(cornerRadius: cornerRadius)
                        Color(red: 30.0 / 255.0, green: 30.0 / 255.0, blue: 30.0 / 255.0)
                            .opacity(0.85)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(Color.white.opacity(borderOpacity), lineWidth: 1)
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
                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                )
        } else {
            content
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
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
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
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
                .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
        } else {
            configuration.label
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(tint?.opacity(0.2) ?? Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
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
                .padding(8)
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
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
        } else {
            configuration.label
                .padding(8)
                .background(
                    Circle()
                        .fill(isActive ? Color.accentColor.opacity(0.2) : Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
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
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background {
                    Capsule()
                        .fill(.clear)
                        .glassEffect(.regular.tint(tint), in: Capsule())
                }
                .opacity(configuration.isPressed ? 0.8 : 1.0)
                .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
                .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
        } else {
            configuration.label
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(tint.opacity(0.15))
                )
                .overlay(
                    Capsule()
                        .stroke(tint.opacity(0.3), lineWidth: 1)
                )
                .opacity(configuration.isPressed ? 0.8 : 1.0)
        }
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
                Color(red: 30.0 / 255.0, green: 30.0 / 255.0, blue: 30.0 / 255.0)
                    .opacity(0.95)
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
    VStack(spacing: 20) {
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
        HStack(spacing: 12) {
            HStack {
                Text("TC:")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Text("01:00:00:00")
                    .font(.system(size: 12, design: .monospaced))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassControl()

            HStack {
                Text("FPS:")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Text("24")
                    .font(.system(size: 12, design: .monospaced))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassControl()
        }

        // Buttons
        HStack(spacing: 12) {
            Button("Import") {}
                .buttonStyle(GlassActionButtonStyle(tint: .accentColor))

            Button("Optimize") {}
                .buttonStyle(GlassActionButtonStyle(tint: .green))
        }

        // Transport
        HStack(spacing: 8) {
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
    .padding(40)
    .frame(width: 400, height: 350)
    .background(Color.black.opacity(0.8))
}
