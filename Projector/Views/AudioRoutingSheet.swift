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
                .padding(Spacing.lg)

            Divider()

            // Device info
            deviceInfoView
                .padding(Spacing.lg)

            Divider()

            // Preset selection
            presetSelectionView
                .padding(Spacing.lg)

            Divider()

            // Preview of lane configuration
            lanePreviewView
                .padding(Spacing.lg)

            Divider()

            // Footer with buttons
            footerView
                .padding(Spacing.lg)
        }
        .frame(width: 520, height: 580)
        .onAppear {
            // Default to stereo if device doesn't support stems
            if availableChannels < 6 {
                selectedPreset = .stereoMix
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Image(systemName: "speaker.wave.3")
                .font(.system(size: 24))
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Audio Routing")
                    .font(Typography.title)
                Text("Configure how audio lanes route to your interface")
                    .font(Typography.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button(action: { onCancel(); dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
    }

    // MARK: - Device Info

    private var deviceInfoView: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "hifispeaker.2")
                .font(.system(size: 28))
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(deviceDisplayName)
                    .font(Typography.heading)

                Text("\(availableChannels) output channels available")
                    .font(Typography.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Link to change device in settings
            Button("Change") {
                // This would open settings to device selection
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)
            .font(Typography.bodySmall)
        }
        .padding(Spacing.md)
        .background(AppColors.surfaceLight)
        .cornerRadius(8)
    }

    // MARK: - Preset Selection

    private var presetSelectionView: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Quick Setup")
                .font(Typography.label)
                .foregroundColor(.secondary)

            VStack(spacing: Spacing.sm) {
                ForEach(availablePresets) { preset in
                    presetRow(preset)
                }
            }
        }
    }

    private func presetRow(_ preset: LanePreset) -> some View {
        let isAvailable = preset.requiredChannels <= availableChannels || preset == .custom
        let isSelected = selectedPreset == preset

        return Button(action: { selectedPreset = preset }) {
            HStack(spacing: Spacing.md) {
                // Radio indicator
                Circle()
                    .strokeBorder(isSelected ? Color.accentColor : AppColors.borderMedium, lineWidth: 2)
                    .background(
                        Circle()
                            .fill(isSelected ? Color.accentColor : Color.clear)
                            .padding(3)
                    )
                    .frame(width: 18, height: 18)

                // Icon
                Image(systemName: preset.iconName)
                    .font(Typography.icon)
                    .foregroundColor(isAvailable ? .secondary : .secondary.opacity(0.5))
                    .frame(width: 24)

                // Label and description
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(preset.displayName)
                            .font(Typography.body)
                            .foregroundColor(isAvailable ? .primary : .secondary.opacity(0.5))

                        if preset != .custom && preset != .stereoMix {
                            Text("(\(preset.requiredChannels) ch)")
                                .font(Typography.captionSmall)
                                .foregroundColor(.secondary)
                        }
                    }

                    Text(preset.description)
                        .font(Typography.captionSmall)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                // Unavailable badge
                if !isAvailable {
                    Text("Needs \(preset.requiredChannels) ch")
                        .font(Typography.captionSmall)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, Spacing.xs)
                        .padding(.vertical, 2)
                        .background(AppColors.surfaceMedium)
                        .cornerRadius(4)
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? AppColors.surfaceLight : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
    }

    // MARK: - Lane Preview

    private var lanePreviewView: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack {
                Text("Lane Configuration")
                    .font(Typography.label)
                    .foregroundColor(.secondary)

                Spacer()

                if selectedPreset == .custom {
                    Button("Edit") {
                        showCustomEditor = true
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                    .font(Typography.bodySmall)
                }
            }

            if selectedPreset == .custom && customLanes.isEmpty {
                // Custom with no lanes
                VStack(spacing: Spacing.sm) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary.opacity(0.5))

                    Text("No lanes configured")
                        .font(Typography.body)
                        .foregroundColor(.secondary)

                    Button("Add Lanes") {
                        showCustomEditor = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity)
                .padding(Spacing.lg)
                .background(AppColors.surfaceLight)
                .cornerRadius(8)
            } else {
                // Lane list
                let configs = selectedPreset == .custom ? customLanes : selectedPreset.laneConfigs

                VStack(spacing: Spacing.xs) {
                    ForEach(Array(configs.enumerated()), id: \.offset) { index, config in
                        lanePreviewRow(config, index: index)
                    }
                }
                .padding(Spacing.sm)
                .background(AppColors.surfaceLight)
                .cornerRadius(8)
            }
        }
    }

    private func lanePreviewRow(_ config: LaneConfig, index: Int) -> some View {
        HStack(spacing: Spacing.md) {
            // Color indicator
            Circle()
                .fill(laneColor(for: config.colorIndex))
                .frame(width: 8, height: 8)

            // Lane name
            Text(config.name)
                .font(Typography.body)
                .frame(width: 100, alignment: .leading)

            // Channel range
            Text("Ch \(config.channelStart)-\(config.channelStart + config.channelCount - 1)")
                .font(Typography.mono)
                .foregroundColor(.secondary)

            Spacer()

            // Stereo/Mono badge
            Text(config.channelCount == 2 ? "Stereo" : "Mono")
                .font(Typography.captionSmall)
                .foregroundColor(.secondary)
                .padding(.horizontal, Spacing.xs)
                .padding(.vertical, 2)
                .background(AppColors.surfaceMedium)
                .cornerRadius(4)
        }
        .padding(.vertical, Spacing.xs)
    }

    private func laneColor(for index: Int) -> Color {
        let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .cyan, .yellow, .red]
        return colors[index % colors.count]
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            // Existing lanes warning
            if !timelineManager.timeline.audioLanes.isEmpty {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(Typography.iconSmall)
                        .foregroundColor(.orange)

                    Text("This will reconfigure existing lanes")
                        .font(Typography.captionSmall)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Button("Cancel") {
                onCancel()
                dismiss()
            }
            .keyboardShortcut(.escape)

            Button(action: applyConfiguration) {
                Text("Apply")
            }
            .keyboardShortcut(.return)
            .buttonStyle(.borderedProminent)
            .disabled(selectedPreset == .custom && customLanes.isEmpty)
        }
    }

    // MARK: - Actions

    private func applyConfiguration() {
        let configs = selectedPreset == .custom ? customLanes : selectedPreset.laneConfigs
        onApply(selectedPreset, configs)
        dismiss()
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
