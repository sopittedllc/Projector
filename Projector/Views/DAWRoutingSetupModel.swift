//
//  DAWRoutingSetupModel.swift
//  Projector
//
//  Drives the DAW routing setup: install the driver, build the device, map the stems.
//

import AppKit
import SwiftUI

/// Orchestrates the three steps behind DAW routing.
///
/// Each step is derived from the current state of the machine rather than remembered,
/// so the sheet is safe to re-open: a machine already set up simply reports that it is.
@MainActor
final class DAWRoutingSetupModel: ObservableObject {

    // MARK: - State

    /// Why the loopback driver is not usable yet.
    enum DriverNeed: Equatable {
        /// No build of the driver is installed.
        case notInstalled
        /// A build is installed but too narrow to carry both stems.
        case tooNarrow(found: Int, required: Int)

        /// What to tell the user, in terms of what they have rather than what is missing.
        var explanation: String {
            switch self {
            case .notInstalled:
                return "Sending stems to a DAW needs a loopback audio driver, which "
                    + "macOS does not include."
            case .tooNarrow(let found, let required):
                return "The installed BlackHole driver has only \(found) channels, and "
                    + "carrying both stems needs \(required). Installing the "
                    + "\(VirtualAudioPorts.preferredChannelCount)-channel build will "
                    + "leave the existing one in place."
            }
        }
    }

    /// What the sheet is showing.
    enum State: Equatable {
        /// Reading the current state of the machine.
        case checking
        /// The loopback driver has to be installed or replaced first.
        case needsDriver(DriverNeed)
        /// The driver is installed but macOS has not published its device yet.
        case needsRestart
        /// Working, with a message and optional determinate progress.
        case working(String, Double?)
        /// Installer handed to macOS; waiting for the driver to appear.
        case awaitingInstaller
        /// Everything is present; the device can be built.
        case readyToCreate(interface: AudioDevice, virtual: AudioDevice)
        /// The device exists and the stems are mapped onto it.
        case done(deviceName: String, map: AggregateChannelMap)
        /// Something went wrong, with a message for display.
        case failed(String)
    }

    @Published private(set) var state: State = .checking

    private let audioManager: AudioOutputManager
    private let installer = BlackHoleInstaller()
    private let aggregates = AggregateDeviceManager()
    private var task: Task<Void, Never>?

    /// How long to wait for the disk image to mount before leaving it to the user.
    private static let installerWaitNanoseconds: UInt64 = 3_000_000_000

    init(audioManager: AudioOutputManager) {
        self.audioManager = audioManager
    }

    // MARK: - Assessment

    /// Re-reads the machine and moves to whatever step is outstanding.
    ///
    /// Called on appearance and whenever the device list changes, which is what lets
    /// the sheet continue by itself once the driver finishes installing.
    func refresh() {
        // Do not interrupt work in flight; the device list changes while an aggregate
        // is being built, and re-entering here would restart the flow mid-step.
        if case .working = state { return }

        // Success is terminal until the sheet is dismissed. Creating the aggregate is
        // itself a change to the device list, so the listener that lets this sheet
        // continue by itself fires on the new device - and re-reading the machine here
        // finds a loopback device, an interface, and no work done, which is
        // indistinguishable from the state before the button was pressed. The sheet
        // then offered to build the device it had just built.
        if case .done = state { return }

        audioManager.refreshDevices()

        switch VirtualAudioPorts.readiness(in: audioManager.availableDevices) {
        case .missing:
            state = .needsDriver(.notInstalled)

        case .insufficientChannels(_, let found, let required):
            state = .needsDriver(.tooNarrow(found: found, required: required))

        case .installedPendingRestart:
            state = .needsRestart

        case .ready(let virtual):
            guard let interface = interfaceCandidate() else {
                state = .failed("No audio interface was found to combine with.")
                return
            }
            state = .readyToCreate(interface: interface, virtual: virtual)
        }
    }

    /// The device to treat as the user's own interface.
    ///
    /// Excludes loopback devices and Projector's own aggregate: building an aggregate
    /// out of a previous aggregate nests them, and building one out of the loopback
    /// driver would leave nothing feeding the speakers.
    private func interfaceCandidate() -> AudioDevice? {
        let usable = audioManager.availableDevices.filter {
            !VirtualAudioPorts.isVirtualPortDevice($0)
                && $0.uid != AggregateDeviceManager.aggregateUID
                && $0.outputChannelCount > 0
        }
        return usable.first { $0.uid == audioManager.selectedDeviceUID }
            ?? usable.first { $0.isSystemDefault }
            ?? usable.first
    }

    // MARK: - Driver

    /// Downloads the loopback driver and hands it to macOS Installer.
    func installDriver() {
        task?.cancel()
        state = .working("Contacting the driver's makers…", nil)

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let package = try await installer.fetchPackage { phase in
                    Task { @MainActor [weak self] in self?.apply(phase) }
                }
                guard !Task.isCancelled else { return }

                NSWorkspace.shared.open(package)
                self.state = .awaitingInstaller
            } catch {
                guard !Task.isCancelled else { return }
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    /// Reflects an installer phase in the UI.
    private func apply(_ phase: BlackHoleInstaller.Phase) {
        switch phase {
        case .idle:
            break
        case .discovering:
            state = .working("Contacting the driver's makers…", nil)
        case .downloading(let fraction):
            state = .working("Downloading the audio driver…", fraction)
        case .readyToInstall:
            state = .working("Opening the installer…", nil)
        case .failed(let message):
            state = .failed(message)
        }
    }

    // MARK: - Device

    /// Builds the aggregate, selects it, and maps the stems onto it.
    func createAggregate() {
        guard case .readyToCreate(let interface, let virtual) = state else { return }

        task?.cancel()
        state = .working("Creating the audio device…", nil)

        task = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await aggregates.createAggregate(
                    interfaceUID: interface.uid,
                    virtualUID: virtual.uid
                )
                guard !Task.isCancelled else { return }
                self.finishSetup(interface: interface, virtual: virtual)
            } catch {
                guard !Task.isCancelled else { return }
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    /// Selects the new device and seeds its outputs.
    ///
    /// The order matters: mappings are stored per device UID, so the aggregate has to
    /// be the selected device before its outputs are written, or they would be saved
    /// against whatever was selected before.
    private func finishSetup(interface: AudioDevice, virtual: AudioDevice) {
        audioManager.refreshDevices()
        audioManager.selectedDeviceUID = AggregateDeviceManager.aggregateUID

        // Stated rather than read back: the device list is published asynchronously, so
        // the composition cannot be re-derived reliably this soon after creating it. This
        // is the layout that was just built.
        let map = AggregateChannelMap(
            virtualChannelCount: virtual.outputChannelCount,
            interfaceChannelCount: interface.outputChannelCount,
            virtualComesFirst: true
        )
        audioManager.seedOutputsForAggregate(map)

        state = .done(
            deviceName: AggregateDeviceManager.aggregateName,
            map: map
        )
    }

    // MARK: - Teardown

    /// Stops work in flight.
    func cancel() {
        task?.cancel()
        task = nil
    }
}
