import SwiftUI
import AppKit

/// Settings window for MIDI, audio, and display configuration
struct SettingsView: View {
    @ObservedObject var midiSync: MIDISyncViewModel
    @ObservedObject var audioManager: AudioOutputManager
    @ObservedObject var settings = AppSettings.shared

    @Binding var isPresented: Bool

    // Accordion section states - default to expanded
    @State private var midiExpanded = true
    @State private var audioExpanded = true
    @State private var displayExpanded = true

    @State private var showInterfaceMapping = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Settings")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 16)
            .padding(.bottom, 8)

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    accordionSection(
                        title: "MIDI",
                        icon: "pianokeys",
                        isExpanded: $midiExpanded
                    ) {
                        midiSectionContent
                    }

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
        .frame(width: 450, height: 650)
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
                HStack(spacing: 8) {
                    Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 12)

                    Label(title, systemImage: icon)
                        .font(.headline)
                        .foregroundColor(.primary)

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Content
            if isExpanded.wrappedValue {
                VStack(alignment: .leading, spacing: 12) {
                    content()
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - MIDI Section

    private var midiSectionContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Input Source")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                HStack(spacing: 8) {
                    Picker("MIDI Input", selection: Binding(
                        get: { midiSync.selectedInputName },
                        set: { newValue in
                            Task {
                                await midiSync.selectInput(newValue)
                                // Save to settings when user changes selection
                                settings.selectedMIDIInput = newValue ?? ""
                            }
                        }
                    )) {
                        Text("None").tag(nil as String?)
                        ForEach(midiSync.availableInputs, id: \.self) { input in
                            Text(input).tag(input as String?)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()

                    RefreshIconButton(helpText: "Refresh Inputs") {
                        Task {
                            await midiSync.refreshInputs()
                        }
                    }
                    Spacer()
                }
            }

            // MTC Status
            HStack {
                Circle()
                    .fill(midiSync.isReceivingMTC ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Text(midiSync.syncStatusText)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                if midiSync.isReceivingMTC {
                    Text(midiSync.timecodeString)
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                }
            }

            Toggle("Respond to MMC Commands", isOn: $settings.respondToMMC)
                .font(.subheadline)
        }
    }

    // MARK: - Audio Section

    private var audioSectionContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Output Device")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                HStack(spacing: 8) {
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

                    RefreshIconButton(helpText: "Refresh Devices") {
                        audioManager.refreshDevices()
                    }

                    Spacer()

                    Button("Map Interface") {
                        showInterfaceMapping = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.accentColor)
                    .disabled(audioManager.selectedDeviceChannelCount == 0)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                if audioManager.selectedDeviceChannelCount == 0 {
                    Text("No output channels detected for this device.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Mapped Outputs")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if audioManager.mappedOutputs.isEmpty {
                        Text("No mapped outputs yet.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(audioManager.mappedOutputs) { output in
                            HStack(spacing: 6) {
                                Text(output.name)
                                    .font(.system(size: 11, weight: .medium))
                                Text(outputChannelLabel(output))
                                    .font(.system(size: 10))
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
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Show Timecode Overlay", isOn: $settings.showTimecodeOverlay)
                .font(.subheadline)

            if settings.showTimecodeOverlay {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Overlay Position")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Picker("Position", selection: $settings.timecodeOverlayPosition) {
                        ForEach(TimecodeOverlayPosition.allCases) { position in
                            Text(position.rawValue).tag(position)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Overlay Opacity: \(Int(settings.timecodeOverlayOpacity * 100))%")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Slider(value: $settings.timecodeOverlayOpacity, in: 0.3...1.0)
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
            withAnimation(.easeInOut(duration: 0.6)) {
                rotation += 360
            }
            action()
        }) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 12, weight: .semibold))
                .rotationEffect(.degrees(rotation))
                .animation(.easeInOut(duration: 0.6), value: rotation)
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .help(helpText)
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
                VStack(alignment: .leading, spacing: 4) {
                    Text("Map Interface")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text(mappingSubtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 16)
            .padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Layout.rowSpacing) {
                    if rows.isEmpty {
                        Text("No outputs available on this device.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.top, 8)
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
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: Layout.outputWidth, alignment: .leading)

                Text("Paired")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(width: Layout.modeWidth, alignment: .leading)

                Text("with Output \(row.channelIndex - 1)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(width: Layout.displayWidth, alignment: .leading)
            } else {
                Toggle("", isOn: bindingForRow(index).isIncluded)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .frame(width: Layout.activeWidth, alignment: .leading)
                    .controlSize(.small)

                Text("Output \(row.channelIndex)")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: Layout.outputWidth, alignment: .leading)

                modeSelector(for: index)
                    .frame(width: Layout.modeWidth, alignment: .leading)

                TextField("Name", text: bindingForRow(index).name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: Layout.displayWidth)
                    .disabled(!rows[index].isIncluded)
                    .controlSize(.small)
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
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: Layout.activeWidth, alignment: .leading)

            Text("Output Name")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: Layout.outputWidth, alignment: .leading)

            Color.clear
                .frame(width: Layout.modeWidth, height: 1)

            Text("Display Name")
                .font(.caption)
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

        return HStack(spacing: 6) {
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
                .padding(4)
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
    struct PreviewWrapper: View {
        @StateObject var midiSync: MIDISyncViewModel

        init() {
            let actor = MIDISyncActor()
            self._midiSync = StateObject(wrappedValue: MIDISyncViewModel(service: actor))
        }

        var body: some View {
            SettingsView(
                midiSync: midiSync,
                audioManager: AudioOutputManager(),
                isPresented: .constant(true)
            )
        }
    }

    return PreviewWrapper()
}
