//
//  BlackHoleInstaller.swift
//  Projector
//
//  Fetches the BlackHole loopback driver so stems can reach a DAW.
//

import Foundation

/// Fetches the BlackHole installer and hands it to macOS.
///
/// ## What this does and does not do
///
/// Projector downloads the package and hands it to macOS Installer, which runs
/// Gatekeeper and raises the system's own authentication prompt. Projector never
/// installs anything itself and never asks for an administrator password: a sandboxed
/// app cannot write to `/Library/Audio/Plug-Ins/HAL`, and an app collecting admin
/// credentials in its own interface is indistinguishable from one harvesting them.
///
/// ## Licence
///
/// BlackHole is GPL-3.0. Projector never bundles, links to, or redistributes it - the
/// package is downloaded from the vendor's own host and handed to the system installer,
/// exactly as a package manager does. **Do not vendor the `.pkg`.**
///
/// ## How the download is trusted
///
/// Verified against the shipping artifact:
///
/// ```
/// BlackHole16ch-0.7.1.pkg  Developer ID Installer: Existential Audio Inc. (Q5C99V536K)
///                          Notarization: trusted by the Apple notary service
///                          spctl --assess --type install → accepted
/// ```
///
/// Trust rests on two things: the download URL must be HTTPS on
/// ``BlackHoleRelease/downloadHost``, and macOS Installer independently refuses
/// anything failing its own Gatekeeper check - the gate that cannot be bypassed.
actor BlackHoleInstaller {

    // MARK: - Errors

    /// A failure while fetching the driver.
    enum InstallerError: LocalizedError, Equatable {
        /// No usable download could be resolved.
        case noDownloadAvailable
        /// A candidate URL was not HTTPS on the vendor's host.
        case untrustedDownloadURL(String)
        /// The download did not complete.
        case downloadFailed(String)

        var errorDescription: String? {
            switch self {
            case .noDownloadAvailable:
                return "Could not find the BlackHole download."
            case .untrustedDownloadURL(let host):
                return "Refused a download from an unexpected location (\(host))."
            case .downloadFailed(let reason):
                return "The download did not finish: \(reason)"
            }
        }
    }

    // MARK: - Phases

    /// Where the fetch has got to, for display.
    enum Phase: Sendable, Equatable {
        /// Nothing started yet.
        case idle
        /// Asking the vendor which version is current.
        case discovering
        /// Downloading, with fractional progress from 0 to 1.
        case downloading(Double)
        /// Downloaded and ready to hand to macOS Installer.
        case readyToInstall(URL)
        /// The fetch failed, with a message suitable for display.
        case failed(String)
    }

    // MARK: - Configuration

    /// How long to wait for the version lookup before falling back.
    private static let discoveryTimeout: TimeInterval = 15

    /// Bytes buffered before each write to disk.
    private static let writeChunkSize = 64 * 1024

    /// Smallest change in progress worth reporting, as a fraction.
    private static let progressReportInterval = 0.01

    private let urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    // MARK: - Fetching

    /// Downloads the installer, reporting progress as it goes.
    ///
    /// - Parameter onPhase: Called on each change of phase. Invoked off the main actor.
    /// - Returns: Local URL of the downloaded package, ready to be opened.
    /// - Throws: ``InstallerError`` if no trusted download could be completed.
    func fetchPackage(onPhase: @Sendable @escaping (Phase) -> Void) async throws -> URL {
        onPhase(.discovering)
        let downloadURL = await resolveDownloadURL()

        try Self.validate(downloadURL)

        onPhase(.downloading(0))
        let localURL = try await download(from: downloadURL) { fraction in
            onPhase(.downloading(fraction))
        }

        onPhase(.readyToInstall(localURL))
        return localURL
    }

    // MARK: - Discovery

    /// Resolves the download URL for the current release.
    ///
    /// - Returns: A URL built from the latest published version, or the pinned
    ///   fallback when the lookup fails.
    private func resolveDownloadURL() async -> URL {
        guard let version = try? await latestVersion() else {
            return BlackHoleRelease.fallbackDownloadURL
        }
        return BlackHoleRelease.downloadURL(forVersion: version)
    }

    /// Asks the project's release feed which version is current.
    ///
    /// The releases carry no attached binaries - the package is only ever served from
    /// the vendor's own host - so this reads the version and the URL is built from it.
    ///
    /// - Returns: A version string such as `"0.7.1"`.
    /// - Throws: ``InstallerError/noDownloadAvailable`` if the feed cannot be read.
    private func latestVersion() async throws -> String {
        var request = URLRequest(url: BlackHoleRelease.latestReleaseAPI)
        request.timeoutInterval = Self.discoveryTimeout
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, _) = try await urlSession.data(for: request)

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String,
              let version = BlackHoleRelease.version(fromTag: tag) else {
            throw InstallerError.noDownloadAvailable
        }
        return version
    }

    // MARK: - Trust

    /// Rejects any download URL that is not HTTPS on the vendor's host.
    ///
    /// - Parameter url: The candidate download URL.
    /// - Throws: ``InstallerError/untrustedDownloadURL(_:)`` when it is not the vendor's.
    static func validate(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https" else {
            throw InstallerError.untrustedDownloadURL(url.scheme ?? "no scheme")
        }
        guard url.host?.lowercased() == BlackHoleRelease.downloadHost else {
            throw InstallerError.untrustedDownloadURL(url.host ?? "no host")
        }
    }

    // MARK: - Download

    /// Downloads the package into the app's caches directory.
    ///
    /// - Parameters:
    ///   - url: Verified download URL.
    ///   - onProgress: Fractional progress callback, 0 to 1.
    /// - Returns: Local URL of the downloaded file.
    /// - Throws: ``InstallerError/downloadFailed(_:)`` on any transport failure.
    private func download(
        from url: URL,
        onProgress: @Sendable @escaping (Double) -> Void
    ) async throws -> URL {
        let destination = try Self.downloadDestination()

        do {
            let (bytes, response) = try await urlSession.bytes(from: url)
            let expected = response.expectedContentLength

            FileManager.default.createFile(atPath: destination.path, contents: nil)
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }

            var buffer = Data()
            buffer.reserveCapacity(Self.writeChunkSize)
            var received: Int64 = 0
            var lastReportedFraction = -1.0

            for try await byte in bytes {
                buffer.append(byte)
                received += 1

                if buffer.count >= Self.writeChunkSize {
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }

                if expected > 0 {
                    let fraction = Double(received) / Double(expected)
                    if fraction - lastReportedFraction >= Self.progressReportInterval {
                        lastReportedFraction = fraction
                        onProgress(fraction)
                    }
                }
            }

            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
            }
            onProgress(1)
            return destination
        } catch {
            throw InstallerError.downloadFailed(error.localizedDescription)
        }
    }

    /// Where the downloaded package is written.
    ///
    /// - Returns: A URL inside the app's caches directory, replacing any previous
    ///   download so a failed attempt cannot be mistaken for a complete one.
    /// - Throws: If the caches directory is unavailable.
    private static func downloadDestination() throws -> URL {
        let caches = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let destination = caches.appendingPathComponent(BlackHoleRelease.packageFilename)
        try? FileManager.default.removeItem(at: destination)
        return destination
    }
}

// MARK: - Release Details

/// Where BlackHole comes from, and what it is called.
enum BlackHoleRelease {

    /// Host serving the vendor's downloads.
    ///
    /// Any candidate URL must be on this host, so a change to the release feed can
    /// never redirect the installer somewhere else.
    static let downloadHost = "existential.audio"

    /// Release feed used to discover the current version.
    static let latestReleaseAPI = URL(
        string: "https://api.github.com/repos/ExistentialAudio/BlackHole/releases/latest"
    )!

    /// The project's home page, for the manual route.
    static let homepageURL = URL(string: "https://existential.audio/blackhole/")!

    /// Filename of the package Projector downloads.
    static let packageFilename = "BlackHole16ch.pkg"

    /// Last known version, used when the release feed cannot be read.
    private static let fallbackVersion = "0.7.1"

    /// Download URL for a given version.
    ///
    /// - Parameter version: A version string such as `"0.7.1"`.
    /// - Returns: The vendor's URL for that release of the 16-channel build.
    static func downloadURL(forVersion version: String) -> URL {
        URL(string: "https://\(downloadHost)/downloads/BlackHole\(VirtualAudioPorts.preferredChannelCount)ch-\(version).pkg")!
    }

    /// Download URL for the last known version.
    static var fallbackDownloadURL: URL {
        downloadURL(forVersion: fallbackVersion)
    }

    /// Extracts a version number from a release tag.
    ///
    /// Tags are published as `v0.7.1`; the download path uses `0.7.1`.
    ///
    /// - Parameter tag: The tag as published.
    /// - Returns: The bare version, or `nil` if the tag is not shaped like one.
    static func version(fromTag tag: String) -> String? {
        let trimmed = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard !trimmed.isEmpty,
              trimmed.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        return trimmed
    }
}
