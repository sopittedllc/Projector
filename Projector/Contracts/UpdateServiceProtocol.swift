//
//  UpdateServiceProtocol.swift
//  Projector
//
//  THE CONTRACT: Software Update Service
//  Layer: Contracts
//  Implemented in: Managers
//  Consumed in: Views, AppDelegate
//

import Foundation

/// Checks whether a newer Projector has been published, and installs it.
///
/// ## Why this is a protocol
///
/// The only implementation is ``SparkleUpdateService``, and one implementation
/// does not usually earn an abstraction. This one does, for a reason that is
/// about distribution rather than testing: updating a *sandboxed* app requires
/// `com.apple.security.temporary-exception.mach-lookup.global-name`, and
/// temporary-exception entitlements are not accepted on the Mac App Store.
///
/// If Projector is ever submitted there, the App Store build has to drop both
/// the entitlements and Sparkle, and take its updates from the App Store
/// instead. Every caller talking to this protocol means that build swaps in a
/// service that reports "no updates here" and changes nothing else. Calling
/// Sparkle directly from the app delegate and the settings window would make
/// the same change a hunt.
///
/// ## What an implementation is expected to do
///
/// Find out whether a newer version exists, tell the user, and - if they agree -
/// install it and relaunch. Nothing here promises *how*: the sandbox means the
/// install cannot happen in this process, and that is the implementation's
/// problem, not the caller's.
@MainActor
protocol UpdateServiceProtocol: AnyObject {

    /// Whether this build can update itself at all.
    ///
    /// False when the machinery is not configured - most importantly when no
    /// EdDSA public key has been compiled in, since an updater that cannot
    /// verify a signature must not install anything. Callers should hide their
    /// update affordances rather than offering ones that cannot work.
    var isEnabled: Bool { get }

    /// Whether a check can be started right now.
    ///
    /// False while a check or install is already in flight. Menu items and
    /// buttons should follow this rather than tracking their own busy state.
    var canCheckForUpdates: Bool { get }

    /// Whether the app looks for updates on its own.
    ///
    /// Persisted by the implementation, not by ``AppSettings``: the updater owns
    /// this preference and reads it whether or not the app has asked, so a
    /// second copy in `AppStorage` would be one that could disagree.
    var automaticallyChecksForUpdates: Bool { get set }

    /// When the last check finished, or `nil` if none has.
    var lastUpdateCheckDate: Date? { get }

    /// Check because the user asked.
    ///
    /// Reports the outcome either way, including "you are up to date" - a
    /// button that silently does nothing when there is no update reads as
    /// broken.
    func checkForUpdates()

    /// Check without being asked.
    ///
    /// Silent unless there is an update to offer, so it is safe to call at
    /// launch.
    func checkForUpdatesInBackground()
}
