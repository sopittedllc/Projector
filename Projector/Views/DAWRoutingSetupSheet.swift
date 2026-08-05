//
//  DAWRoutingSetupSheet.swift
//  Projector
//
//  Sets up the aggregate device that carries Projector's stems into a DAW.
//

import AppKit
import SwiftUI

/// Walks the user from "my DAW cannot hear Projector" to a working aggregate device.
///
/// Three things have to be true, and this sheet arranges all of them: a loopback
/// driver is installed, an aggregate combines it with the user's interface, and the
/// stems are mapped onto the loopback half of that device. Each is checked rather than
/// assumed, so re-running the sheet on a machine that is already set up simply confirms
/// it.
///
/// macOS raises its own administrator prompt for the driver install. Projector never
/// asks for a password itself.
struct DAWRoutingSetupSheet: View {

    @ObservedObject var audioManager: AudioOutputManager

    /// Dismisses the sheet.
    let onDismiss: () -> Void

    /// Opens the per-DAW instructions for using the finished device.
    let onShowWalkthrough: () -> Void

    @StateObject private var model: DAWRoutingSetupModel

    /// Wide enough for the channel table to breathe without becoming a wall of text.
    private static let sheetWidth: CGFloat = 480

    init(
        audioManager: AudioOutputManager,
        onDismiss: @escaping () -> Void,
        onShowWalkthrough: @escaping () -> Void
    ) {
        self.audioManager = audioManager
        self.onDismiss = onDismiss
        self.onShowWalkthrough = onShowWalkthrough
        _model = StateObject(wrappedValue: DAWRoutingSetupModel(audioManager: audioManager))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            header
            Divider()
            content
            Divider()
            buttons
        }
        .padding(Spacing.xxl)
        .frame(width: Self.sheetWidth)
        .onAppear { model.refresh() }
        .onChangeCompat(of: audioManager.availableDevices.count) { _ in
            // The driver appears in the device list the moment it installs, with no
            // relaunch, so the sheet can move on by itself rather than asking the
            // user to confirm something they have already done.
            model.refresh()
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            Image(systemName: "waveform.badge.plus")
                .font(Typography.iconXLarge)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Send Stems to Your DAW")
                    .font(.headline)
                Text("Creates one audio device that feeds your speakers and your DAW at once.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .checking:
            ProgressView().progressViewStyle(.linear)

        case .needsDriver(let reason):
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text(reason.explanation)
                    .fixedSize(horizontal: false, vertical: true)
                Text("BlackHole is a free, open-source audio driver. Projector will "
                     + "download it from its makers; macOS will ask for your "
                     + "administrator password to install it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .needsRestart:
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Label("Audio driver installed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Restart your Mac to finish. macOS loads audio drivers when it "
                     + "starts up, and cannot pick this one up while audio is in use.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("Nothing else to download \u{2014} open this window again after "
                     + "restarting and Projector will build the device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .working(let message, let fraction):
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text(message)
                if let fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }

        case .awaitingInstaller:
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Label("Download complete", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Follow the installer and enter your administrator password when "
                     + "macOS asks. This window will continue on its own once the "
                     + "driver appears.")
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .readyToCreate(let interface, _):
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Label("Audio driver installed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Projector will combine **\(interface.name)** with the loopback "
                     + "driver into a single device.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("Projector sends only to the loopback half, leaving your "
                     + "interface's own outputs free for your DAW to monitor through.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .done(let deviceName, let map):
            VStack(alignment: .leading, spacing: Spacing.md) {
                Label("\(deviceName) is ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                AggregateRoutingSummary(map: map, outputs: audioManager.mappedOutputs)
                Text("Set your DAW to the same device to receive these inputs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Label("Setup did not finish", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack {
            if case .done = model.state {
                Button("How to use this in your DAW", action: onShowWalkthrough)
                    .buttonStyle(.link)
            }

            Spacer()

            switch model.state {
            case .checking, .working:
                Button("Cancel") { model.cancel(); onDismiss() }
                    .keyboardShortcut(.cancelAction)

            case .needsDriver:
                Button("Not Now", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                Button("Install Audio Driver") { model.installDriver() }
                    .keyboardShortcut(.defaultAction)

            case .awaitingInstaller:
                Button("Cancel", action: onDismiss)
                    .keyboardShortcut(.cancelAction)

            case .needsRestart:
                Button("OK", action: onDismiss)
                    .keyboardShortcut(.defaultAction)

            case .readyToCreate:
                Button("Cancel", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                Button("Create Audio Device") { model.createAggregate() }
                    .keyboardShortcut(.defaultAction)

            case .done:
                Button("Done", action: onDismiss)
                    .keyboardShortcut(.defaultAction)

            case .failed:
                Button("Close", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                Button("Try Again") { model.refresh() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
