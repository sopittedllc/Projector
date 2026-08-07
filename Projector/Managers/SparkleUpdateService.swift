//
//  SparkleUpdateService.swift
//  Projector
//
//  Checks for a newer published build and installs it, via Sparkle.
//

import Foundation
import Sparkle

/// ``UpdateServiceProtocol`` backed by Sparkle.
///
/// ## Why Sparkle rather than doing this here
///
/// Projector is sandboxed. Nothing running inside the sandbox may write to
/// `/Applications`, so the app cannot replace itself however it downloads the
/// disk image - and ``ProVideoFormatsInstaller`` states the house position on
/// the obvious workaround: an app collecting an administrator password in its
/// own interface is indistinguishable from one harvesting it.
///
/// Sparkle's answer is an installer that runs as an XPC service outside the
/// sandbox, reached through the two `-spks`/`-spki` mach-lookup exceptions in
/// `Projector.entitlements`, with `SUEnableInstallerLauncherService` in
/// `Info.plist` telling Sparkle to use it. Writing that ourselves would mean
/// writing a privileged helper, which is the single most security-sensitive
/// thing a Mac app can ship.
///
/// ## What is checked before anything is installed
///
/// Two independent gates, neither of which this class implements:
///
/// 1. **EdDSA signature.** Every DMG is signed by `scripts/build-release.sh`
///    with a private key held in the release machine's keychain. Sparkle
///    verifies it against `SUPublicEDKey` in `Info.plist` and refuses a
///    mismatch - so a tampered appcast pointing at a hostile download does not
///    get installed.
/// 2. **Code signature.** Sparkle requires the downloaded app to be signed by
///    the same Developer ID as the running one before it will swap them.
///
/// The feed itself is public and unauthenticated, which is fine: it is a list
/// of URLs, and trust rests on the signatures rather than on the transport.
///
/// ## Threading
///
/// Main actor throughout. Sparkle calls its delegate on the main thread and
/// `SPUUpdater` expects to be driven from it; there is no real-time path here
/// to keep clear of.
@MainActor
final class SparkleUpdateService: NSObject, UpdateServiceProtocol {

    // MARK: - Sparkle

    /// Sparkle's controller, which owns the updater and the standard update UI.
    ///
    /// Started immediately. Sparkle's own scheduler then does the launch check
    /// on its terms - honouring `SUScheduledCheckInterval` and its one-hour
    /// floor - which is why ``checkForUpdatesInBackground()`` is not called
    /// from `applicationDidFinishLaunching` as well. Two schedulers checking
    /// the same feed would double the requests to no end.
    ///
    /// Optional, and built after `super.init()`, for two separate reasons.
    ///
    /// Built late because `SPUUpdater` has no settable delegate: the only way to
    /// be one is to hand `self` over at construction, and `self` does not exist
    /// until after `super.init()`.
    ///
    /// Optional because Sparkle must not be started at all without an EdDSA
    /// public key. `-[SPUUpdater startUpdater:]` fails when one is missing, and
    /// `SPUStandardUpdaterController` answers that failure with a modal
    /// "Unable to Check For Updates" alert - so a build whose key had not been
    /// generated yet would greet every launch with an error dialog. Leaving the
    /// controller nil keeps that build silent and merely un-updatable, which is
    /// the correct behaviour for an updater that could not verify a signature
    /// even if it found one.
    private var controller: SPUStandardUpdaterController?

    private var updater: SPUUpdater? { controller?.updater }

    /// Whether a usable EdDSA public key is compiled into this build.
    ///
    /// Checked here rather than left to Sparkle because Sparkle's answer to a
    /// missing key is a modal alert, and this is the check that avoids it. Only
    /// presence is checked - whether the key is *valid* is Sparkle's business,
    /// and a malformed key should fail loudly rather than be quietly ignored.
    private static var hasPublicKey: Bool {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        return !(key ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Initialization

    /// Creates the service, starting Sparkle only if this build is signed for it.
    override init() {
        super.init()

        guard Self.hasPublicKey else {
            diagnosticLog(
                .warning, .app,
                "Update service inert: no SUPublicEDKey in Info.plist. "
                + "See docs/software-update.md to generate the key pair."
            )
            return
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        self.controller = controller

        diagnosticLog(
            .info, .app,
            "Update service started (automatic checks: "
            + "\(controller.updater.automaticallyChecksForUpdates), "
            + "feed: \(controller.updater.feedURL?.absoluteString ?? "none"))"
        )
    }

    // MARK: - UpdateServiceProtocol

    var isEnabled: Bool {
        controller != nil
    }

    var canCheckForUpdates: Bool {
        updater?.canCheckForUpdates ?? false
    }

    var automaticallyChecksForUpdates: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set {
            updater?.automaticallyChecksForUpdates = newValue
            diagnosticLog(.info, .app, "Automatic update checks set to \(newValue)")
        }
    }

    var lastUpdateCheckDate: Date? {
        updater?.lastUpdateCheckDate
    }

    func checkForUpdates() {
        guard let updater else {
            diagnosticLog(.warning, .app, "Update check ignored: updater not configured")
            return
        }
        diagnosticLog(.info, .app, "Update check requested by user")
        updater.checkForUpdates()
    }

    func checkForUpdatesInBackground() {
        guard let updater else { return }
        diagnosticLog(.info, .app, "Background update check requested")
        updater.checkForUpdatesInBackground()
    }
}

// MARK: - SPUUpdaterDelegate

/// Logging only.
///
/// Every callback here records what the updater did and returns control - no
/// callback changes Sparkle's behaviour. The point is that "did it even check?"
/// is answerable from a diagnostic report, which is the first question when
/// someone is running a version they should not be.
///
/// These are optional protocol requirements, so a signature that does not match
/// one exactly is not a build error - the method simply never gets called, and
/// the log goes quiet rather than the app breaking. Worth knowing when reading
/// a report that says nothing about updates.
extension SparkleUpdateService: SPUUpdaterDelegate {

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        let build = item.versionString
        diagnosticLog(.info, .app, "Update available: \(version) (\(build))")
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        diagnosticLog(.info, .app, "Update check found nothing newer")
    }

    nonisolated func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        if let error {
            // Includes the ordinary "no network" case, so this is not an error
            // level: a laptop opened on a plane should not file a fault.
            diagnosticLog(.warning, .app, "Update check ended with: \(error.localizedDescription)")
        } else {
            diagnosticLog(.info, .app, "Update check finished")
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        diagnosticLog(.info, .app, "Installing update \(item.displayVersionString) (\(item.versionString))")
    }
}
