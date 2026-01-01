import SwiftUI
import SwiftTimecodeCore

/// Settings window for MIDI, audio, and display configuration
struct SettingsView: View {
    @ObservedObject var midiManager: MIDIManager
    @ObservedObject var audioManager: AudioOutputManager
    @ObservedObject var settings = AppSettings.shared

    @Binding var isPresented: Bool

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
                VStack(alignment: .leading, spacing: 24) {
                    midiSection
                    Divider()
                    audioSection
                    Divider()
                    displaySection
                    Divider()
                    syncSection
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
        .frame(width: 450, height: 550)
    }

    // MARK: - MIDI Section

    private var midiSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("MIDI", systemImage: "pianokeys")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("Input Source")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Picker("MIDI Input", selection: $midiManager.selectedInputName) {
                    Text("None").tag(nil as String?)
                    ForEach(midiManager.availableInputs, id: \.self) { input in
                        Text(input).tag(input as String?)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)

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

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Audio Output", systemImage: "speaker.wave.2")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("Output Device")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

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
                .frame(maxWidth: .infinity)

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

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Display", systemImage: "tv")
                .font(.headline)

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

    // MARK: - Sync Section

    private var syncSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                .font(.headline)

            Toggle("Auto-play when MTC starts", isOn: $settings.autoPlayOnMTC)
                .font(.subheadline)

            Toggle("Auto-pause when MTC stops", isOn: $settings.autoPauseOnMTCStop)
                .font(.subheadline)

            VStack(alignment: .leading, spacing: 8) {
                Text("Re-sync when drift exceeds \(settings.syncDriftThreshold) frames")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Stepper(value: $settings.syncDriftThreshold, in: 1...10) {
                    Text("\(settings.syncDriftThreshold) frames")
                        .font(.subheadline)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Default Frame Rate")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Picker("Frame Rate", selection: $settings.defaultFrameRate) {
                    Text("23.976").tag(TimecodeFrameRate.fps23_976)
                    Text("24").tag(TimecodeFrameRate.fps24)
                    Text("25").tag(TimecodeFrameRate.fps25)
                    Text("29.97").tag(TimecodeFrameRate.fps29_97)
                    Text("30").tag(TimecodeFrameRate.fps30)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
        }
    }
}

#Preview {
    SettingsView(
        midiManager: MIDIManager(),
        audioManager: AudioOutputManager(),
        isPresented: .constant(true)
    )
}
