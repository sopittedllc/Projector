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

            compactRow(title: "Show Overlay") {
                Toggle("", isOn: $settings.showTimecodeOverlay)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            if settings.showTimecodeOverlay {
                compactRow(title: "Position") {
                    Picker("", selection: $settings.timecodeOverlayPosition) {
                        Text("Top Left").tag(TimecodeOverlayPosition.topLeft)
                        Text("Top Right").tag(TimecodeOverlayPosition.topRight)
                        Text("Bottom Left").tag(TimecodeOverlayPosition.bottomLeft)
                        Text("Bottom Right").tag(TimecodeOverlayPosition.bottomRight)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 110)
                }
            }
        }
    }

    // MARK: - Playback Behavior Section

    private var playbackBehaviorSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("Playback Behavior")

            compactRow(title: "Auto-play on MTC") {
                Toggle("", isOn: $settings.autoPlayOnMTC)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            compactRow(title: "Auto-pause on MTC Stop") {
                Toggle("", isOn: $settings.autoPauseOnMTCStop)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            compactRow(title: "Respond to MMC") {
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

            // Device picker row
            HStack {
                Text("Device")
                    .font(Typography.body)
                    .foregroundColor(.secondary)

                Spacer()

                Picker("", selection: Binding<String>(
                    get: { audioManager.selectedDeviceUID ?? "" },
                    set: { newValue in
                        audioManager.selectedDeviceUID = newValue.isEmpty ? nil : newValue
                        // Create default outputs when device changes
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
                .frame(maxWidth: 200)
            }
            .padding(.vertical, Spacing.xs)

            // Output ports header
            HStack {
                Text("Output Ports")
                    .font(Typography.label)
                    .foregroundColor(AppColors.textTertiary)

                Spacer()

                Text("\(audioManager.selectedDeviceChannelCount) channels")
                    .font(Typography.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.top, Spacing.xs)

            // Output ports list
            outputPortsList
        }
    }

    // MARK: - Output Ports List

    private var outputPortsList: some View {
        let outputs = settings.mappedOutputs(for: audioManager.selectedDeviceUID)

        return VStack(spacing: 2) {
            if outputs.isEmpty {
                // Empty state - prompt to create defaults
                Button(action: createDefaultOutputs) {
                    HStack {
                        Image(systemName: "plus.circle")
                            .font(Typography.icon)
                        Text("Create Default Stereo Outputs")
                            .font(Typography.body)
                    }
                    .foregroundColor(AppColors.accentBlue)
                    .frame(maxWidth: .infinity)
                    .padding(Spacing.md)
                }
                .buttonStyle(.plain)
                .background(AppColors.surfaceLight)
                .cornerRadius(PanelLayout.cornerRadius)
            } else {
                ForEach(outputs) { output in
                    OutputPortRow(
                        output: output,
                        onNameChange: { newName in
                            updateOutputName(output.id, newName: newName)
                        },
                        onDelete: {
                            deleteOutput(output.id)
                        }
                    )
                }

                // Add output button
                if canAddMoreOutputs(existing: outputs) {
                    Button(action: addStereoOutput) {
                        HStack(spacing: Spacing.xs) {
                            Image(systemName: "plus")
                                .font(Typography.iconSmall)
                            Text("Add Stereo Output")
                                .font(Typography.caption)
                        }
                        .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, Spacing.xs)
                }
            }
        }
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

    private func deleteOutput(_ id: UUID) {
        var outputs = settings.mappedOutputs(for: audioManager.selectedDeviceUID)
        outputs.removeAll { $0.id == id }
        settings.setMappedOutputs(outputs, for: audioManager.selectedDeviceUID)
    }

    private func canAddMoreOutputs(existing: [MappedAudioOutput]) -> Bool {
        let usedChannels = existing.reduce(0) { $0 + $1.channelCount }
        return usedChannels + 2 <= audioManager.selectedDeviceChannelCount
    }

    private func addStereoOutput() {
        var outputs = settings.mappedOutputs(for: audioManager.selectedDeviceUID)
        let usedChannels = outputs.reduce(0) { $0 + $1.channelCount }
        let nextChannel = usedChannels + 1

        guard nextChannel + 1 <= audioManager.selectedDeviceChannelCount else { return }

        outputs.append(MappedAudioOutput(
            name: "Output \(outputs.count + 1)",
            channelStart: nextChannel,
            channelCount: 2
        ))
        settings.setMappedOutputs(outputs, for: audioManager.selectedDeviceUID)
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(Typography.labelSmall)
            .foregroundColor(AppColors.textTertiary)
            .padding(.bottom, Spacing.xs)
    }

    @ViewBuilder
    private func compactRow<Content: View>(
        title: String,
        @ViewBuilder control: () -> Content
    ) -> some View {
        HStack {
            Text(title)
                .font(Typography.body)
                .foregroundColor(.primary)
                .lineLimit(1)

            Spacer()

            control()
        }
    }
}

// MARK: - Output Port Row

private struct OutputPortRow: View {
    let output: MappedAudioOutput
    let onNameChange: (String) -> Void
    let onDelete: () -> Void

    @State private var editedName: String = ""
    @State private var isEditing = false
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: Spacing.sm) {
            // Channel indicator
            Text("Ch \(output.channelStart)–\(output.channelStart + output.channelCount - 1)")
                .font(Typography.mono)
                .foregroundColor(.secondary)
                .frame(width: 55, alignment: .leading)

            // Editable name
            if isEditing {
                TextField("Name", text: $editedName)
                    .textFieldStyle(.plain)
                    .font(Typography.body)
                    .focused($isFocused)
                    .onSubmit {
                        commitEdit()
                    }
                    .onExitCommand {
                        cancelEdit()
                    }
            } else {
                Text(output.name)
                    .font(Typography.body)
                    .foregroundColor(.primary)
                    .onTapGesture(count: 2) {
                        startEdit()
                    }
            }

            Spacer()

            // Format badge
            Text(output.channelCount == 2 ? "Stereo" : "Mono")
                .font(Typography.captionSmall)
                .foregroundColor(.secondary)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, 2)
                .background(AppColors.surfaceMedium.opacity(0.5))
                .cornerRadius(4)

            // Delete button
            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(Typography.iconSmall)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(0.6)
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.sm)
        .background(AppColors.surfaceLight.opacity(0.5))
        .cornerRadius(PanelLayout.cornerRadius)
    }

    private func startEdit() {
        editedName = output.name
        isEditing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            isFocused = true
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

// MARK: - Preview

#if DEBUG
struct SettingsAccordionView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsAccordionView(
            audioManager: AudioOutputManager(),
            isExpanded: .constant(true)
        )
        .frame(width: 450)
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
#endif
