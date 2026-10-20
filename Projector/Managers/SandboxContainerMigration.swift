//
//  SandboxContainerMigration.swift
//  Projector
//
//  Carries settings out of the sandbox container the app used to run in.
//

import Foundation

/// Copies the settings a sandboxed Projector saved into the preferences the
/// unsandboxed app reads.
///
/// A sandboxed app's `UserDefaults` live in its container
/// (`~/Library/Containers/<bundle id>/Data/Library/Preferences`). Once the
/// sandbox is gone the same code reads `~/Library/Preferences` instead, where
/// any copy predates the sandbox. Without this the first unsandboxed launch
/// would lose the audio routing, MIDI ports, overlay settings and welcome state,
/// and bring back stale values from before.
///
/// Runs once: the container copy wins over whatever the global file holds,
/// then a marker key stops it running again. Caches and logs in the container
/// are not moved - waveforms rebuild on demand and the logs are diagnostic.
enum SandboxContainerMigration {

    /// Set once the container's settings have been copied (or found absent).
    static let completedKey = "sandboxContainerSettingsMigrated"

    /// Copies the container's settings into `defaults` if that has not happened yet.
    ///
    /// - Parameters:
    ///   - defaults: The domain to copy into; the app's standard defaults.
    ///   - containerPreferencesURL: The sandboxed app's preferences file. `nil`
    ///     derives it from the home folder and bundle identifier.
    /// - Returns: The number of settings copied; zero when already migrated or
    ///   when there was no container.
    @discardableResult
    static func migrateIfNeeded(
        defaults: UserDefaults = .standard,
        containerPreferencesURL: URL? = nil
    ) -> Int {
        guard !defaults.bool(forKey: completedKey) else { return 0 }

        var copied = 0
        if let url = containerPreferencesURL ?? defaultContainerPreferencesURL(),
           let settings = NSDictionary(contentsOf: url) as? [String: Any] {
            for (key, value) in settings {
                defaults.set(value, forKey: key)
                copied += 1
            }
        }
        defaults.set(true, forKey: completedKey)
        return copied
    }

    /// The preferences file the sandboxed build of this app wrote.
    private static func defaultContainerPreferencesURL() -> URL? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(bundleID)/Data/Library/Preferences", isDirectory: true)
            .appendingPathComponent("\(bundleID).plist")
    }
}
