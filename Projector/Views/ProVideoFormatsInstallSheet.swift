//
//  ProVideoFormatsInstallSheet.swift
//  Projector
//
//  Walks the user through installing Apple's Pro Video Formats package.
//

import AppKit
import SwiftUI

/// Sheet that fetches Apple's Pro Video Formats package and hands it to macOS.
///
/// Projector downloads the disk image and opens it. The system installer does the
/// actual install and raises its own administrator prompt - Projector never asks for a
/// password itself, and could not install a system package even if it did, being
/// sandboxed.
///
/// A relaunch is offered at the end because professional decoders are bound into a
/// process when it starts, so a package installed under a running Projector does not
/// take effect until the app is restarted.
struct ProVideoFormatsInstallSheet: View {

    /// Codec that prompted this, e.g. "Avid DNxHD", shown so the user knows why.
    let codecName: String

    /// Dismisses the sheet.
    let onDismiss: () -> Void

    @StateObject private var model = ProVideoFormatsInstallModel()

    /// Width of the sheet. Wide enough for the explanatory text to breathe without
    /// becoming a wall.
    private static let sheetWidth: CGFloat = 460

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            header
            Divider()
            statusContent
            Divider()
            buttons
        }
        .padding(Spacing.xxl)
        .frame(width: Self.sheetWidth)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            Image(systemName: "film.stack")
                .font(Typography.iconXLarge)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Additional Codec Required")
                    .font(.headline)
                Text("This Mac cannot decode \(codecName).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        switch model.state {
        case .idle:
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Apple publishes a free package, Pro Video Formats, that adds "
                     + "decoders for \(codecName) and other professional formats.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("Projector can download it for you. macOS will ask for your "
                     + "administrator password to install it.")
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
                    ProgressView()
                        .progressViewStyle(.linear)
                }
            }

        case .awaitingInstaller:
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Label("Download complete", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("The installer has been opened. Follow its steps and enter your "
                     + "administrator password when macOS asks.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("If no installer window appeared, double-click "
                     + "ProVideoFormats.pkg in the Finder window that opened.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Projector must relaunch before it can use the new decoders.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Label("Download failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Text("You can download it manually from Apple instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack {
            Button("Apple's Download Page") {
                NSWorkspace.shared.open(ProVideoFormats.supportPageURL)
            }
            .buttonStyle(.link)

            Spacer()

            switch model.state {
            case .idle:
                Button("Not Now", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                Button("Download & Install") {
                    model.start()
                }
                .keyboardShortcut(.defaultAction)

            case .working:
                Button("Cancel") {
                    model.cancel()
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)

            case .awaitingInstaller:
                Button("Later", action: onDismiss)
                Button("Relaunch Projector") {
                    model.relaunch()
                }
                .keyboardShortcut(.defaultAction)

            case .failed:
                Button("Close", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                Button("Try Again") {
                    model.start()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

// MARK: - Model

/// Drives the install sheet: downloads, opens the installer, relaunches.
@MainActor
final class ProVideoFormatsInstallModel: ObservableObject {

    /// What the sheet is showing.
    enum State: Equatable {
        /// Waiting for the user to begin.
        case idle
        /// Working, with a message and optional determinate progress.
        case working(String, Double?)
        /// Installer handed to macOS; waiting on the user.
        case awaitingInstaller
        /// Something went wrong, with a message for display.
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private let installer = ProVideoFormatsInstaller()
    private var task: Task<Void, Never>?

    /// How long to wait for the disk image to mount before giving up on opening the
    /// package automatically and leaving the Finder window to the user.
    ///
    /// Expressed in nanoseconds because the app still supports macOS 12, where
    /// `Task.sleep(for:)` is unavailable.
    private static let mountWaitNanoseconds: UInt64 = 3_000_000_000

    /// Begins the download.
    func start() {
        task?.cancel()
        state = .working("Contacting Apple…", nil)

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let diskImage = try await installer.fetchPackage { phase in
                    Task { @MainActor [weak self] in
                        self?.apply(phase)
                    }
                }
                guard !Task.isCancelled else { return }
                await self.openInstaller(diskImage: diskImage)
            } catch {
                guard !Task.isCancelled else { return }
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    /// Stops an in-flight download.
    func cancel() {
        task?.cancel()
        task = nil
        state = .idle
    }

    /// Reflects an installer phase in the UI.
    private func apply(_ phase: ProVideoFormatsInstaller.Phase) {
        switch phase {
        case .idle:
            state = .idle
        case .discovering:
            state = .working("Contacting Apple…", nil)
        case .downloading(let fraction):
            state = .working("Downloading Pro Video Formats…", fraction)
        case .readyToInstall:
            state = .working("Opening the installer…", nil)
        case .failed(let message):
            state = .failed(message)
        }
    }

    /// Mounts the disk image and opens the package inside it.
    ///
    /// Opening the disk image is what mounts it; macOS then shows its contents in the
    /// Finder. Opening the package inside is attempted as well so the user does not
    /// have to, but the sandbox may not permit reading the mounted volume - in which
    /// case the Finder window is already in front of them and the sheet says so.
    private func openInstaller(diskImage: URL) async {
        NSWorkspace.shared.open(diskImage)
        state = .awaitingInstaller

        try? await Task.sleep(nanoseconds: Self.mountWaitNanoseconds)
        if let package = Self.mountedPackageURL() {
            NSWorkspace.shared.open(package)
        }
    }

    /// Finds the Pro Video Formats package on a mounted volume, if it can be read.
    ///
    /// - Returns: The package URL, or `nil` when no mounted volume exposes one.
    private static func mountedPackageURL() -> URL? {
        let keys: [URLResourceKey] = [.volumeNameKey]
        guard let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) else { return nil }

        for volume in volumes {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: volume,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            if let package = contents.first(where: {
                $0.pathExtension.lowercased() == "pkg"
                && $0.lastPathComponent.localizedCaseInsensitiveContains("ProVideoFormats")
            }) {
                return package
            }
        }
        return nil
    }

    /// Relaunches Projector so the newly installed decoders are registered.
    ///
    /// Asks this instance to quit and lets it start the replacement on its way out.
    /// Doing it in that order means the normal unsaved-changes prompt still gets its
    /// say: if the user cancels, nothing is launched and they are left with the one
    /// app they started with.
    func relaunch() {
        AppDelegate.shouldRelaunchAfterTermination = true
        NSApp.terminate(nil)
    }
}
