//
//  SettingsAccordionView.swift
//  Projector
//
//  Collapsible settings panel with two-column layout.
//  Top: Timecode Overlay (left) | Playback Behavior (right)
//  Bottom: Audio section with device and output ports
//

import SwiftUI

/// Collapsible settings section for the right panel
struct SettingsAccordionView: View {
    @ObservedObject var audioManager: AudioOutputManager
    @Binding var isExpanded: Bool
    @ObservedObject private var settings = AppSettings.shared

    // State for add output popover
    @State private var showAddOutputPopover = false

    var body: some View {
        VStack(spacing: 0) {
            // Header bar (always visible)
            accordionHeader

            // Content (only when expanded)
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
            // TOP ROW: Two columns
            HStack(alignment: .top, spacing: Spacing.lg) {
                // LEFT: Timecode Overlay
                timecodeOverlaySection
                    .frame(maxWidth: .infinity, alignment: .leading)

                Divider()
                    .frame(height: 80)

                // RIGHT: Playback Behavior
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

            // Show Overlay row - label and control together
            HStack(spacing: Spacing.sm) {
                Text("Show Overlay")
                    .font(Typography.body)
                    .foregroundColor(.primary)

                Toggle("", isOn: $settings.showTimecodeOverlay)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            if settings.showTimecodeOverlay {
                // Position row - label and control together
                HStack(spacing: Spacing.sm) {
                    Text("Position")
                        .font(Typography.body)
                        .foregroundColor(.primary)

                    Picker("", selection: $settings.timecodeOverlayPosition) {
                        Text("Top Left").tag(TimecodeOverlayPosition.topLeft)
                        Text("Top Right").tag(TimecodeOverlayPosition.topRight)
                        Text("Bottom Left").tag(TimecodeOverlayPosition.bottomLeft)
                        Text("Bottom Right").tag(TimecodeOverlayPosition.bottomRight)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 130)
                }
            }
        }
    }

    // MARK: - Playback Behavior Section

    private var playbackBehaviorSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("Playback Behavior")

            // Each row: label + control together, no spacer
            HStack(spacing: Spacing.sm) {
                Text("Auto-play on MTC")
                    .font(Typography.body)
                    .foregroundColor(.primary)

                Toggle("", isOn: $settings.autoPlayOnMTC)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            HStack(spacing: Spacing.sm) {
                Text("Auto-pause on MTC Stop")
                    .font(Typography.body)
                    .foregroundColor(.primary)

                Toggle("", isOn: $settings.autoPauseOnMTCStop)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            HStack(spacing: Spacing.sm) {
                Text("Respond to MMC")
                    .font(Typography.body)
                    .foregroundColor(.primary)

                Toggle("", isOn: $settings.respondToMMC)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Audio Section

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("Audio Output")

            // Device picker row - label directly next to control
            HStack(spacing: Spacing.sm) {
                Text("Device")
                    .font(Typography.body)
                    .foregroundColor(.secondary)

                Picker("", selection: Binding<String>(
                    get: { audioManager.selectedDeviceUID ?? "" },
                    set: { newValue in
                        audioManager.selectedDeviceUID = newValue.isEmpty ? nil : newValue
                        createDefaultOutputsIfNeeded()
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

                Text("\(audioManager.selectedDeviceChannelCount) ch")
                    .font(Typography.caption)
                    .foregroundColor(AppColors.textTertiary)
            }
            .padding(.vertical, Spacing.xs)

            // Output ports header with add button
            HStack {
                Text("Output Ports")
                    .font(Typography.label)
                    .foregroundColor(AppColors.textTertiary)

                Spacer()

                // Add output button
                if canAddMoreOutputs {
                    Button(action: { showAddOutputPopover = true }) {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                                .font(Typography.iconSmall)
                            Text("Add")
                                .font(Typography.caption)
                        }
                        .foregroundColor(AppColors.accentBlue)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showAddOutputPopover, arrowEdge: .bottom) {
                        AddOutputPopover(
                            totalChannels: audioManager.selectedDeviceChannelCount,
                            assignedChannels: assignedChannels,
                            onAdd: { name, channelStart, isStereo in
                                addOutput(name: name, channelStart: channelStart, isStereo: isStereo)
                                showAddOutputPopover = false
                            },
                            onCancel: { showAddOutputPopover = false }
                        )
                    }
                }
            }
            .padding(.top, Spacing.xs)

            // Output ports list
            outputPortsList

            // Unassigned channels indicator
            if !unassignedChannels.isEmpty {
                unassignedChannelsRow
            }
        }
    }

    // MARK: - Output Ports List

    private var outputPortsList: some View {
        let outputs = settings.mappedOutputs(for: audioManager.selectedDeviceUID)

        return VStack(spacing: 4) {
            if outputs.isEmpty {
                // Empty state
                HStack {
                    Image(systemName: "speaker.slash")
                        .font(Typography.icon)
                        .foregroundColor(.secondary)

                    Text("No outputs configured")
                        .font(Typography.body)
                        .foregroundColor(.secondary)

                    Spacer()

                    Button("Create Defaults") {
                        createDefaultOutputs()
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(AppColors.accentBlue)
                }
                .padding(Spacing.md)
                .background(AppColors.surfaceLight.opacity(0.5))
                .cornerRadius(PanelLayout.cornerRadius)
            } else {
                ForEach(outputs) { output in
                    OutputPortConfigRow(
                        output: output,
                        totalChannels: audioManager.selectedDeviceChannelCount,
                        assignedChannels: assignedChannels,
                        onNameChange: { newName in
                            updateOutputName(output.id, newName: newName)
                        },
                        onFormatChange: { isStereo in
                            updateOutputFormat(output.id, isStereo: isStereo)
                        },
                        onDelete: {
                            deleteOutput(output.id)
                        }
                    )
                }
            }
        }
    }

    // MARK: - Unassigned Channels Row

    private var unassignedChannelsRow: some View {
        HStack(spacing: Spacing.sm) {
            // Channel indicators
            HStack(spacing: 4) {
                ForEach(unassignedChannels.prefix(8), id: \.self) { channel in
                    ChannelPill(channel: channel, isAssigned: false)
                }
                if unassignedChannels.count > 8 {
                    Text("+\(unassignedChannels.count - 8)")
                        .font(Typography.captionSmall)
                        .foregroundColor(.secondary)
                }
            }

            Text("Unassigned")
                .font(Typography.caption)
                .foregroundColor(AppColors.textTertiary)

            Spacer()
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: PanelLayout.cornerRadius)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .foregroundColor(AppColors.borderLight)
        )
    }

    // MARK: - Channel Tracking

    /// Set of all channel numbers currently assigned to outputs
    private var assignedChannels: Set<Int> {
        let outputs = settings.mappedOutputs(for: audioManager.selectedDeviceUID)
        var channels = Set<Int>()
        for output in outputs {
            for ch in output.channelStart..<(output.channelStart + output.channelCount) {
                channels.insert(ch)
            }
        }
        return channels
    }

    /// Array of unassigned channel numbers
    private var unassignedChannels: [Int] {
        let total = audioManager.selectedDeviceChannelCount
        guard total > 0 else { return [] }
        let assigned = assignedChannels
        return (1...total).filter { !assigned.contains($0) }
    }

    /// Whether we can add more outputs
    private var canAddMoreOutputs: Bool {
        !unassignedChannels.isEmpty
    }

    // MARK: - Output Port Management

    private func createDefaultOutputsIfNeeded() {
        let outputs = settings.mappedOutputs(for: audioManager.selectedDeviceUID)
        if outputs.isEmpty {
            createDefaultOutputs()
        }
    }

    private func createDefaultOutputs() {
        let channelCount = audioManager.selectedDeviceChannelCount
        var outputs: [MappedAudioOutput] = []

        // Create stereo pairs
        var channel = 1
        var pairIndex = 1
        while channel + 1 <= channelCount {
            let name = pairIndex == 1 ? "Main" : "Output \(pairIndex)"
            outputs.append(MappedAudioOutput(
                name: name,
                channelStart: channel,
                channelCount: 2
            ))
            channel += 2
            pairIndex += 1
        }

        settings.setMappedOutputs(outputs, for: audioManager.selectedDeviceUID)
    }

    private func updateOutputName(_ id: UUID, newName: String) {
        var outputs = settings.mappedOutputs(for: audioManager.selectedDeviceUID)
        if let index = outputs.firstIndex(where: { $0.id == id }) {
            outputs[index].name = newName
            settings.setMappedOutputs(outputs, for: audioManager.selectedDeviceUID)
        }
    }

    private func updateOutputFormat(_ id: UUID, isStereo: Bool) {
        var outputs = settings.mappedOutputs(for: audioManager.selectedDeviceUID)
        guard let index = outputs.firstIndex(where: { $0.id == id }) else { return }

        let output = outputs[index]
        let newChannelCount = isStereo ? 2 : 1

        // Check if we can expand to stereo
        if isStereo && output.channelCount == 1 {
            let nextChannel = output.channelStart + 1
            // Check if next channel is available or out of bounds
            if nextChannel > audioManager.selectedDeviceChannelCount || assignedChannels.contains(nextChannel) {
                return // Can't expand
            }
        }

        outputs[index].channelCount = newChannelCount
        settings.setMappedOutputs(outputs, for: audioManager.selectedDeviceUID)
    }

    private func deleteOutput(_ id: UUID) {
        var outputs = settings.mappedOutputs(for: audioManager.selectedDeviceUID)
        outputs.removeAll { $0.id == id }
        settings.setMappedOutputs(outputs, for: audioManager.selectedDeviceUID)
    }

    private func addOutput(name: String, channelStart: Int, isStereo: Bool) {
        var outputs = settings.mappedOutputs(for: audioManager.selectedDeviceUID)
        outputs.append(MappedAudioOutput(
            name: name,
            channelStart: channelStart,
            channelCount: isStereo ? 2 : 1
        ))
        // Sort by channel start for consistent ordering
        outputs.sort { $0.channelStart < $1.channelStart }
        settings.setMappedOutputs(outputs, for: audioManager.selectedDeviceUID)
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(Typography.labelSmall)
            .foregroundColor(AppColors.textTertiary)
            .padding(.bottom, Spacing.xs)
    }
}

// MARK: - Channel Pill

/// Small visual indicator for a channel number
private struct ChannelPill: View {
    let channel: Int
    let isAssigned: Bool

    var body: some View {
        Text("\(channel)")
            .font(Typography.captionSmall)
            .foregroundColor(isAssigned ? .primary : .secondary)
            .frame(width: 20, height: 20)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isAssigned ? AppColors.accentBlue.opacity(0.2) : AppColors.surfaceLight)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isAssigned ? AppColors.accentBlue.opacity(0.5) : AppColors.borderLight, lineWidth: 1)
            )
    }
}

// MARK: - Output Port Config Row

/// Enhanced output port row with hover states and edit affordances
private struct OutputPortConfigRow: View {
    let output: MappedAudioOutput
    let totalChannels: Int
    let assignedChannels: Set<Int>
    let onNameChange: (String) -> Void
    let onFormatChange: (Bool) -> Void
    let onDelete: () -> Void

    @State private var isHovered = false
    @State private var isEditing = false
    @State private var editedName: String = ""
    @FocusState private var isNameFocused: Bool

    /// Whether this output can be expanded to stereo
    private var canExpandToStereo: Bool {
        if output.channelCount == 2 { return true } // Already stereo
        let nextChannel = output.channelStart + 1
        return nextChannel <= totalChannels && !assignedChannels.contains(nextChannel)
    }

    var body: some View {
        HStack(spacing: Spacing.sm) {
            // Channel pills
            HStack(spacing: 4) {
                ForEach(0..<output.channelCount, id: \.self) { offset in
                    ChannelPill(
                        channel: output.channelStart + offset,
                        isAssigned: true
                    )
                }
            }
            .frame(width: 48, alignment: .leading)

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
                    .onSubmit { commitEdit() }
                    .onExitCommand { cancelEdit() }
            } else {
                HStack(spacing: 4) {
                    Text(output.name)
                        .font(Typography.body)
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    // Edit affordance (pencil icon visible on hover)
                    if isHovered {
                        Image(systemName: "pencil")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { startEdit() }
            }

            Spacer()

            // Format selector (Mono/Stereo)
            Menu {
                Button(action: { onFormatChange(false) }) {
                    HStack {
                        Text("Mono")
                        if output.channelCount == 1 {
                            Image(systemName: "checkmark")
                        }
                    }
                }

                Button(action: { onFormatChange(true) }) {
                    HStack {
                        Text("Stereo")
                        if output.channelCount == 2 {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .disabled(!canExpandToStereo && output.channelCount == 1)
            } label: {
                HStack(spacing: 4) {
                    Text(output.channelCount == 2 ? "Stereo" : "Mono")
                        .font(Typography.caption)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8))
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, 4)
                .background(AppColors.surfaceMedium.opacity(0.5))
                .cornerRadius(4)
            }
            .buttonStyle(.plain)

            // Delete button
            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(Typography.iconSmall)
                    .foregroundColor(isHovered ? AppColors.accentPink : .secondary)
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1.0 : 0.5)
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

    private func startEdit() {
        editedName = output.name
        isEditing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            isNameFocused = true
        }
    }

    private func commitEdit() {
        let trimmed = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != output.name {
            onNameChange(trimmed)
        }
        isEditing = false
    }

    private func cancelEdit() {
        isEditing = false
    }
}

// MARK: - Add Output Popover

/// Popover for creating new audio outputs
private struct AddOutputPopover: View {
    let totalChannels: Int
    let assignedChannels: Set<Int>
    let onAdd: (String, Int, Bool) -> Void
    let onCancel: () -> Void

    @State private var name: String = ""
    @State private var isStereo: Bool = true
    @State private var selectedChannel: Int = 1

    /// Available channels that can start a new output
    private var availableStartChannels: [Int] {
        let unassigned = (1...totalChannels).filter { !assignedChannels.contains($0) }
        if isStereo {
            // For stereo, need consecutive pairs
            return unassigned.filter { ch in
                ch + 1 <= totalChannels && !assignedChannels.contains(ch + 1)
            }
        }
        return unassigned
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        availableStartChannels.contains(selectedChannel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Create Output")
                .font(Typography.subheading)
                .foregroundColor(.primary)

            // Name field
            VStack(alignment: .leading, spacing: 4) {
                Text("Name")
                    .font(Typography.caption)
                    .foregroundColor(.secondary)

                TextField("Output name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
            }

            // Format selector
            VStack(alignment: .leading, spacing: 4) {
                Text("Format")
                    .font(Typography.caption)
                    .foregroundColor(.secondary)

                Picker("", selection: $isStereo) {
                    Text("Stereo").tag(true)
                    Text("Mono").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                .onChange(of: isStereo) { _, _ in
                    // Reset channel selection if current is invalid
                    if !availableStartChannels.contains(selectedChannel) {
                        selectedChannel = availableStartChannels.first ?? 1
                    }
                }
            }

            // Channel selector
            VStack(alignment: .leading, spacing: 4) {
                Text("Start Channel")
                    .font(Typography.caption)
                    .foregroundColor(.secondary)

                Picker("", selection: $selectedChannel) {
                    ForEach(availableStartChannels, id: \.self) { channel in
                        if isStereo {
                            Text("Ch \(channel)-\(channel + 1)").tag(channel)
                        } else {
                            Text("Ch \(channel)").tag(channel)
                        }
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 180)
                .disabled(availableStartChannels.isEmpty)
            }

            // Buttons
            HStack {
                Button("Cancel") { onCancel() }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)

                Spacer()

                Button("Create") {
                    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    onAdd(trimmedName, selectedChannel, isStereo)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canCreate)
            }
        }
        .padding(Spacing.md)
        .frame(width: 220)
        .onAppear {
            // Set default name
            let existingCount = totalChannels > 0 ? (totalChannels - availableStartChannels.count) / 2 + 1 : 1
            name = "Output \(existingCount)"
            // Set default channel
            selectedChannel = availableStartChannels.first ?? 1
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
        .frame(width: 500)
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
#endif
