import SwiftUI
import SwiftTimecodeCore

/// Settings window for MIDI, audio, and display configuration
struct SettingsView: View {
    @ObservedObject var midiManager: MIDIManager
    @ObservedObject var audioManager: AudioOutputManager
    @ObservedObject var timelineManager: TimelineManager
    @ObservedObject var settings = AppSettings.shared

    @Binding var isPresented: Bool

    // Timeline editing state
    @State private var startTimecodeText: String = ""
    @State private var endTimecodeText: String = ""

    // Accordion section states
    @State private var timelineExpanded = false
    @State private var midiExpanded = false
    @State private var audioExpanded = false
    @State private var displayExpanded = false

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
                        title: "Timeline",
                        icon: "timeline.selection",
                        isExpanded: $timelineExpanded
                    ) {
                        timelineSectionContent
                    }

                    accordionSection(
                        title: "MIDI",
                        icon: "pianokeys",
                        isExpanded: $midiExpanded
                    ) {
                        midiSectionContent
                    }

                    accordionSection(
                        title: "Audio Output",
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
            .onAppear {
                // Initialize text fields with current values
                startTimecodeText = formatTimecode(timelineManager.timeline.config.startTimecode)
                endTimecodeText = formatTimecode(timelineManager.timeline.config.endTimecode)
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
            .onTapGesture {
                isExpanded.wrappedValue.toggle()
            }

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

    // MARK: - Timeline Section

    private var timelineSectionContent: some View {
        VStack(alignment: .leading, spacing: 12) {

            // Frame Rate
            VStack(alignment: .leading, spacing: 8) {
                Text("Frame Rate")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Picker("Frame Rate", selection: Binding(
                    get: { timelineManager.timeline.config.frameRate },
                    set: { newRate in
                        var config = timelineManager.timeline.config
                        // Convert timecodes to new frame rate
                        let startFrames = config.startTimecode.frameCount.wholeFrames
                        let endFrames = config.endTimecode.frameCount.wholeFrames
                        config.frameRate = newRate
                        config.startTimecode = Timecode(.frames(startFrames), at: newRate, by: .clamping)
                        config.endTimecode = Timecode(.frames(endFrames), at: newRate, by: .clamping)
                        timelineManager.updateConfig(config)
                        // Update text fields
                        startTimecodeText = formatTimecode(config.startTimecode)
                        endTimecodeText = formatTimecode(config.endTimecode)
                    }
                )) {
                    Text("23.976").tag(TimecodeFrameRate.fps23_976)
                    Text("24").tag(TimecodeFrameRate.fps24)
                    Text("25").tag(TimecodeFrameRate.fps25)
                    Text("29.97").tag(TimecodeFrameRate.fps29_97)
                    Text("29.97 DF").tag(TimecodeFrameRate.fps29_97d)
                    Text("30").tag(TimecodeFrameRate.fps30)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            // Start Timecode
            VStack(alignment: .leading, spacing: 8) {
                Text("Start Timecode")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Text("TC:")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)

                        TextField("00:00:00:00", text: $startTimecodeText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .frame(width: 100)
                            .onChange(of: startTimecodeText) { _, newValue in
                                let formatted = formatTimecodeInput(newValue)
                                if formatted != newValue {
                                    startTimecodeText = formatted
                                }
                            }
                            .onSubmit {
                                applyStartTimecode()
                            }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                            )
                    )

                    Button("Apply") {
                        applyStartTimecode()
                    }
                    .buttonStyle(.bordered)
                }
            }

            // End Timecode
            VStack(alignment: .leading, spacing: 8) {
                Text("End Timecode")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Text("TC:")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)

                        TextField("00:00:00:00", text: $endTimecodeText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .frame(width: 100)
                            .onChange(of: endTimecodeText) { _, newValue in
                                let formatted = formatTimecodeInput(newValue)
                                if formatted != newValue {
                                    endTimecodeText = formatted
                                }
                            }
                            .onSubmit {
                                applyEndTimecode()
                            }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                            )
                    )

                    Button("Apply") {
                        applyEndTimecode()
                    }
                    .buttonStyle(.bordered)
                }
            }

            // Duration display
            Text("Duration: \(formatDuration(timelineManager.timeline.config.durationFrames, at: timelineManager.timeline.config.frameRate))")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func applyStartTimecode() {
        let frameRate = timelineManager.timeline.config.frameRate
        if let tc = parseTimecode(startTimecodeText, at: frameRate) {
            var config = timelineManager.timeline.config
            config.startTimecode = tc
            timelineManager.updateConfig(config)
            startTimecodeText = formatTimecode(tc)
        } else {
            // Reset to current value if invalid
            startTimecodeText = formatTimecode(timelineManager.timeline.config.startTimecode)
        }
    }

    private func applyEndTimecode() {
        let frameRate = timelineManager.timeline.config.frameRate
        if let tc = parseTimecode(endTimecodeText, at: frameRate) {
            var config = timelineManager.timeline.config
            config.endTimecode = tc
            timelineManager.updateConfig(config)
            endTimecodeText = formatTimecode(tc)
        } else {
            // Reset to current value if invalid
            endTimecodeText = formatTimecode(timelineManager.timeline.config.endTimecode)
        }
    }

    private func parseTimecode(_ string: String, at frameRate: TimecodeFrameRate) -> Timecode? {
        // Strip non-numeric characters and get just digits
        let digits = string.filter { $0.isNumber }

        // Pad with leading zeros to get 8 digits (HHMMSSFF)
        let padded = String(repeating: "0", count: max(0, 8 - digits.count)) + digits
        let trimmed = String(padded.suffix(8))

        guard trimmed.count == 8 else { return nil }

        let h = Int(trimmed.prefix(2)) ?? 0
        let m = Int(trimmed.dropFirst(2).prefix(2)) ?? 0
        let s = Int(trimmed.dropFirst(4).prefix(2)) ?? 0
        let f = Int(trimmed.dropFirst(6).prefix(2)) ?? 0

        return Timecode(
            .components(h: h, m: m, s: s, f: f),
            at: frameRate,
            by: .clamping
        )
    }

    private func formatTimecode(_ tc: Timecode) -> String {
        // stringValue() returns format like "01:00:00:00"
        return tc.stringValue()
    }

    /// Format timecode input as the user types, inserting colons every 2 digits
    private func formatTimecodeInput(_ input: String) -> String {
        // Extract only digits
        let digits = input.filter { $0.isNumber }

        // Limit to 8 digits
        let limited = String(digits.prefix(8))

        // Insert colons every 2 digits
        var result = ""
        for (index, char) in limited.enumerated() {
            if index > 0 && index % 2 == 0 {
                result += ":"
            }
            result.append(char)
        }

        return result
    }

    private func formatDuration(_ frames: Int, at frameRate: TimecodeFrameRate) -> String {
        let totalSeconds = Double(frames) / frameRate.fps
        let hours = Int(totalSeconds) / 3600
        let minutes = (Int(totalSeconds) % 3600) / 60
        let seconds = Int(totalSeconds) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    // MARK: - MIDI Section

    private var midiSectionContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Input Source")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                HStack {
                    Picker("MIDI Input", selection: $midiManager.selectedInputName) {
                        Text("None").tag(nil as String?)
                        ForEach(midiManager.availableInputs, id: \.self) { input in
                            Text(input).tag(input as String?)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                }

                Button("Refresh") {
                    midiManager.refreshAvailableInputs()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundColor(.accentColor)
            }

            // MTC Status
            HStack {
                Circle()
                    .fill(midiManager.isReceivingMTC ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Text(midiManager.isReceivingMTC ? "Receiving MTC" : "No MTC Signal")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                if midiManager.isReceivingMTC {
                    Text(midiManager.currentTimecode.stringValue())
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

                HStack {
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
                    Spacer()
                }

                Button("Refresh") {
                    audioManager.refreshDevices()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundColor(.accentColor)
            }
        }
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

#Preview {
    SettingsView(
        midiManager: MIDIManager(),
        audioManager: AudioOutputManager(),
        timelineManager: TimelineManager(),
        isPresented: .constant(true)
    )
}
