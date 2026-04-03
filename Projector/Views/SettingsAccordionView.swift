//
//  SettingsAccordionView.swift
//  Projector
//
//  Collapsible settings panel that appears in the right panel area.
//  Shows key settings inline without opening a modal sheet.
//

import SwiftUI

/// Collapsible settings section for the right panel
struct SettingsAccordionView: View {
    @ObservedObject var audioManager: AudioOutputManager
    @Binding var isExpanded: Bool
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerBar

            Divider()

            // Settings content
            settingsContent
        }
        .glassPanel()
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: Spacing.sm) {
            Button(action: {
                withAnimation(AppAnimations.standard) {
                    isExpanded = false
                }
            }) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 12)

                    Image(systemName: "gearshape")
                        .frame(width: 14, height: 14)
                        .foregroundColor(.secondary)

                    Text("Settings")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(height: PanelLayout.headerHeight)
        .padding(.horizontal, Spacing.md)
    }

    // MARK: - Settings Content

    private var settingsContent: some View {
        VStack(spacing: Spacing.md) {
            // Timecode Overlay Section
            GroupBox {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Toggle("Show Timecode Overlay", isOn: $settings.showTimecodeOverlay)
                        .font(Typography.body)

                    if settings.showTimecodeOverlay {
                        HStack {
                            Text("Position:")
                                .font(Typography.label)
                                .foregroundColor(.secondary)

                            Picker("", selection: $settings.timecodeOverlayPosition) {
                                Text("Top Left").tag(TimecodeOverlayPosition.topLeft)
                                Text("Top Right").tag(TimecodeOverlayPosition.topRight)
                                Text("Bottom Left").tag(TimecodeOverlayPosition.bottomLeft)
                                Text("Bottom Right").tag(TimecodeOverlayPosition.bottomRight)
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }

                        HStack {
                            Text("Opacity:")
                                .font(Typography.label)
                                .foregroundColor(.secondary)

                            Slider(value: $settings.timecodeOverlayOpacity, in: 0.3...1.0)
                                .frame(width: 120)

                            Text("\(Int(settings.timecodeOverlayOpacity * 100))%")
                                .font(Typography.monoSmall)
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                }
            } label: {
                Label("Video Overlay", systemImage: "clock")
                    .font(Typography.subheading)
            }

            // Audio Output Section
            GroupBox {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    HStack {
                        Text("Output Device:")
                            .font(Typography.label)
                            .foregroundColor(.secondary)

                        Picker("", selection: Binding<String>(
                            get: { audioManager.selectedDeviceUID ?? "" },
                            set: { newValue in audioManager.selectedDeviceUID = newValue.isEmpty ? nil : newValue }
                        )) {
                            Text("System Default").tag("")
                            ForEach(audioManager.availableDevices, id: \.uid) { device in
                                Text(device.name).tag(device.uid)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }

                    Text("\(audioManager.selectedDeviceChannelCount) channels available")
                        .font(Typography.caption)
                        .foregroundColor(.secondary)
                }
            } label: {
                Label("Audio Output", systemImage: "speaker.wave.2")
                    .font(Typography.subheading)
            }

            // MIDI Section
            GroupBox {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Toggle("Auto-play on MTC", isOn: $settings.autoPlayOnMTC)
                        .font(Typography.body)

                    Toggle("Auto-pause on MTC Stop", isOn: $settings.autoPauseOnMTCStop)
                        .font(Typography.body)

                    Toggle("Respond to MMC Commands", isOn: $settings.respondToMMC)
                        .font(Typography.body)
                }
            } label: {
                Label("MIDI Sync", systemImage: "cable.connector")
                    .font(Typography.subheading)
            }
        }
        .padding(Spacing.md)
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
        .frame(width: 400)
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
#endif
