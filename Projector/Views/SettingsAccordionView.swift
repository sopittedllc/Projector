//
//  SettingsAccordionView.swift
//  Projector
//
//  Collapsible settings panel for the right panel area.
//  Follows UI rules: clean sections, action buttons in headers only.
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
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            // Audio Routing button in header (primary action for this panel)
            if isExpanded {
                Button(action: {
                    NotificationCenter.default.post(name: .showAudioRouting, object: nil)
                }) {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "slider.horizontal.3")
                            .font(Typography.iconSmall)
                        Text("Routing")
                    }
                }
                .buttonStyle(GlassActionButtonStyle(tint: AppColors.accentBlue))
                .help("Configure audio lane routing")
            }
        }
        .frame(height: PanelLayout.headerHeight)
        .padding(.horizontal, Spacing.md)
    }

    // MARK: - Settings Content

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Video Overlay Section
            settingsRow(icon: "clock", title: "Timecode Overlay") {
                Toggle("", isOn: $settings.showTimecodeOverlay)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            if settings.showTimecodeOverlay {
                settingsSubRow {
                    Text("Position")
                        .font(Typography.caption)
                        .foregroundColor(.secondary)

                    Spacer()

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

            Divider()
                .padding(.vertical, Spacing.xs)

            // Audio Output Section
            settingsRow(icon: "speaker.wave.2", title: "Output Device") {
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
                .frame(maxWidth: 180)
            }

            settingsSubRow {
                Text("\(audioManager.selectedDeviceChannelCount) channels")
                    .font(Typography.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }

            Divider()
                .padding(.vertical, Spacing.xs)

            // MIDI Sync Section
            settingsRow(icon: "cable.connector", title: "Auto-play on MTC") {
                Toggle("", isOn: $settings.autoPlayOnMTC)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            settingsRow(icon: nil, title: "Auto-pause on MTC Stop") {
                Toggle("", isOn: $settings.autoPauseOnMTCStop)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            settingsRow(icon: nil, title: "Respond to MMC") {
                Toggle("", isOn: $settings.respondToMMC)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, Spacing.sm)
    }

    // MARK: - Helpers

    /// A single settings row with icon, label, and control
    @ViewBuilder
    private func settingsRow<Content: View>(
        icon: String?,
        title: String,
        @ViewBuilder control: () -> Content
    ) -> some View {
        HStack(spacing: Spacing.sm) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(Typography.icon)
                    .foregroundColor(.secondary)
                    .frame(width: 20)
            } else {
                Spacer()
                    .frame(width: 20)
            }

            Text(title)
                .font(Typography.body)
                .foregroundColor(.primary)

            Spacer()

            control()
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .contentShape(Rectangle())
    }

    /// A sub-row for additional options (indented, smaller)
    @ViewBuilder
    private func settingsSubRow<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: Spacing.sm) {
            content()
        }
        .padding(.leading, Spacing.md + 20 + Spacing.sm) // Align with text after icon
        .padding(.trailing, Spacing.md)
        .padding(.vertical, Spacing.xs)
    }
}

// MARK: - Preview

#if DEBUG
struct SettingsAccordionView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: Spacing.md) {
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
