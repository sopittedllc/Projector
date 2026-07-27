import SwiftUI
import AppKit

/// Settings window for audio and display configuration.
///
/// Provides accordion-style sections for:
/// - Audio: Output device selection and channel mapping
/// - Display: Timecode overlay configuration
struct SettingsView: View {
    @ObservedObject var audioManager: AudioOutputManager
    @ObservedObject var settings = AppSettings.shared

    @Binding var isPresented: Bool

    // Accordion section states - default to expanded
    @State private var audioExpanded = true
    @State private var displayExpanded = true

    @State private var showInterfaceMapping = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Settings")
                    .font(Typography.title)
                Spacer()
            }
            .padding(.horizontal, Spacing.md)
            .padding(.top, Spacing.lg)
            .padding(.bottom, Spacing.sm)

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    // MIDI Info Blurb
                    midiInfoSection

                    accordionSection(
                        title: "Audio",
                        icon: "speaker.wave.2",
                        isExpanded: $audioExpanded
                    ) {
                        audioSectionContent
                    }

                    accordionSection(
                        title: "Display",
                        icon: "tv",
                        isExpanded: $displayExpanded
                    ) {
                        displaySectionContent
                    }
                }
                .padding()
            }

            Divider()

            // Footer
            HStack {
                Button("Reset to Defaults") {
                    settings.resetToDefaults()
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)

                Spacer()

                Button("Done") {
                    isPresented = false
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: SettingsLayout.width, height: SettingsLayout.height)
        .sheet(isPresented: $showInterfaceMapping) {
            AudioOutputMappingView(
                audioManager: audioManager,
                isPresented: $showInterfaceMapping
            )
        }
    }

    // MARK: - Accordion Helper

    @ViewBuilder
    private func accordionSection<Content: View>(
        title: String,
        icon: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            // Header - entire area is clickable
            Button(action: { isExpanded.wrappedValue.toggle() }) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(Typography.iconSmall)
                        .foregroundColor(.secondary)
                        .frame(width: Spacing.md)

                    Label(title, systemImage: icon)
                        .font(Typography.heading)
                        .foregroundColor(.primary)

                    Spacer()
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title) section, \(isExpanded.wrappedValue ? "expanded" : "collapsed")")
            .accessibilityHint("Double-tap to \(isExpanded.wrappedValue ? "collapse" : "expand")")

            // Content
            if isExpanded.wrappedValue {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    content()
                }
                .padding(.horizontal, Spacing.md)
                .padding(.bottom, Spacing.md)
            }
        }
        .glassPanel()
    }

    // MARK: - MIDI Info Section

    private var midiInfoSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Label("MIDI", systemImage: "pianokeys")
                .font(Typography.heading)

            Text("On launch, Projector creates a \"Projector MIDI IN\" port. Within your DAW, send MTC and MMC to that port and you're good to go!")
                .font(Typography.body)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel()
    }

    // MARK: - Audio Section

    private var audioSectionContent: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Output Device")
                    .font(Typography.subheading)
                    .foregroundColor(.secondary)

                HStack(spacing: Spacing.sm) {
                    Picker("Audio Output", selection: $audioManager.selectedDeviceUID) {
                        Text("System Default").tag(nil as String?)
                        ForEach(audioManager.availableDevices) { device in
                            HStack {
                                Text(device.name)
                                if device.isSystemDefault {
                                    Text("(Default)")
                                        .foregroundColor(.secondary)
                                }
                            }
                            .tag(device.uid as String?)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("Audio output device")

                    RefreshIconButton(helpText: "Refresh Devices") {
                        audioManager.refreshDevices()
                    }

                    Spacer()
                }

                Button("Map Interface") {
                    showInterfaceMapping = true
                }
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
                .disabled(audioManager.selectedDeviceChannelCount == 0)
                .accessibilityLabel("Map audio interface outputs")
            }

            VStack(alignment: .leading, spacing: Spacing.sm) {
                if audioManager.selectedDeviceChannelCount == 0 {
                    Text("No output channels detected for this device.")
                        .font(Typography.caption)
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("Mapped Outputs")
                        .font(Typography.caption)
                        .foregroundColor(.secondary)

                    if audioManager.mappedOutputs.isEmpty {
                        Text("No mapped outputs yet.")
                            .font(Typography.caption)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(audioManager.mappedOutputs) { output in
                            HStack(spacing: Spacing.sm) {
                                Text(output.name)
                                    .font(Typography.button)
                                Text(outputChannelLabel(output))
                                    .font(Typography.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func outputChannelLabel(_ output: MappedAudioOutput) -> String {
        if output.channelCount <= 1 {
            return "Out \(output.channelStart)"
        }
        let end = output.channelStart + output.channelCount - 1
        return "Out \(output.channelStart)-\(end)"
    }

    // MARK: - Display Section

    private var displaySectionContent: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Toggle("Show Timecode Overlay", isOn: $settings.showTimecodeOverlay)
                .font(Typography.body)

            if settings.showTimecodeOverlay {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("Overlay Position")
                        .font(Typography.subheading)
                        .foregroundColor(.secondary)

                    Picker("Position", selection: $settings.timecodeOverlayPosition) {
                        ForEach(TimecodeOverlayPosition.allCases) { position in
                            Text(position.rawValue).tag(position)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .accessibilityLabel("Timecode overlay position")
                }

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("Overlay Opacity: \(Int(settings.timecodeOverlayOpacity * 100))%")
                        .font(Typography.subheading)
                        .foregroundColor(.secondary)

                    Slider(value: $settings.timecodeOverlayOpacity, in: 0.3...1.0)
                        .accessibilityLabel("Overlay opacity")
                        .accessibilityValue("\(Int(settings.timecodeOverlayOpacity * 100)) percent")
                }
            }
        }
    }

}

private struct RefreshIconButton: View {
    let helpText: String
    let action: () -> Void

    @State private var isHovering = false
    @State private var rotation: Double = 0

    var body: some View {
        Button(action: {
            withAnimation(AppAnimations.slow) {
                rotation += 360
            }
            action()
        }) {
            Image(systemName: "arrow.clockwise")
                .font(Typography.icon)
                .rotationEffect(.degrees(rotation))
                .animation(AppAnimations.slow, value: rotation)
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .help(helpText)
        .accessibilityLabel(helpText)
        .onHover { hovering in
            if hovering, !isHovering {
                NSCursor.pointingHand.push()
                isHovering = true
            } else if !hovering, isHovering {
                NSCursor.pop()
                isHovering = false
            }
        }
    }
}

private struct AudioOutputMappingView: View {
    @ObservedObject var audioManager: AudioOutputManager
    @Binding var isPresented: Bool

    @State private var rows: [OutputChannelRow] = []

    private enum Layout {
        static let activeWidth: CGFloat = 50
        static let outputWidth: CGFloat = 110
        static let modeWidth: CGFloat = 84
        static let displayWidth: CGFloat = 200
        static let columnSpacing: CGFloat = 12
        static let rowHeight: CGFloat = 28
        static let rowSpacing: CGFloat = 6
        static let headerHeight: CGFloat = 16
        static let horizontalPadding: CGFloat = 16
        static let verticalPadding: CGFloat = 12
        static let listMaxHeight: CGFloat = 320
        static let listMinHeight: CGFloat = 120
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Map Interface")
                        .font(Typography.title)

                    Text(mappingSubtitle)
                        .font(Typography.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, Spacing.md)
            .padding(.top, Spacing.lg)
            .padding(.bottom, Spacing.sm)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Layout.rowSpacing) {
                    if rows.isEmpty {
                        Text("No outputs available on this device.")
                            .font(Typography.caption)
                            .foregroundColor(.secondary)
                            .padding(.top, Spacing.sm)
                    } else {
                        mappingHeaderRow
                        ForEach(rows.indices, id: \.self) { index in
                            outputRow(for: index)
                        }
                    }
                }
                .padding(.horizontal, Layout.horizontalPadding)
                .padding(.vertical, Layout.verticalPadding)
            }
            .frame(height: mappingListHeight)

            Divider()

            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .buttonStyle(.plain)

                Spacer()

                Button("Save") {
                    saveMappings()
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(rows.isEmpty)
            }
            .padding()
        }
        .frame(width: mappingWindowWidth, height: mappingWindowHeight)
        .onAppear {
            buildRows()
        }
        .onChange(of: audioManager.selectedDeviceUID) { _, _ in
            buildRows()
        }
    }

    private var mappingSubtitle: String {
        let deviceName = audioManager.selectedDevice?.name ?? "System Default"
        return "\(deviceName) - \(audioManager.selectedDeviceChannelCount) outputs"
    }

    private func buildRows() {
        let channelCount = audioManager.selectedDeviceChannelCount
        guard channelCount > 0 else {
            rows = []
            return
        }

        rows = (0..<channelCount).map { index in
            OutputChannelRow(channelIndex: index + 1)
        }

        let mappedOutputs = audioManager.mappedOutputs
        for output in mappedOutputs {
            let startIndex = output.channelStart - 1
            guard startIndex >= 0, startIndex < rows.count else { continue }
            rows[startIndex].isIncluded = true
            rows[startIndex].name = output.name
            rows[startIndex].isStereo = output.channelCount == 2
        }
    }

    private func outputRow(for index: Int) -> some View {
        let row = rows[index]
        let isLocked = isChannelLocked(index)

        return HStack(spacing: Layout.columnSpacing) {
            if isLocked {
                Color.clear
                    .frame(width: Layout.activeWidth, height: 1)

                Text("Output \(row.channelIndex)")
                    .font(Typography.body)
                    .foregroundColor(.secondary)
                    .frame(width: Layout.outputWidth, alignment: .leading)

                Text("Paired")
                    .font(Typography.bodySmall)
                    .foregroundColor(.secondary)
                    .frame(width: Layout.modeWidth, alignment: .leading)

                Text("with Output \(row.channelIndex - 1)")
                    .font(Typography.bodySmall)
                    .foregroundColor(.secondary)
                    .frame(width: Layout.displayWidth, alignment: .leading)
            } else {
                Toggle("", isOn: bindingForRow(index).isIncluded)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .frame(width: Layout.activeWidth, alignment: .leading)
                    .controlSize(.small)
                    .accessibilityLabel("Include Output \(row.channelIndex)")

                Text("Output \(row.channelIndex)")
                    .font(Typography.body)
                    .frame(width: Layout.outputWidth, alignment: .leading)

                modeSelector(for: index)
                    .frame(width: Layout.modeWidth, alignment: .leading)

                TextField("Name", text: bindingForRow(index).name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: Layout.displayWidth)
                    .disabled(!rows[index].isIncluded)
                    .controlSize(.small)
                    .accessibilityLabel("Display name for Output \(row.channelIndex)")
            }
        }
        .frame(height: Layout.rowHeight)
        .frame(width: mappingContentWidth, alignment: .leading)
        .onChange(of: rows[index].isIncluded) { _, _ in
            enforceRowRules(at: index)
        }
        .onChange(of: rows[index].isStereo) { _, _ in
            enforceRowRules(at: index)
        }
    }

    private func isChannelLocked(_ index: Int) -> Bool {
        guard index > 0 else { return false }
        let previous = rows[index - 1]
        return previous.isIncluded && previous.isStereo
    }

    private func enforceRowRules(at index: Int) {
        guard index >= 0 && index < rows.count else { return }

        if !rows[index].isIncluded {
            rows[index].isStereo = false
            rows[index].name = ""
            return
        }

        if rows[index].name.isEmpty {
            rows[index].name = defaultName(for: index)
        }

        if rows[index].isStereo {
            if index == rows.count - 1 {
                rows[index].isStereo = false
                return
            }
            rows[index + 1].isIncluded = false
            rows[index + 1].isStereo = false
            rows[index + 1].name = ""
        }
    }

    private func defaultName(for index: Int) -> String {
        let channel = index + 1
        if rows[index].isStereo && index + 1 < rows.count {
            return "Output \(channel)-\(channel + 1)"
        }
        return "Output \(channel)"
    }

    private var mappingHeaderRow: some View {
        HStack(spacing: Layout.columnSpacing) {
            Text("Active")
                .font(Typography.caption)
                .foregroundColor(.secondary)
                .frame(width: Layout.activeWidth, alignment: .leading)

            Text("Output Name")
                .font(Typography.caption)
                .foregroundColor(.secondary)
                .frame(width: Layout.outputWidth, alignment: .leading)

            Color.clear
                .frame(width: Layout.modeWidth, height: 1)

            Text("Display Name")
                .font(Typography.caption)
                .foregroundColor(.secondary)
                .frame(width: Layout.displayWidth, alignment: .leading)
        }
        .padding(.bottom, 2)
        .frame(width: mappingContentWidth, alignment: .leading)
    }

    private var mappingListHeight: CGFloat {
        let rowCount = max(rows.count, 1)
        let headerHeight: CGFloat = rows.isEmpty ? 0 : Layout.headerHeight
        let spacing: CGFloat = rows.isEmpty ? 0 : Layout.rowSpacing
        let contentHeight = headerHeight + (CGFloat(rowCount) * Layout.rowHeight) + (CGFloat(max(rowCount - 1, 0)) * spacing)
        let paddedHeight = contentHeight + (Layout.verticalPadding * 2)
        return min(Layout.listMaxHeight, max(Layout.listMinHeight, paddedHeight))
    }

    private var mappingContentWidth: CGFloat {
        Layout.activeWidth
            + Layout.outputWidth
            + Layout.modeWidth
            + Layout.displayWidth
            + (Layout.columnSpacing * 3)
    }

    private var mappingWindowWidth: CGFloat {
        mappingContentWidth + (Layout.horizontalPadding * 2)
    }

    private var mappingWindowHeight: CGFloat {
        let headerHeight: CGFloat = 72
        let footerHeight: CGFloat = 64
        return headerHeight + mappingListHeight + footerHeight
    }

    private func saveMappings() {
        var outputs: [MappedAudioOutput] = []
        var index = 0

        while index < rows.count {
            let row = rows[index]
            if row.isIncluded {
                let name = row.name.isEmpty ? defaultName(for: index) : row.name
                if row.isStereo && index + 1 < rows.count {
                    outputs.append(MappedAudioOutput(name: name, channelStart: index + 1, channelCount: 2))
                    index += 2
                    continue
                }
                outputs.append(MappedAudioOutput(name: name, channelStart: index + 1, channelCount: 1))
            }
            index += 1
        }

        audioManager.saveMappedOutputs(outputs, for: audioManager.selectedDeviceUID)
    }

    private func modeSelector(for index: Int) -> some View {
        let canEdit = rows[index].isIncluded && index < rows.count - 1
        let isStereo = bindingForRow(index).isStereo

        return HStack(spacing: Spacing.sm) {
            modeButton(
                iconName: "MonoIcon",
                isSelected: !isStereo.wrappedValue,
                isEnabled: canEdit
            ) {
                isStereo.wrappedValue = false
            }

            modeButton(
                iconName: "StereoIcon",
                isSelected: isStereo.wrappedValue,
                isEnabled: canEdit
            ) {
                isStereo.wrappedValue = true
            }
        }
    }

    private func modeButton(
        iconName: String,
        isSelected: Bool,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(iconName)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 14, height: 14)
                .foregroundColor(isSelected ? .accentColor : .secondary)
                .padding(Spacing.xs)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
    }
}

private struct OutputChannelRow: Identifiable, Hashable {
    let id = UUID()
    let channelIndex: Int
    var isIncluded: Bool = false
    var isStereo: Bool = false
    var name: String = ""
}

private extension Binding where Value == OutputChannelRow {
    var isIncluded: Binding<Bool> {
        Binding<Bool>(
            get: { wrappedValue.isIncluded },
            set: { wrappedValue.isIncluded = $0 }
        )
    }

    var isStereo: Binding<Bool> {
        Binding<Bool>(
            get: { wrappedValue.isStereo },
            set: { wrappedValue.isStereo = $0 }
        )
    }

    var name: Binding<String> {
        Binding<String>(
            get: { wrappedValue.name },
            set: { wrappedValue.name = $0 }
        )
    }
}

private extension AudioOutputMappingView {
    func bindingForRow(_ index: Int) -> Binding<OutputChannelRow> {
        Binding(
            get: { rows[index] },
            set: { rows[index] = $0 }
        )
    }
}

#Preview {
    SettingsView(
        audioManager: AudioOutputManager(),
        isPresented: .constant(true)
    )
}
