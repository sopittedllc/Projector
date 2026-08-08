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

    /// Whether this build should offer to replace itself at all.
    ///
    /// A development copy must not. `MARKETING_VERSION` is only stamped by the
    /// release script, so a build from Xcode calls itself whatever the project
    /// file says - and any published date-version looks newer than that. The
    /// result is an update offered on every launch from Xcode, aimed at a copy
    /// living in `DerivedData`.
    ///
    /// **And it goes through.** This was first written to test the code signature,
    /// on the assumption that Sparkle would refuse to replace a development build
    /// - it does not: the Debug configuration is signed with the same Developer ID
    /// team as a release, so Sparkle accepted it and installed the release build
    /// *over the app inside DerivedData*, which is how the assumption came to be
    /// checked. Measured after the fact: `TeamIdentifier=G398H44H6X` on the copy
    /// in the build folder, running the release version.
    ///
    /// So the discriminator is the build configuration, which is exactly the thing
    /// that differs, rather than a signature that does not.
    private static var buildCanUpdateItself: Bool {
        #if DEBUG
        return false
        #else
        return true
        #endif
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

        // A development copy must not replace itself - see
        // ``buildCanUpdateItself``, which is where the reasoning lives.
        guard Self.buildCanUpdateItself else {
            diagnosticLog(
                .info, .app,
                "Update service inert: debug build. Updates are offered to release "
                + "builds only, so a copy in DerivedData is not replaced by one from the feed."
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

// MARK: - Relaunch Handoff

/// Carries Sparkle's "now you may install" block from the updater to whoever
/// clears the way for it.
///
/// Idempotent on purpose: the interface calls ``proceed()`` once its modals are
/// gone, and a timeout calls it too in case nothing was listening. Whichever
/// arrives first continues the relaunch; the second is a no-op rather than a
/// second install.
@MainActor
final class UpdateRelaunchHandoff {
    private var installHandler: (() -> Void)?

    init(installHandler: @escaping () -> Void) {
        self.installHandler = installHandler
    }

    /// Let the install and relaunch continue.
    func proceed() {
        guard let handler = installHandler else { return }
        installHandler = nil
        diagnosticLog(.info, .app, "Update install proceeding")
        handler()
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
        guard let error else {
            diagnosticLog(.info, .app, "Update check finished")
            return
        }

        // Sparkle reports "you are already up to date" as an error object, so
        // taking the error branch at face value filed the most ordinary outcome
        // there is as a warning reading "Update check ended with: You're up to
        // date!" - which is the sort of line that sends someone hunting for a
        // fault that was never there.
        if (error as NSError).code == Int(SUError.noUpdateError.rawValue) {
            diagnosticLog(.info, .app, "Update check found nothing newer")
            return
        }

        // Everything else, including the ordinary no-network case. Still not an
        // error level: a laptop opened on a plane should not file a fault.
        diagnosticLog(.warning, .app, "Update check ended with: \(error.localizedDescription)")
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        diagnosticLog(.info, .app, "Installing update \(item.displayVersionString) (\(item.versionString))")
    }

    /// Clear anything modal out of the way before the app is asked to quit.
    ///
    /// **AppKit will not terminate an app with a modal sheet on screen**, and it
    /// says so and stops - measured, from AppKit's own log while an update was
    /// being installed with a sheet open:
    ///
    /// ```
    /// Checking whether app should terminate
    /// App termination blocked by modal sheet
    /// ```
    ///
    /// So "Install and Relaunch" appeared to do nothing at all: the download had
    /// finished, the install was ready, and the quit request was refused before
    /// `applicationShouldTerminate` could even be consulted. Nothing was broken
    /// and nothing was reported, which is the worst of both.
    ///
    /// Sparkle offers exactly the hook this needs. Returning `true` holds the
    /// relaunch open until `installHandler` is invoked, so the sheets can be
    /// closed first. Sparkle may call this again on a later attempt if the app
    /// still refuses to quit - the unsaved-changes prompt is entitled to cancel,
    /// and the update simply stays pending until the next quit.
    nonisolated func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let handoff = UpdateRelaunchHandoff(installHandler: installHandler)

                // The interface closes its own modals - windows and sheets are the
                // UI layer's business, and this file must not reach for AppKit.
                NotificationCenter.default.post(
                    name: .projectorDismissModalsRequested,
                    object: handoff
                )

                // Nothing may be listening: no window yet, or a build that does not
                // observe this. The install must not be stranded either way, and the
                // handoff only fires once whoever gets there first.
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.modalDismissalTimeout) {
                    handoff.proceed()
                }
            }
        }
        return true
    }

    /// How long to wait for the interface to clear its modals before installing
    /// regardless.
    private static let modalDismissalTimeout: TimeInterval = 3
}
