//
//  ComponentCatalog.swift
//  Projector
//
//  Living style guide showing all design system components.
//  Use this as a reference when building new UI.
//

import SwiftUI

/// Living catalog of all Projector UI components and design system elements.
///
/// This catalog serves as:
/// - Visual reference for developers building new UI
/// - Design system documentation
/// - Consistency verification tool
/// - Onboarding resource for new contributors
///
/// Usage: Open in Xcode Previews to see all components rendered
struct ComponentCatalog: View {
    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.xxl) {
                // Header
                catalogHeader

                // Section 1: Spacing System
                spacingSection

                // Section 2: Button Styles
                buttonStylesSection

                // Section 3: Panel Styles
                panelStylesSection

                // Section 4: Timeline Components
                timelineComponentsSection

                // Section 5: Drag-Drop Zones
                dragDropSection

                // Section 6: Transport Controls
                transportControlsSection

                // Section 7: Glass Effects
                glassEffectsSection
            }
            .padding(Spacing.xxl)
        }
        .frame(width: 900, height: 1400)
        .background(WindowGlassBackground())
    }

    // MARK: - Header

    private var catalogHeader: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Projector Design System Catalog")
                .font(.system(size: 28, weight: .bold, design: .rounded))

            Text("Living style guide for all UI components")
                .font(.system(size: 14))
                .foregroundColor(.secondary)

            Divider()
        }
    }

    // MARK: - Section 1: Spacing System

    private var spacingSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionHeader("Spacing System")

            Text("All spacing uses the Spacing enum. Never hardcode values.")
                .font(.caption)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: Spacing.sm) {
                spacingExample("Spacing.xs", value: Spacing.xs)
                spacingExample("Spacing.sm", value: Spacing.sm)
                spacingExample("Spacing.md", value: Spacing.md)
                spacingExample("Spacing.lg", value: Spacing.lg)
                spacingExample("Spacing.xl", value: Spacing.xl)
                spacingExample("Spacing.xxl", value: Spacing.xxl)
            }
            .padding(Spacing.md)
            .glassPanel()
        }
    }

    private func spacingExample(_ name: String, value: CGFloat) -> some View {
        HStack(spacing: Spacing.md) {
            Text(name)
                .font(.system(.body, design: .monospaced))
                .frame(width: 140, alignment: .leading)

            Text("\(Int(value))pt")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 50, alignment: .leading)

            Rectangle()
                .fill(Color.accentColor)
                .frame(width: value, height: 8)
        }
    }

    // MARK: - Section 2: Button Styles

    private var buttonStylesSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionHeader("Button Styles")

            Text("All buttons use one of these 4 standard styles")
                .font(.caption)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: Spacing.lg) {
                // GlassActionButtonStyle
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("GlassActionButtonStyle")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)

                    HStack(spacing: Spacing.sm) {
                        Button("Import") {}
                            .buttonStyle(GlassActionButtonStyle(tint: .accentColor))

                        Button("Export") {}
                            .buttonStyle(GlassActionButtonStyle(tint: .green))

                        Button("Delete") {}
                            .buttonStyle(GlassActionButtonStyle(tint: .red))
                    }
                }

                // GlassTransportButtonStyle
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("GlassTransportButtonStyle")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)

                    HStack(spacing: Spacing.sm) {
                        Button(action: {}) {
                            Image(systemName: "play.fill")
                        }
                        .buttonStyle(GlassTransportButtonStyle(isActive: true))

                        Button(action: {}) {
                            Image(systemName: "pause.fill")
                        }
                        .buttonStyle(GlassTransportButtonStyle())

                        Button(action: {}) {
                            Image(systemName: "stop.fill")
                        }
                        .buttonStyle(GlassTransportButtonStyle())
                    }
                }

                // GlassIconButtonStyle
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("GlassIconButtonStyle")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)

                    HStack(spacing: Spacing.sm) {
                        Button(action: {}) {
                            Image(systemName: "gear")
                        }
                        .buttonStyle(GlassIconButtonStyle())

                        Button(action: {}) {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(GlassIconButtonStyle())

                        Button(action: {}) {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(GlassIconButtonStyle())
                    }
                }

                // GlassToggleButtonStyle
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("GlassToggleButtonStyle")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)

                    HStack(spacing: Spacing.sm) {
                        Button("Grid") {}
                            .buttonStyle(GlassToggleButtonStyle(isOn: true))

                        Button("List") {}
                            .buttonStyle(GlassToggleButtonStyle(isOn: false))
                    }
                }
            }
            .padding(Spacing.md)
            .glassPanel()
        }
    }

    // MARK: - Section 3: Panel Styles

    private var panelStylesSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionHeader("Panel Styles")

            Text("All panels use .glassPanel() modifier with depth system")
                .font(.caption)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: Spacing.lg) {
                // Panel with header
                VStack(spacing: 0) {
                    HStack {
                        Text("Panel Header")
                            .font(.headline)
                        Spacer()
                        Button(action: {}) {
                            Image(systemName: "chevron.down")
                        }
                        .buttonStyle(GlassIconButtonStyle())
                    }
                    .glassPanelHeader()

                    Text("Panel content goes here")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Spacing.md)
                }
                .glassPanel()
                .glassDepth(level: 1)

                // Panel with depth level 2
                VStack(spacing: Spacing.sm) {
                    Text("Elevated Panel (depth: 2)")
                        .font(.headline)
                    Text("Use higher depth for modals and overlays")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.md)
                .glassPanel()
                .glassDepth(level: 2)

                // Panel with depth level 3
                VStack(spacing: Spacing.sm) {
                    Text("Modal Panel (depth: 3)")
                        .font(.headline)
                    Text("Highest elevation for critical UI")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.md)
                .glassPanel()
                .glassDepth(level: 3)
            }
        }
    }

    // MARK: - Section 4: Timeline Components

    private var timelineComponentsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionHeader("Timeline Components")

            Text("Timeline elements use TimelineLayout constants")
                .font(.caption)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: Spacing.lg) {
                // Reel representation
                HStack(spacing: Spacing.xs) {
                    Rectangle()
                        .fill(Color.blue.opacity(0.3))
                        .frame(width: 200, height: TimelineLayout.trackHeight)
                        .overlay(
                            Text("Video Reel")
                                .font(.caption)
                        )
                        .cornerRadius(4)

                    Text("TimelineLayout.trackHeight (\(Int(TimelineLayout.trackHeight))pt)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Audio lane
                HStack(spacing: Spacing.xs) {
                    Rectangle()
                        .fill(Color.green.opacity(0.3))
                        .frame(width: 150, height: TimelineLayout.audioLaneHeight)
                        .overlay(
                            Text("Audio Clip")
                                .font(.caption)
                        )
                        .cornerRadius(4)

                    Text("TimelineLayout.audioLaneHeight (\(Int(TimelineLayout.audioLaneHeight))pt)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Timeline header
                Rectangle()
                    .fill(Color.black.opacity(0.2))
                    .frame(height: TimelineLayout.headerHeight)
                    .overlay(
                        Text("Timeline Header (TimelineLayout.headerHeight)")
                            .font(.caption)
                    )
            }
            .padding(Spacing.md)
            .glassPanel()
        }
    }

    // MARK: - Section 5: Drag-Drop Zones

    private var dragDropSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionHeader("Drag-Drop Zones")

            Text("Consistent drop zone styling for Finder and internal drags")
                .font(.caption)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: Spacing.lg) {
                // Active drop zone
                VStack(spacing: Spacing.sm) {
                    Text("Drop files here")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 100)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                )
                .background(
                    Color.accentColor.opacity(0.1)
                        .cornerRadius(8)
                )
                .overlay(
                    Text("Active Drop Zone")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                )

                // Invalid drop zone
                VStack(spacing: Spacing.sm) {
                    Text("Invalid file type")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 100)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.red, lineWidth: 2)
                )
                .background(
                    Color.red.opacity(0.1)
                        .cornerRadius(8)
                )
                .overlay(
                    Text("Invalid Drop Zone")
                        .font(.caption)
                        .foregroundColor(.red)
                )
            }
            .padding(Spacing.md)
            .glassPanel()
        }
    }

    // MARK: - Section 6: Transport Controls

    private var transportControlsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionHeader("Transport Controls")

            Text("Standard transport bar layout and controls")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: Spacing.md) {
                // Transport buttons
                HStack(spacing: Spacing.sm) {
                    Button(action: {}) {
                        Image(systemName: "backward.fill")
                    }
                    .buttonStyle(GlassTransportButtonStyle())

                    Button(action: {}) {
                        Image(systemName: "play.fill")
                    }
                    .buttonStyle(GlassTransportButtonStyle(isActive: true))

                    Button(action: {}) {
                        Image(systemName: "pause.fill")
                    }
                    .buttonStyle(GlassTransportButtonStyle())

                    Button(action: {}) {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(GlassTransportButtonStyle())

                    Button(action: {}) {
                        Image(systemName: "forward.fill")
                    }
                    .buttonStyle(GlassTransportButtonStyle())
                }

                Spacer()

                // Timecode display
                Text("01:23:45:12")
                    .font(.system(.title2, design: .monospaced))
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.sm)
                    .background(Color.black.opacity(0.3))
                    .cornerRadius(6)
            }
            .frame(height: TransportLayout.controlBoxHeight)
            .padding(Spacing.md)
            .glassPanel()
        }
    }

    // MARK: - Section 7: Glass Effects

    private var glassEffectsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionHeader("Glass Effects")

            Text("Depth hierarchy: Modals (3) > Panels (2) > Controls (1)")
                .font(.caption)
                .foregroundColor(.secondary)

            ZStack(alignment: .topLeading) {
                // Layer 1 (background)
                Text("Background Layer")
                    .padding(Spacing.md)
                    .frame(width: 250, height: 150)
                    .glassPanel()
                    .glassDepth(level: 1)

                // Layer 2 (middle)
                Text("Panel Layer")
                    .padding(Spacing.md)
                    .frame(width: 200, height: 120)
                    .glassPanel()
                    .glassDepth(level: 2)
                    .offset(x: 50, y: 40)

                // Layer 3 (foreground)
                Text("Modal Layer")
                    .padding(Spacing.md)
                    .frame(width: 150, height: 90)
                    .glassPanel()
                    .glassDepth(level: 3)
                    .offset(x: 100, y: 80)
            }
            .frame(height: 200)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title)
                .font(.system(size: 20, weight: .semibold))

            Divider()
        }
    }
}

// MARK: - Xcode Previews

#Preview("Component Catalog") {
    ComponentCatalog()
}

#Preview("Spacing Only") {
    ComponentCatalog()
        .frame(width: 600, height: 400)
}

#Preview("Dark Mode") {
    ComponentCatalog()
        .preferredColorScheme(.dark)
}
