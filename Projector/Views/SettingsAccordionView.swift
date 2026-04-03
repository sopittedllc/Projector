//
//  SettingsAccordionView.swift
//  Projector
//
//  Collapsible settings panel with two-column layout.
//  Top: Timecode Overlay (left) | Playback Behavior (right)
//  Bottom: Audio section with channel-first output configuration
//

import SwiftUI

// MARK: - Channel State

/// Represents the state of a single channel in the audio output grid
enum ChannelState: Equatable {
    case inactive
    case activeMono(outputId: UUID)
    case stereoPrimary(outputId: UUID)
    case stereoSecondary(outputId: UUID)
}

// MARK: - Channel Item (for grouped rendering)

/// Represents an item in the channel grid - can be a single channel or a stereo group
enum ChannelItem: Identifiable {
    case inactive(channel: Int)
    case mono(channel: Int, outputId: UUID)
    case stereoGroup(channels: (Int, Int), outputId: UUID)

    var id: String {
        switch self {
        case .inactive(let channel):
            return "inactive-\(channel)"
        case .mono(let channel, _):
            return "mono-\(channel)"
        case .stereoGroup(let channels, _):
            return "stereo-\(channels.0)-\(channels.1)"
        }
    }
}

/// Collapsible settings section for the right panel
struct SettingsAccordionView: View {
    @ObservedObject var audioManager: AudioOutputManager
    @Binding var isExpanded: Bool
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            accordionHeader

            if isExpanded {
                Divider()
                settingsContent
            }
        }
        .glassPanel()
    }

    // MARK: - Accordion Header

    private var accordionHeader: some View {
        HStack(spacing: Spacing.sm) {
            Button(action: {
                withAnimation(AppAnimations.standard) {
                    isExpanded.toggle()
                }
            }) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(Typography.iconSmall)
                        .foregroundColor(.secondary)
                        .frame(width: Spacing.md)

                    Image(systemName: "gearshape")
                        .font(Typography.icon)
                        .foregroundColor(.secondary)

                    Text("Settings")
                        .font(Typography.subheading)
                        .foregroundColor(.primary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .frame(height: PanelLayout.headerHeight)
        .padding(.horizontal, Spacing.md)
    }

    // MARK: - Settings Content

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            // TOP ROW: Two columns with aligned controls
            HStack(alignment: .top, spacing: Spacing.lg) {
                timecodeOverlaySection
                    .frame(maxWidth: .infinity, alignment: .leading)

                Divider()
                    .frame(height: 100)

                playbackBehaviorSection
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            // BOTTOM: Audio section (full width)
            audioSection
        }
        .padding(Spacing.md)
    }

    // MARK: - Timecode Overlay Section

    private var timecodeOverlaySection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("Timecode Overlay")

            settingsRow(label: "Show Overlay") {
                Toggle("", isOn: $settings.showTimecodeOverlay)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            if settings.showTimecodeOverlay {
                settingsRow(label: "Position") {
                    Picker("", selection: $settings.timecodeOverlayPosition) {
                        Text("Top Left").tag(TimecodeOverlayPosition.topLeft)
                        Text("Top Right").tag(TimecodeOverlayPosition.topRight)
                        Text("Bottom Left").tag(TimecodeOverlayPosition.bottomLeft)
                        Text("Bottom Right").tag(TimecodeOverlayPosition.bottomRight)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(minWidth: 120)
                }
            }
        }
    }

    // MARK: - Playback Behavior Section

    private var playbackBehaviorSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("Playback Behavior")

            settingsRow(label: "Auto-play on MTC") {
                Toggle("", isOn: $settings.autoPlayOnMTC)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            settingsRow(label: "Auto-pause on MTC Stop") {
                Toggle("", isOn: $settings.autoPauseOnMTCStop)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            settingsRow(label: "Respond to MMC") {
                Toggle("", isOn: $settings.respondToMMC)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Audio Section

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionHeader("Audio Output")

            // Device picker row
            settingsRow(label: "Device") {
                Picker("", selection: Binding<String>(
                    get: { audioManager.selectedDeviceUID ?? "" },
                    set: { newValue in
                        audioManager.selectedDeviceUID = newValue.isEmpty ? nil : newValue
                    }
                )) {
                    Text("System Default").tag("")
                    ForEach(audioManager.availableDevices, id: \.uid) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(minWidth: 180)

                Spacer()

                Text("\(audioManager.selectedDeviceChannelCount) channels")
                    .font(Typography.caption)
                    .foregroundColor(AppColors.textTertiary)
            }

            // Channel grid
            ChannelGridView(
                totalChannels: audioManager.selectedDeviceChannelCount,
                outputs: settings.mappedOutputs(for: audioManager.selectedDeviceUID),
                onOutputsChanged: { newOutputs in
                    settings.setMappedOutputs(newOutputs, for: audioManager.selectedDeviceUID)
                }
            )
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(Typography.labelSmall)
            .foregroundColor(AppColors.textTertiary)
            .padding(.bottom, Spacing.xs)
    }

    @ViewBuilder
    private func settingsRow<Content: View>(
        label: String,
        @ViewBuilder control: () -> Content
    ) -> some View {
        HStack(spacing: Spacing.sm) {
            Text(label)
                .font(Typography.body)
                .foregroundColor(.primary)
                .frame(width: SettingsLayout.labelWidth, alignment: .leading)

            control()
        }
    }
}

// MARK: - Channel Grid View

/// Channel-first grid showing all device channels with activation/linking support
private struct ChannelGridView: View {
    let totalChannels: Int
    let outputs: [MappedAudioOutput]
    let onOutputsChanged: ([MappedAudioOutput]) -> Void

    @State private var selectedChannel: Int? = nil  // Single selected channel for linking
    @State private var hoveredChannel: Int? = nil   // Currently hovered channel
    @State private var editingOutputId: UUID?
    @State private var editedName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // Channels header
            Text("Channels")
                .font(Typography.label)
                .foregroundColor(AppColors.textTertiary)

            // Channel cells grid with Link button on same row
            if totalChannels > 0 {
                channelGrid
            } else {
                Text("No audio device selected")
                    .font(Typography.body)
                    .foregroundColor(.secondary)
                    .padding(Spacing.md)
            }

            // Configured outputs list
            if !outputs.isEmpty {
                outputsList
            }
        }
    }

    // MARK: - Channel Grid

    /// Build grouped channel items for rendering
    private var channelItems: [ChannelItem] {
        var items: [ChannelItem] = []
        var channel = 1

        while channel <= totalChannels {
            let state = channelState(for: channel)

            switch state {
            case .stereoPrimary(let outputId):
                // This is a stereo pair - group both channels
                items.append(.stereoGroup(
                    channels: (channel, channel + 1),
                    outputId: outputId
                ))
                channel += 2 // Skip the secondary channel

            case .stereoSecondary:
                // Should not hit this if we're processing in order
                channel += 1

            case .activeMono(let outputId):
                items.append(.mono(channel: channel, outputId: outputId))
                channel += 1

            case .inactive:
                items.append(.inactive(channel: channel))
                channel += 1
            }
        }

        return items
    }

    /// Returns the pair of channels to show link preview for, sorted (lower, higher)
    private var linkPreviewPair: (Int, Int)? {
        guard let selected = selectedChannel else { return nil }
        guard let hovered = hoveredChannel else { return nil }
        guard abs(hovered - selected) == 1 else { return nil }
        guard channelState(for: hovered) == .inactive else { return nil }
        let sorted = [selected, hovered].sorted()
        return (sorted[0], sorted[1])
    }

    private var channelGrid: some View {
        HStack(spacing: SettingsLayout.channelCellSpacing) {
            ForEach(channelItems) { item in
                switch item {
                case .inactive(let channel):
                    // Check if this channel is part of a link preview
                    if let pair = linkPreviewPair {
                        if channel == pair.0 {
                            // First channel of pair - show LinkPreviewView
                            LinkPreviewView(
                                channels: pair,
                                onLink: { linkChannels(pair.0, pair.1) }
                            )
                        } else if channel == pair.1 {
                            // Second channel of pair - skip (already shown in LinkPreviewView)
                            EmptyView()
                        } else {
                            // Not part of pair - show normal cell
                            normalChannelCell(channel: channel)
                        }
                    } else {
                        // No link preview - show normal cell
                        normalChannelCell(channel: channel)
                    }

                case .mono(let channel, _):
                    ChannelCellView(
                        channel: channel,
                        state: channelState(for: channel),
                        isSelected: false,
                        onTap: { handleChannelTap(channel) },
                        onActivate: { },
                        onHover: { _ in }
                    )

                case .stereoGroup(let channels, let outputId):
                    StereoGroupView(
                        channels: channels,
                        onUnlink: { unlinkOutput(outputId) }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func normalChannelCell(channel: Int) -> some View {
        ChannelCellView(
            channel: channel,
            state: .inactive,
            isSelected: selectedChannel == channel,
            onTap: { handleChannelTap(channel) },
            onActivate: { activateChannel(channel) },
            onHover: { isHovered in
                hoveredChannel = isHovered ? channel : nil
            }
        )
    }

    // MARK: - Outputs List

    private var outputsList: some View {
        VStack(spacing: 4) {
            ForEach(outputs) { output in
                OutputRowView(
                    output: output,
                    isEditing: editingOutputId == output.id,
                    editedName: editingOutputId == output.id ? $editedName : .constant(""),
                    onStartEdit: {
                        editedName = output.name
                        editingOutputId = output.id
                    },
                    onCommitEdit: {
                        commitRename(output.id)
                    },
                    onCancelEdit: {
                        editingOutputId = nil
                    },
                    onUnlink: output.channelCount > 1 ? { unlinkOutput(output.id) } : nil,
                    onDelete: { deleteOutput(output.id) }
                )
            }
        }
    }

    // MARK: - Channel State

    private func channelState(for channel: Int) -> ChannelState {
        for output in outputs {
            let endChannel = output.channelStart + output.channelCount - 1
            if channel >= output.channelStart && channel <= endChannel {
                if output.channelCount == 1 {
                    return .activeMono(outputId: output.id)
                } else if channel == output.channelStart {
                    return .stereoPrimary(outputId: output.id)
                } else {
                    return .stereoSecondary(outputId: output.id)
                }
            }
        }
        return .inactive
    }

    // MARK: - Selection & Linking

    private func handleChannelTap(_ channel: Int) {
        let state = channelState(for: channel)

        switch state {
        case .inactive:
            // Toggle selection - single selection model
            if selectedChannel == channel {
                selectedChannel = nil
            } else {
                selectedChannel = channel
            }
        case .activeMono, .stereoPrimary, .stereoSecondary:
            // Clear selection when tapping active channel
            selectedChannel = nil
        }
    }

    private func activateChannel(_ channel: Int) {
        var newOutputs = outputs
        newOutputs.append(MappedAudioOutput(
            name: "Ch \(channel)",
            channelStart: channel,
            channelCount: 1
        ))
        newOutputs.sort { $0.channelStart < $1.channelStart }
        onOutputsChanged(newOutputs)
        selectedChannel = nil
    }

    private func linkChannels(_ channel1: Int, _ channel2: Int) {
        let sorted = [channel1, channel2].sorted()

        var newOutputs = outputs
        newOutputs.append(MappedAudioOutput(
            name: "Ch \(sorted[0])-\(sorted[1])",
            channelStart: sorted[0],
            channelCount: 2
        ))
        newOutputs.sort { $0.channelStart < $1.channelStart }
        onOutputsChanged(newOutputs)
        selectedChannel = nil
    }

    // MARK: - Output Management

    private func commitRename(_ id: UUID) {
        let trimmed = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            editingOutputId = nil
            return
        }

        var newOutputs = outputs
        if let index = newOutputs.firstIndex(where: { $0.id == id }) {
            newOutputs[index].name = trimmed
            onOutputsChanged(newOutputs)
        }
        editingOutputId = nil
    }

    private func unlinkOutput(_ id: UUID) {
        var newOutputs = outputs
        newOutputs.removeAll { $0.id == id }
        onOutputsChanged(newOutputs)
    }

    private func deleteOutput(_ id: UUID) {
        var newOutputs = outputs
        newOutputs.removeAll { $0.id == id }
        onOutputsChanged(newOutputs)
    }
}


// MARK: - Stereo Group View

/// A grouped view showing two linked stereo channels as a single unit
private struct StereoGroupView: View {
    let channels: (Int, Int)
    let onUnlink: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onUnlink) {
            ZStack {
                // Channel numbers with link icon (dimmed on hover)
                HStack(spacing: 2) {
                    Text("\(channels.0)")
                        .font(Typography.captionSmall)
                        .foregroundColor(isHovered ? .primary.opacity(0.2) : .primary)
                        .frame(width: 20, height: SettingsLayout.channelCellSize - 8)

                    Image(systemName: "link")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(isHovered ? AppColors.accentGreen.opacity(0.2) : AppColors.accentGreen.opacity(0.8))

                    Text("\(channels.1)")
                        .font(Typography.captionSmall)
                        .foregroundColor(isHovered ? .primary.opacity(0.2) : .primary)
                        .frame(width: 20, height: SettingsLayout.channelCellSize - 8)
                }

                // "Unlink?" overlay on hover with icon
                if isHovered {
                    HStack(spacing: 3) {
                        Image(systemName: "link.badge.minus")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Unlink?")
                            .font(Typography.labelSmall)
                    }
                    .foregroundColor(AppColors.accentPink)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? AppColors.accentPink.opacity(0.35) : AppColors.accentGreen.opacity(0.2))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isHovered ? AppColors.accentPink.opacity(0.6) : AppColors.accentGreen.opacity(0.4), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(AppAnimations.quick) {
                isHovered = hovering
            }
        }
    }
}


// MARK: - Link Preview View

/// Preview overlay showing two channels about to be linked
private struct LinkPreviewView: View {
    let channels: (Int, Int)
    let onLink: () -> Void

    var body: some View {
        Button(action: onLink) {
            ZStack {
                // Channel numbers (dimmed)
                HStack(spacing: 2) {
                    Text("\(channels.0)")
                        .font(Typography.captionSmall)
                        .foregroundColor(.primary.opacity(0.2))
                        .frame(width: 20, height: SettingsLayout.channelCellSize - 8)

                    Image(systemName: "link")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(AppColors.accentGreen.opacity(0.2))

                    Text("\(channels.1)")
                        .font(Typography.captionSmall)
                        .foregroundColor(.primary.opacity(0.2))
                        .frame(width: 20, height: SettingsLayout.channelCellSize - 8)
                }

                // "Link?" overlay with icon
                HStack(spacing: 3) {
                    Image(systemName: "link.badge.plus")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Link?")
                        .font(Typography.labelSmall)
                }
                .foregroundColor(AppColors.accentGreen)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(AppColors.accentGreen.opacity(0.35))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(AppColors.accentGreen.opacity(0.6), lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
}


// MARK: - Channel Cell View

/// Individual channel cell in the grid (for inactive and mono channels)
private struct ChannelCellView: View {
    let channel: Int
    let state: ChannelState
    let isSelected: Bool
    let onTap: () -> Void
    let onActivate: () -> Void
    let onHover: (Bool) -> Void

    @State private var isHovered = false

    private var isInactive: Bool {
        if case .inactive = state { return true }
        return false
    }

    var body: some View {
        Button(action: onTap) {
            ZStack {
                // Background
                RoundedRectangle(cornerRadius: 6)
                    .fill(backgroundColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(borderColor, lineWidth: isSelected ? 2 : 1)
                    )

                // Channel number
                Text("\(channel)")
                    .font(Typography.mono)
                    .foregroundColor(textColor)

                // Hover affordance for inactive - plus icon
                if isInactive && isHovered && !isSelected {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(AppColors.accentBlue.opacity(0.8))
                        .offset(x: 8, y: -8)
                }
            }
            .frame(width: SettingsLayout.channelCellSize, height: SettingsLayout.channelCellSize)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(AppAnimations.quick) {
                isHovered = hovering
            }
            onHover(hovering)
        }
        .contextMenu {
            if isInactive {
                Button("Activate as Mono") { onActivate() }
            }
        }
        .help(helpText)
    }

    private var backgroundColor: Color {
        if isSelected {
            return AppColors.accentYellow.opacity(0.3)
        }
        switch state {
        case .inactive:
            return isHovered ? AppColors.surfaceMedium : AppColors.surfaceLight.opacity(0.5)
        case .activeMono:
            return AppColors.accentBlue.opacity(isHovered ? 0.35 : 0.25)
        case .stereoPrimary, .stereoSecondary:
            // Stereo channels are handled by StereoGroupView
            return AppColors.accentGreen.opacity(0.25)
        }
    }

    private var borderColor: Color {
        if isSelected {
            return AppColors.accentYellow
        }
        switch state {
        case .inactive:
            return isHovered ? AppColors.borderMedium : AppColors.borderLight
        case .activeMono:
            return AppColors.accentBlue.opacity(0.5)
        case .stereoPrimary, .stereoSecondary:
            return AppColors.accentGreen.opacity(0.5)
        }
    }

    private var textColor: Color {
        if isSelected {
            return .primary
        }
        switch state {
        case .inactive:
            return isHovered ? .primary : .secondary
        case .activeMono, .stereoPrimary, .stereoSecondary:
            return .primary
        }
    }

    private var helpText: String {
        switch state {
        case .inactive:
            return isSelected ? "Hover over adjacent channel to link"
                : "Click to select, right-click to activate as mono"
        case .activeMono:
            return "Active mono output"
        case .stereoPrimary, .stereoSecondary:
            return "Linked stereo pair"
        }
    }
}

// MARK: - Output Row View

/// Row showing a configured output with rename/delete controls
private struct OutputRowView: View {
    let output: MappedAudioOutput
    let isEditing: Bool
    @Binding var editedName: String
    let onStartEdit: () -> Void
    let onCommitEdit: () -> Void
    let onCancelEdit: () -> Void
    let onUnlink: (() -> Void)?
    let onDelete: () -> Void

    @State private var isHovered = false
    @FocusState private var isNameFocused: Bool

    var body: some View {
        HStack(spacing: Spacing.sm) {
            // Channel indicator - green for stereo, blue for mono
            HStack(spacing: 2) {
                let accentColor = output.channelCount == 2 ? AppColors.accentGreen : AppColors.accentBlue
                ForEach(0..<output.channelCount, id: \.self) { offset in
                    Text("\(output.channelStart + offset)")
                        .font(Typography.captionSmall)
                        .foregroundColor(.primary)
                        .frame(width: 20, height: 20)
                        .background(accentColor.opacity(0.2))
                        .cornerRadius(4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(accentColor.opacity(0.4), lineWidth: 1)
                        )
                }
            }
            .frame(width: 50, alignment: .leading)

            // Name (editable)
            if isEditing {
                TextField("Name", text: $editedName)
                    .textFieldStyle(.plain)
                    .font(Typography.body)
                    .padding(.horizontal, Spacing.xs)
                    .padding(.vertical, 2)
                    .background(AppColors.surfaceMedium)
                    .cornerRadius(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(AppColors.accentBlue, lineWidth: 1)
                    )
                    .focused($isNameFocused)
                    .onSubmit { onCommitEdit() }
                    .onExitCommand { onCancelEdit() }
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            isNameFocused = true
                        }
                    }
            } else {
                HStack(spacing: 4) {
                    Text(output.name)
                        .font(Typography.body)
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    if isHovered {
                        Image(systemName: "pencil")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { onStartEdit() }
            }

            Spacer()

            // Format badge - green for stereo, subtle for mono
            Text(output.channelCount == 2 ? "Stereo" : "Mono")
                .font(Typography.captionSmall)
                .foregroundColor(output.channelCount == 2 ? AppColors.accentGreen : .secondary)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, 2)
                .background(output.channelCount == 2 ? AppColors.accentGreen.opacity(0.15) : AppColors.surfaceMedium.opacity(0.5))
                .cornerRadius(4)

            // Unlink button (for stereo)
            if let onUnlink = onUnlink, isHovered {
                Button(action: onUnlink) {
                    Image(systemName: "link.badge.minus")
                        .font(Typography.iconSmall)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Unlink stereo pair")
            }

            // Delete button
            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(Typography.iconSmall)
                    .foregroundColor(isHovered ? AppColors.accentPink : .secondary)
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1.0 : 0.4)
            .help("Remove output")
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: PanelLayout.cornerRadius)
                .fill(isHovered ? AppColors.surfaceMedium : AppColors.surfaceLight.opacity(0.5))
        )
        .onHover { hovering in
            withAnimation(AppAnimations.quick) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
struct SettingsAccordionView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsAccordionView(
            audioManager: AudioOutputManager(),
            isExpanded: .constant(true)
        )
        .frame(width: 550)
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
#endif
