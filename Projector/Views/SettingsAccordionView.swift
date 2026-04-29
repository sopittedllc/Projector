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
        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
            // Two columns: Timecode Overlay | Playback Behavior
            HStack(alignment: .top, spacing: Spacing.xxl) {
                timecodeOverlaySection
                playbackBehaviorSection
                Spacer()
            }

            Divider()

            // Audio section (full width)
            audioSection
        }
        .padding(.horizontal, SettingsLayout.windowMargin)
        .padding(.vertical, Spacing.md)
    }

    // MARK: - Timecode Overlay Section

    private var timecodeOverlaySection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("Timecode Overlay")

            VStack(alignment: .leading, spacing: SettingsLayout.formRowVerticalSpacing) {
                HStack {
                    Text("Show Overlay")
                        .font(Typography.body)
                    Spacer()
                    Toggle("", isOn: $settings.showTimecodeOverlay)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }

                if settings.showTimecodeOverlay {
                    HStack {
                        Text("Position")
                            .font(Typography.body)
                        Spacer()
                        Picker("", selection: $settings.timecodeOverlayPosition) {
                            Text("Top Left").tag(TimecodeOverlayPosition.topLeft)
                            Text("Top Right").tag(TimecodeOverlayPosition.topRight)
                            Text("Bottom Left").tag(TimecodeOverlayPosition.bottomLeft)
                            Text("Bottom Right").tag(TimecodeOverlayPosition.bottomRight)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                }
            }
        }
        .frame(width: SettingsLayout.formSectionWidth)
    }

    // MARK: - Playback Behavior Section

    private var playbackBehaviorSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("Playback Behavior")

            VStack(alignment: .leading, spacing: SettingsLayout.formRowVerticalSpacing) {
                HStack {
                    Text("Auto-play on MTC")
                        .font(Typography.body)
                    Spacer()
                    Toggle("", isOn: $settings.autoPlayOnMTC)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }

                HStack {
                    Text("Auto-pause on MTC Stop")
                        .font(Typography.body)
                    Spacer()
                    Toggle("", isOn: $settings.autoPauseOnMTCStop)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }

                HStack {
                    Text("Respond to MMC")
                        .font(Typography.body)
                    Spacer()
                    Toggle("", isOn: $settings.respondToMMC)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }
        }
        .frame(width: SettingsLayout.formSectionWidth)
    }

    // MARK: - Audio Section

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionHeader("Audio Output")

            // Device picker row
            HStack {
                Text("Device")
                    .font(Typography.body)
                Spacer().frame(width: Spacing.sm)
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
            }

            // Channel grid (only if device has channels)
            if audioManager.selectedDeviceChannelCount > 0 {
                ChannelGridView(
                    totalChannels: audioManager.selectedDeviceChannelCount,
                    outputs: settings.mappedOutputs(for: audioManager.selectedDeviceUID),
                    onOutputsChanged: { newOutputs in
                        settings.setMappedOutputs(newOutputs, for: audioManager.selectedDeviceUID)
                    }
                )
            } else {
                // 2.5: Device no-channels feedback
                Text("Selected device has no configurable outputs")
                    .font(Typography.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, Spacing.xs)
            }
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(Typography.labelSmall)
            .foregroundColor(AppColors.textTertiary)
            .padding(.bottom, Spacing.xs)
    }
}

// MARK: - Channel Grid View

/// Channel-first grid showing all device channels with activation/linking support
private struct ChannelGridView: View {
    let totalChannels: Int
    let outputs: [MappedAudioOutput]
    let onOutputsChanged: ([MappedAudioOutput]) -> Void

    @State private var draggedChannel: Int? = nil   // Channel being dragged
    @State private var dragTargetChannel: Int? = nil  // Channel being hovered over during drag
    @State private var hoveredStereoGroup: UUID? = nil  // Currently hovered stereo group
    @State private var dragLocation: CGPoint = .zero  // Current drag position in grid coordinates

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // Channels header with instructional sublabel
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Channels")
                    .font(Typography.label)
                    .foregroundColor(AppColors.textTertiary)
                Text("Click to select for stereo linking • Double-click for mono")
                    .font(Typography.caption)
                    .foregroundColor(AppColors.textTertiary)
            }

            // Channel cells grid
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

    /// Check if this channel is being dragged
    private func isBeingDragged(_ channel: Int) -> Bool {
        draggedChannel == channel
    }

    /// Check if this channel is a valid drag target
    private func isValidDragTarget(_ channel: Int, from sourceChannel: Int? = nil) -> Bool {
        let dragged = sourceChannel ?? draggedChannel
        guard let dragged = dragged else { return false }
        guard abs(channel - dragged) == 1 else { return false }  // Must be adjacent
        return channelState(for: channel) == .inactive
    }

    /// Check if this channel is being hovered during drag
    private func isDragTarget(_ channel: Int) -> Bool {
        dragTargetChannel == channel && isValidDragTarget(channel)
    }

    /// Calculate which channel the drag is over based on position
    private func channelAtPosition(_ position: CGPoint) -> Int? {
        let cellWidth = SettingsLayout.channelCellSize + SettingsLayout.channelCellSpacing
        let index = Int(position.x / cellWidth)
        let channel = index + 1  // Channels are 1-indexed
        guard channel >= 1 && channel <= totalChannels else { return nil }
        return channel
    }

    /// Update drag target based on current drag position
    private func updateDragTarget(at position: CGPoint, from sourceChannel: Int) {
        if let channel = channelAtPosition(position), isValidDragTarget(channel, from: sourceChannel) {
            dragTargetChannel = channel
        } else {
            dragTargetChannel = nil
        }
    }

    private var channelGrid: some View {
        HStack(spacing: SettingsLayout.channelCellSpacing) {
            ForEach(channelItems) { item in
                switch item {
                case .inactive(let channel):
                    ChannelCellView(
                        channel: channel,
                        state: .inactive,
                        isBeingDragged: isBeingDragged(channel),
                        isDragTarget: isDragTarget(channel),
                        onDragStarted: {
                            // If another channel is already selected and this is adjacent, link them
                            if let existingDrag = draggedChannel, existingDrag != channel {
                                if isValidDragTarget(channel, from: existingDrag) {
                                    linkChannels(existingDrag, channel)
                                    draggedChannel = nil
                                    dragTargetChannel = nil
                                    return
                                }
                            }
                            // Otherwise, select this channel
                            draggedChannel = channel
                        },
                        onDragChanged: { location in
                            dragLocation = location
                            updateDragTarget(at: location, from: channel)
                        },
                        onDragEnded: {
                            if let target = dragTargetChannel, isValidDragTarget(target, from: channel) {
                                linkChannels(channel, target)
                            }
                            draggedChannel = nil
                            dragTargetChannel = nil
                        },
                        onActivate: { activateChannel(channel) },
                        onHoverChanged: { isHovered in
                            // When hovering over a valid link target, show green glow
                            if isHovered, let source = draggedChannel, isValidDragTarget(channel, from: source) {
                                dragTargetChannel = channel
                            } else if !isHovered && dragTargetChannel == channel {
                                dragTargetChannel = nil
                            }
                        }
                    )

                case .mono(let channel, _):
                    ChannelCellView(
                        channel: channel,
                        state: channelState(for: channel),
                        isBeingDragged: false,
                        isDragTarget: false,
                        onDragStarted: { },
                        onDragChanged: { _ in },
                        onDragEnded: { },
                        onActivate: { },
                        onHoverChanged: { _ in }
                    )

                case .stereoGroup(let channels, let outputId):
                    StereoGroupView(
                        channels: channels,
                        isHoveredForUnlink: hoveredStereoGroup == outputId,
                        onUnlink: { unlinkOutput(outputId) },
                        onHover: { isHovered in
                            hoveredStereoGroup = isHovered ? outputId : nil
                        }
                    )
                }
            }
        }
        .coordinateSpace(name: "channelGrid")
    }

    // MARK: - Outputs List

    private var outputsList: some View {
        VStack(spacing: 4) {
            ForEach(outputs) { output in
                OutputRowView(
                    output: output,
                    outputName: bindingForOutputName(output.id),
                    onNameChanged: { newName in
                        renameOutput(output.id, to: newName)
                    },
                    onUnlink: output.channelCount > 1 ? { unlinkOutput(output.id) } : nil,
                    onDelete: { deleteOutput(output.id) }
                )
            }
        }
    }

    /// Create a binding to an output's name for inline editing
    private func bindingForOutputName(_ id: UUID) -> Binding<String> {
        Binding(
            get: { outputs.first(where: { $0.id == id })?.name ?? "" },
            set: { newValue in
                renameOutput(id, to: newValue)
            }
        )
    }

    private func renameOutput(_ id: UUID, to newName: String) {
        var newOutputs = outputs
        if let index = newOutputs.firstIndex(where: { $0.id == id }) {
            newOutputs[index].name = newName
            onOutputsChanged(newOutputs)
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

    // MARK: - Channel Actions

    private func activateChannel(_ channel: Int) {
        var newOutputs = outputs
        newOutputs.append(MappedAudioOutput(
            name: "Ch \(channel)",
            channelStart: channel,
            channelCount: 1
        ))
        newOutputs.sort { $0.channelStart < $1.channelStart }
        onOutputsChanged(newOutputs)
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
    }

    // MARK: - Output Management

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
/// Sized to match two cell widths for consistent grid layout
private struct StereoGroupView: View {
    let channels: (Int, Int)
    let isHoveredForUnlink: Bool
    let onUnlink: () -> Void
    let onHover: (Bool) -> Void

    // Width to cover both cells plus the spacing between them
    private var totalWidth: CGFloat {
        SettingsLayout.channelCellSize * 2 + SettingsLayout.channelCellSpacing
    }

    var body: some View {
        Button(action: onUnlink) {
            HStack(spacing: 4) {
                // Left channel with L badge (2.3)
                HStack(spacing: 2) {
                    Text("\(channels.0)")
                        .font(Typography.captionSmall)
                        .foregroundColor(.primary)
                    Text("L")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 2)
                        .padding(.vertical, 1)
                        .background(AppColors.accentGreen)
                        .cornerRadius(2)
                }

                Image(systemName: "link")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(AppColors.accentGreen.opacity(0.8))

                // Right channel with R badge (2.3)
                HStack(spacing: 2) {
                    Text("\(channels.1)")
                        .font(Typography.captionSmall)
                        .foregroundColor(.primary)
                    Text("R")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 2)
                        .padding(.vertical, 1)
                        .background(AppColors.accentGreen)
                        .cornerRadius(2)
                }
            }
            .frame(width: totalWidth, height: SettingsLayout.channelCellSize)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHoveredForUnlink ? AppColors.accentPink.opacity(0.35) : AppColors.accentGreen.opacity(0.2))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isHoveredForUnlink ? AppColors.accentPink.opacity(0.6) : AppColors.accentGreen.opacity(0.4), lineWidth: 1)
            )
            .scaleEffect(isHoveredForUnlink ? 1.03 : 1.0)
            .shadow(color: isHoveredForUnlink ? AppColors.accentPink.opacity(0.5) : .clear, radius: isHoveredForUnlink ? 3 : 0)
        }
        .buttonStyle(.plain)
        .animation(AppAnimations.quick, value: isHoveredForUnlink)
        .onHover { hovering in
            withAnimation(AppAnimations.quick) {
                onHover(hovering)
            }
        }
        .help(isHoveredForUnlink ? "Click to unlink stereo pair" : "Linked stereo pair")
    }
}
// MARK: - Channel Cell View

/// Individual channel cell in the grid (for inactive and mono channels)
private struct ChannelCellView: View {
    let channel: Int
    let state: ChannelState
    let isBeingDragged: Bool
    let isDragTarget: Bool
    let onDragStarted: () -> Void
    let onDragChanged: (CGPoint) -> Void  // Reports position in grid coordinate space
    let onDragEnded: () -> Void
    let onActivate: () -> Void
    let onHoverChanged: (Bool) -> Void  // Report hover state to parent

    @State private var isHovered = false

    private var isInactive: Bool {
        if case .inactive = state { return true }
        return false
    }

    // Computed properties for visual effects
    private var hoverScale: CGFloat {
        if isBeingDragged { return 1.06 }
        if isDragTarget { return 1.05 }
        if isHovered { return 1.03 }
        return 1.0
    }

    private var borderWidth: CGFloat {
        if isBeingDragged || isDragTarget { return 2 }
        if isHovered { return 1.5 }
        return 1
    }

    private var shadowColor: Color {
        if isDragTarget { return AppColors.accentGreen }
        if isBeingDragged { return AppColors.accentYellow }
        if isHovered { return AppColors.accentBlue }
        return .clear
    }

    private var shadowRadius: CGFloat {
        if isDragTarget || isBeingDragged { return 4 }
        if isHovered { return 3 }
        return 0
    }

    private var isMono: Bool {
        if case .activeMono = state { return true }
        return false
    }

    var body: some View {
        ZStack {
            // Background
            RoundedRectangle(cornerRadius: 6)
                .fill(backgroundColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(borderColor, lineWidth: borderWidth)
                )

            // Channel number
            Text("\(channel)")
                .font(Typography.mono)
                .foregroundColor(textColor)

            // Mono badge (2.3) - shown for active mono channels
            if isMono {
                Text("M")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white)
                    .padding(2)
                    .background(AppColors.accentBlue)
                    .cornerRadius(3)
                    .offset(x: 14, y: -14)
            }

            // Mono activation button (1.3) - shown on hover for inactive channels
            if isInactive && isHovered {
                Button(action: { onActivate() }) {
                    Text("M")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 16, height: 16)
                        .background(AppColors.accentBlue)
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .offset(x: 14, y: -14)
                .help("Activate as mono output")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: SettingsLayout.channelCellSize, height: SettingsLayout.channelCellSize)
        .contentShape(Rectangle())
        .scaleEffect(hoverScale)
        .shadow(color: shadowColor.opacity(0.5), radius: shadowRadius)
        .animation(AppAnimations.quick, value: isHovered)
        .animation(AppAnimations.quick, value: isBeingDragged)
        .animation(AppAnimations.quick, value: isDragTarget)
        .onHover { hovering in
            withAnimation(AppAnimations.quick) {
                isHovered = hovering
            }
            onHoverChanged(hovering)
        }
        .onTapGesture(count: 2) {
            // Double-click to activate as mono
            if isInactive {
                onActivate()
            }
        }
        .onTapGesture(count: 1) {
            // Single click to select for linking
            if isInactive {
                onDragStarted()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if isInactive && !isBeingDragged {
                        onDragStarted()
                    }
                    onDragChanged(value.location)
                }
                .onEnded { _ in
                    onDragEnded()
                }
        )
        .contextMenu {
            if isInactive {
                Button("Activate as Mono") { onActivate() }
            }
        }
        .help(helpText)
        .cursor(isInactive ? (isBeingDragged ? .closedHand : .openHand) : .arrow)
    }

    private var backgroundColor: Color {
        if isBeingDragged {
            return AppColors.accentYellow.opacity(0.4)
        }
        if isDragTarget {
            return AppColors.accentGreen.opacity(0.4)
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
        if isBeingDragged {
            return AppColors.accentYellow.opacity(0.7)
        }
        if isDragTarget {
            return AppColors.accentGreen.opacity(0.7)
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
        if isBeingDragged || isDragTarget {
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
            if isBeingDragged {
                return "Drag to adjacent channel to create stereo pair"
            }
            if isDragTarget {
                return "Release to link as stereo"
            }
            return "Drag to link, right-click to activate as mono"
        case .activeMono:
            return "Active mono output"
        case .stereoPrimary, .stereoSecondary:
            return "Linked stereo pair"
        }
    }
}

// MARK: - Cursor Extension

extension View {
    /// Sets the cursor type when hovering over this view
    func cursor(_ cursor: NSCursor) -> some View {
        self.onHover { isHovered in
            if isHovered {
                cursor.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

// MARK: - Output Row View

/// Row showing a configured output with rename/delete controls
private struct OutputRowView: View {
    let output: MappedAudioOutput
    @Binding var outputName: String
    let onNameChanged: (String) -> Void
    let onUnlink: (() -> Void)?
    let onDelete: () -> Void

    @State private var isHovered = false
    @FocusState private var isNameFocused: Bool
    @State private var originalName = ""

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

            // Name - always-visible TextField (2.1)
            TextField("Output Name", text: $outputName)
                .textFieldStyle(.roundedBorder)
                .font(Typography.body)
                .frame(width: 120)
                .focused($isNameFocused)
                .onSubmit {
                    let trimmed = outputName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        onNameChanged(trimmed)
                    }
                    isNameFocused = false
                }
                .onExitCommand {
                    outputName = originalName
                    isNameFocused = false
                }
                .onChange(of: isNameFocused) { _, focused in
                    if focused {
                        // Capture original when focus gained
                        originalName = outputName
                    } else {
                        // Save on blur
                        let trimmed = outputName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            onNameChanged(trimmed)
                        }
                    }
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
