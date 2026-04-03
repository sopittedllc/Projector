//
//  AudioRoutingSheet.swift
//  Projector
//
//  Sprint 2: Audio Routing - A composer-focused audio routing dialog.
//  Makes multi-output interface setup clean and intuitive.
//
//  Owned by: ui-specialist
//

import SwiftUI

// MARK: - Lane Preset

/// Pre-configured lane setups for common composer workflows.
enum LanePreset: String, CaseIterable, Identifiable {
    case stereoMix = "stereoMix"
    case stems = "stems"
    case dialogue = "dialogue"
    case filmMix = "filmMix"
    case custom = "custom"

    var id: String { rawValue }

    /// User-facing name
    var displayName: String {
        switch self {
        case .stereoMix: return "Stereo Mix"
        case .stems: return "Stems (5.1)"
        case .dialogue: return "Dialogue + M&E"
        case .filmMix: return "Film Mix"
        case .custom: return "Custom"
        }
    }

    /// Description of what this preset includes
    var description: String {
        switch self {
        case .stereoMix:
            return "Simple stereo output on channels 1-2"
        case .stems:
            return "Dialogue, Music, Effects on separate stereo pairs"
        case .dialogue:
            return "Dialogue (1-2) and Music & Effects (3-4)"
        case .filmMix:
            return "Full mix (1-2), Dialogue (3-4), Music (5-6), FX (7-8)"
        case .custom:
            return "Configure lanes manually"
        }
    }

    /// SF Symbol for this preset
    var iconName: String {
        switch self {
        case .stereoMix: return "speaker.wave.2"
        case .stems: return "square.stack.3d.up"
        case .dialogue: return "person.wave.2"
        case .filmMix: return "film"
        case .custom: return "slider.horizontal.3"
        }
    }

    /// Lane configurations for this preset
    var laneConfigs: [LaneConfig] {
        switch self {
        case .stereoMix:
            return [
                LaneConfig(name: "Master", channelStart: 1, channelCount: 2, colorIndex: 0)
            ]
        case .stems:
            return [
                LaneConfig(name: "Dialogue", channelStart: 1, channelCount: 2, colorIndex: 0),
                LaneConfig(name: "Music", channelStart: 3, channelCount: 2, colorIndex: 1),
                LaneConfig(name: "Effects", channelStart: 5, channelCount: 2, colorIndex: 2)
            ]
        case .dialogue:
            return [
                LaneConfig(name: "Dialogue", channelStart: 1, channelCount: 2, colorIndex: 0),
                LaneConfig(name: "M&E", channelStart: 3, channelCount: 2, colorIndex: 1)
            ]
        case .filmMix:
            return [
                LaneConfig(name: "Full Mix", channelStart: 1, channelCount: 2, colorIndex: 0),
                LaneConfig(name: "Dialogue", channelStart: 3, channelCount: 2, colorIndex: 1),
                LaneConfig(name: "Music", channelStart: 5, channelCount: 2, colorIndex: 2),
                LaneConfig(name: "FX", channelStart: 7, channelCount: 2, colorIndex: 3)
            ]
        case .custom:
            return []
        }
    }

    /// Minimum output channels required for this preset
    var requiredChannels: Int {
        switch self {
        case .stereoMix: return 2
        case .stems: return 6
        case .dialogue: return 4
        case .filmMix: return 8
        case .custom: return 2
        }
    }
}

/// Configuration for a single lane in a preset
struct LaneConfig {
    let name: String
    let channelStart: Int
    let channelCount: Int
    let colorIndex: Int
}

// MARK: - AudioRoutingSheet

/// A composer-focused dialog for configuring audio output routing.
///
/// This sheet appears when:
/// - User clicks "Configure Audio" in the timeline header
/// - User accesses audio routing from settings
/// - First time setup for multi-output interfaces
///
/// Features:
/// - Quick presets for common workflows (Stems, Dialogue, Film Mix)
/// - Visual channel assignment
/// - Interface detection and display
///
/// ## Usage
/// ```swift
/// .sheet(isPresented: $showAudioRouting) {
///     AudioRoutingSheet(
///         audioManager: audioManager,
///         timelineManager: timelineManager,
///         onApply: { preset in
///             applyLanePreset(preset)
///         },
///         onCancel: { }
///     )
/// }
/// ```
struct AudioRoutingSheet: View {
    // MARK: - Environment

    @Environment(\.dismiss) private var dismiss

    // MARK: - Properties

    @ObservedObject var audioManager: AudioOutputManager
    @ObservedObject var timelineManager: TimelineManager

    /// Callback when user applies a configuration
    let onApply: (LanePreset, [LaneConfig]) -> Void

    /// Callback when user cancels
    let onCancel: () -> Void

    // MARK: - State

    @State private var selectedPreset: LanePreset = .stereoMix
    @State private var customLanes: [LaneConfig] = []
    @State private var showCustomEditor = false

    // MARK: - Computed Properties

    private var availableChannels: Int {
        audioManager.selectedDeviceChannelCount
    }

    private var selectedDevice: AudioDevice? {
        audioManager.selectedDevice
    }

    private var deviceDisplayName: String {
        selectedDevice?.name ?? "System Default"
    }

    /// Presets that can work with the current device's channel count
    private var availablePresets: [LanePreset] {
        LanePreset.allCases.filter { $0.requiredChannels <= availableChannels || $0 == .custom }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            // Scrollable content
            ScrollView {
                VStack(spacing: Spacing.md) {
                    // Device info card
                    deviceInfoView

                    // Preset selection
                    presetSelectionView

                    // Preview of lane configuration
                    lanePreviewView
                }
                .padding(Spacing.lg)
            }

            // Footer with buttons
            footerView
        }
        .frame(width: 500, height: 560)
        .glassPanel()
        .onAppear {
            // Default to stereo if device doesn't support stems
            if availableChannels < 6 {
                selectedPreset = .stereoMix
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "slider.horizontal.3")
                .font(Typography.icon)
                .foregroundColor(AppColors.accentBlue)

            Text("Audio Routing")
                .font(Typography.heading)
                .foregroundColor(.primary)

            Spacer()

            Button(action: { onCancel(); dismiss() }) {
                Image(systemName: "xmark")
                    .font(Typography.iconSmall)
            }
            .buttonStyle(GlassIconButtonStyle())
            .keyboardShortcut(.escape)
            .accessibilityLabel("Close")
        }
        .frame(height: PanelLayout.headerHeight)
        .padding(.horizontal, Spacing.lg)
    }

    // MARK: - Device Info

    private var deviceInfoView: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // Section label
            Text("Output Device")
                .font(Typography.label)
                .foregroundColor(.secondary)

            // Device card
            HStack(spacing: Spacing.md) {
                Image(systemName: "hifispeaker.2")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundColor(AppColors.accentBlue)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(deviceDisplayName)
                        .font(Typography.body)
                        .foregroundColor(.primary)

                    Text("\(availableChannels) channels")
                        .font(Typography.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding(Spacing.md)
            .glassControl()
        }
    }

    // MARK: - Preset Selection

    private var presetSelectionView: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Quick Setup")
                .font(Typography.label)
                .foregroundColor(.secondary)

            VStack(spacing: Spacing.xs) {
                ForEach(availablePresets) { preset in
                    PresetRowView(
                        preset: preset,
                        isSelected: selectedPreset == preset,
                        isAvailable: preset.requiredChannels <= availableChannels || preset == .custom
                    ) {
                        selectedPreset = preset
                    }
                }
            }
            .padding(Spacing.sm)
            .glassControl()
        }
    }

    // MARK: - Lane Preview

    private var lanePreviewView: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                Text("Lane Configuration")
                    .font(Typography.label)
                    .foregroundColor(.secondary)

                Spacer()

                if selectedPreset == .custom {
                    Button(action: { showCustomEditor = true }) {
                        HStack(spacing: Spacing.xs) {
                            Image(systemName: "pencil")
                                .font(Typography.iconSmall)
                            Text("Edit")
                        }
                    }
                    .buttonStyle(GlassTextButtonStyle())
                }
            }

            if selectedPreset == .custom && customLanes.isEmpty {
                // Custom with no lanes
                VStack(spacing: Spacing.md) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 32, weight: .regular))
                        .foregroundColor(.secondary.opacity(0.5))

                    Text("No lanes configured")
                        .font(Typography.body)
                        .foregroundColor(.secondary)

                    Button(action: { showCustomEditor = true }) {
                        HStack(spacing: Spacing.xs) {
                            Image(systemName: "plus")
                                .font(Typography.iconSmall)
                            Text("Add Lanes")
                        }
                    }
                    .buttonStyle(GlassActionButtonStyle(tint: AppColors.accentBlue))
                }
                .frame(maxWidth: .infinity)
                .padding(Spacing.xl)
                .glassControl()
            } else {
                // Lane list
                let configs = selectedPreset == .custom ? customLanes : selectedPreset.laneConfigs

                VStack(spacing: 0) {
                    ForEach(Array(configs.enumerated()), id: \.offset) { index, config in
                        lanePreviewRow(config, index: index)

                        if index < configs.count - 1 {
                            Divider()
                                .padding(.leading, Spacing.md + 12)
                        }
                    }
                }
                .padding(.vertical, Spacing.xs)
                .glassControl()
            }
        }
    }

    private func lanePreviewRow(_ config: LaneConfig, index: Int) -> some View {
        HStack(spacing: Spacing.sm) {
            // Color indicator
            Circle()
                .fill(laneColor(for: config.colorIndex))
                .frame(width: 8, height: 8)

            // Lane name
            Text(config.name)
                .font(Typography.body)
                .foregroundColor(.primary)

            Spacer()

            // Channel range
            Text("Ch \(config.channelStart)–\(config.channelStart + config.channelCount - 1)")
                .font(Typography.mono)
                .foregroundColor(.secondary)

            // Stereo/Mono badge
            Text(config.channelCount == 2 ? "Stereo" : "Mono")
                .font(Typography.captionSmall)
                .foregroundColor(.secondary)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, 3)
                .background(AppColors.surfaceMedium.opacity(0.5))
                .cornerRadius(4)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
    }

    private func laneColor(for index: Int) -> Color {
        let colors: [Color] = [
            AppColors.accentBlue,
            AppColors.accentGreen,
            AppColors.accentYellow,
            AppColors.accentPurple,
            AppColors.accentPink,
            .cyan,
            .orange,
            .red
        ]
        return colors[index % colors.count]
    }

    // MARK: - Footer

    private var footerView: some View {
        VStack(spacing: Spacing.sm) {
            // Warning if reconfiguring existing lanes
            if !timelineManager.timeline.audioLanes.isEmpty {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(Typography.iconSmall)
                        .foregroundColor(AppColors.accentYellow)

                    Text("This will reconfigure existing lanes")
                        .font(Typography.caption)
                        .foregroundColor(.secondary)

                    Spacer()
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .background(AppColors.accentYellow.opacity(0.1))
                .cornerRadius(PanelLayout.cornerRadius)
            }

            // Action buttons
            HStack(spacing: Spacing.md) {
                Spacer()

                Button(action: { onCancel(); dismiss() }) {
                    Text("Cancel")
                }
                .buttonStyle(GlassTextButtonStyle())

                Button(action: applyConfiguration) {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "checkmark")
                            .font(Typography.iconSmall)
                        Text("Apply")
                    }
                }
                .buttonStyle(GlassActionButtonStyle(tint: AppColors.accentBlue))
                .keyboardShortcut(.return)
                .disabled(selectedPreset == .custom && customLanes.isEmpty)
            }
        }
        .padding(Spacing.lg)
        .background(AppColors.surfaceLight.opacity(0.3))
    }

    // MARK: - Actions

    private func applyConfiguration() {
        let configs = selectedPreset == .custom ? customLanes : selectedPreset.laneConfigs
        onApply(selectedPreset, configs)
        dismiss()
    }
}

// MARK: - Preset Row View

/// A single preset option row with hover and selection states
private struct PresetRowView: View {
    let preset: LanePreset
    let isSelected: Bool
    let isAvailable: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: Spacing.md) {
                // Radio indicator
                ZStack {
                    Circle()
                        .strokeBorder(
                            isSelected ? AppColors.accentBlue : AppColors.borderMedium,
                            lineWidth: 2
                        )
                        .frame(width: 16, height: 16)

                    if isSelected {
                        Circle()
                            .fill(AppColors.accentBlue)
                            .frame(width: 8, height: 8)
                    }
                }

                // Icon
                Image(systemName: preset.iconName)
                    .font(Typography.icon)
                    .foregroundColor(isAvailable ? (isSelected ? AppColors.accentBlue : .secondary) : .secondary.opacity(0.4))
                    .frame(width: 20)

                // Label and description
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Spacing.xs) {
                        Text(preset.displayName)
                            .font(Typography.body)
                            .foregroundColor(isAvailable ? .primary : .secondary.opacity(0.5))

                        if preset != .custom && preset != .stereoMix {
                            Text("\(preset.requiredChannels) ch")
                                .font(Typography.captionSmall)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, Spacing.xs)
                                .padding(.vertical, 1)
                                .background(AppColors.surfaceMedium.opacity(0.5))
                                .cornerRadius(3)
                        }
                    }

                    Text(preset.description)
                        .font(Typography.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                // Selection indicator
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(Typography.iconSmall)
                        .foregroundColor(AppColors.accentBlue)
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: PanelLayout.cornerRadius)
                    .fill(isSelected ? AppColors.accentBlue.opacity(0.1) : (isHovered ? AppColors.surfaceLight : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .onHover { hovering in
            isHovered = hovering
        }
        .animation(AppAnimations.quick, value: isHovered)
        .animation(AppAnimations.quick, value: isSelected)
    }
}

// MARK: - Preview

#if DEBUG
struct AudioRoutingSheet_Previews: PreviewProvider {
    static var previews: some View {
        AudioRoutingSheet(
            audioManager: AudioOutputManager(),
            timelineManager: TimelineManager(),
            onApply: { preset, configs in
                print("Applied preset: \(preset.displayName) with \(configs.count) lanes")
            },
            onCancel: {
                print("Cancelled")
            }
        )
    }
}
#endif
