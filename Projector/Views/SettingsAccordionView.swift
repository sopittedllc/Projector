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
            // Expand/collapse button
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

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings section, \(isExpanded ? "expanded" : "collapsed")")
            .accessibilityHint("Double-tap to \(isExpanded ? "collapse" : "expand")")
        }
        .frame(height: PanelLayout.headerHeight)
        .padding(.horizontal, Spacing.md)
    }

    // MARK: - Settings Content

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            // Video Overlay Section
            settingsSection(title: "Video Overlay", icon: "clock") {
                Toggle("Show Timecode Overlay", isOn: $settings.showTimecodeOverlay)
                    .font(Typography.body)

                if settings.showTimecodeOverlay {
                    HStack {
                        Text("Position:")
                            .font(Typography.label)
                            .foregroundColor(.secondary)
                            .frame(width: 70, alignment: .leading)

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

            Divider()

            // Audio Output Section
            settingsSection(title: "Audio Output", icon: "speaker.wave.2") {
                HStack {
                    Text("Device:")
                        .font(Typography.label)
                        .foregroundColor(.secondary)
                        .frame(width: 70, alignment: .leading)

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

                HStack {
                    Text("\(audioManager.selectedDeviceChannelCount) channels available")
                        .font(Typography.caption)
                        .foregroundColor(.secondary)

                    Spacer()

                    Button(action: {
                        NotificationCenter.default.post(name: .showAudioRouting, object: nil)
                    }) {
                        HStack(spacing: Spacing.xs) {
                            Image(systemName: "slider.horizontal.3")
                            Text("Audio Routing")
                        }
                    }
                    .buttonStyle(GlassActionButtonStyle(tint: AppColors.accentBlue))
                }
            }

            Divider()

            // MIDI Sync Section
            settingsSection(title: "MIDI Sync", icon: "cable.connector") {
                Toggle("Auto-play on MTC", isOn: $settings.autoPlayOnMTC)
                    .font(Typography.body)

                Toggle("Auto-pause on MTC Stop", isOn: $settings.autoPauseOnMTCStop)
                    .font(Typography.body)

                Toggle("Respond to MMC Commands", isOn: $settings.respondToMMC)
                    .font(Typography.body)
            }
        }
        .padding(Spacing.md)
    }

    // MARK: - Helper

    @ViewBuilder
    private func settingsSection<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // Section header
            HStack(spacing: Spacing.xs) {
                Image(systemName: icon)
                    .font(Typography.icon)
                    .foregroundColor(.secondary)
                    .frame(width: 20)

                Text(title)
                    .font(Typography.label)
                    .foregroundColor(.secondary)
            }

            // Section content with indent
            VStack(alignment: .leading, spacing: Spacing.sm) {
                content()
            }
            .padding(.leading, 28) // Align with text after icon
        }
    }
}

// MARK: - Preview

#if DEBUG
struct SettingsAccordionView_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            SettingsAccordionView(
                audioManager: AudioOutputManager(),
                isExpanded: .constant(true)
            )

            SettingsAccordionView(
                audioManager: AudioOutputManager(),
                isExpanded: .constant(false)
            )
        }
        .frame(width: 400)
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
#endif
