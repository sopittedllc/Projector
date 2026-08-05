//
//  ProVideoFormatsInstaller.swift
//  Projector
//
//  Fetches Apple's Pro Video Formats package so macOS can decode professional codecs.
//

import Foundation

/// Fetches Apple's Pro Video Formats disk image and hands it to macOS to install.
///
/// ## What this does and does not do
///
/// Projector downloads the disk image and verifies its provenance. It never installs
/// anything itself and never asks for an administrator password: a sandboxed app cannot
/// write to `/Library`, and an app collecting admin credentials in its own interface is
/// indistinguishable from one harvesting them. The signed package is handed to macOS
/// Installer, which runs Gatekeeper and raises the system's own authentication prompt.
///
/// ## How the download is trusted
///
/// Apple does not sign the disk image itself - only the installer package inside it,
/// which carries an *Apple Software Update* certificate chain and is notarized.
/// Verified against the shipping download:
///
/// ```
/// ProVideoFormats.dmg  → code object is not signed at all
/// ProVideoFormats.pkg  → signed Apple Software Update, notarized
///                        spctl --assess --type install → accepted
/// ```
///
/// Trust therefore rests on two things:
///
/// 1. The download URL must be HTTPS on ``ProVideoFormats/downloadHost``, so a change
///    to Apple's support page can never redirect this somewhere else.
/// 2. macOS Installer runs Gatekeeper against the package's Apple signature and
///    refuses anything that fails, which is the gate that cannot be bypassed.
///
/// Projector deliberately does not attempt its own Gatekeeper assessment: the
/// `SecAssessment` API that would do it is not part of the public SDK, and duplicating
/// the check with anything weaker would imply a guarantee it could not keep.
actor ProVideoFormatsInstaller {

    // MARK: - Phases

    /// Where the fetch has got to, for display.
    enum Phase: Sendable, Equatable {
        /// Nothing started yet.
        case idle
        /// Reading Apple's support page for the current download link.
        case discovering
        /// Downloading, with fractional progress from 0 to 1.
        case downloading(Double)
        /// Downloaded and ready to hand to macOS Installer.
        case readyToInstall(URL)
        /// The fetch failed, with a message suitable for display.
        case failed(String)
    }

    // MARK: - Errors

    /// A failure while fetching the package.
    enum InstallerError: LocalizedError, Equatable {
        /// No usable download link could be found or reached.
        case noDownloadAvailable
        /// A candidate URL was not HTTPS on Apple's download host.
        case untrustedDownloadURL(String)
        /// The download did not complete.
        case downloadFailed(String)

        var errorDescription: String? {
            switch self {
            case .noDownloadAvailable:
                return "Could not find Apple's Pro Video Formats download."
            case .untrustedDownloadURL(let host):
                return "Refused a download from an unexpected location (\(host))."
            case .downloadFailed(let reason):
                return "The download did not finish: \(reason)"
            }
        }
    }

    // MARK: - Configuration

    /// Filename of the disk image Apple publishes.
    private static let diskImageName = "ProVideoFormats.dmg"

    /// How long to wait for Apple's support page before falling back.
    private static let discoveryTimeout: TimeInterval = 15

    /// Matches the package download link on Apple's support page.
    ///
    /// The path carries a per-release build token, which is exactly why the link is
    /// read live rather than hardcoded.
    private static let downloadLinkPattern =
        #"https://updates\.cdn-apple\.com/[^"'\s]*ProVideoFormats\.dmg"#

    private let urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    // MARK: - Fetching

    /// Downloads and verifies the package, reporting progress as it goes.
    ///
    /// - Parameter onPhase: Called on each change of phase. Invoked off the main actor.
    /// - Returns: Local URL of the verified disk image, ready to be opened.
    /// - Throws: ``InstallerError`` if no trusted download could be completed.
    func fetchPackage(onPhase: @Sendable @escaping (Phase) -> Void) async throws -> URL {
        onPhase(.discovering)
        let downloadURL = await resolveDownloadURL()

        try Self.validate(downloadURL)

        onPhase(.downloading(0))
        let localURL = try await download(from: downloadURL, onProgress: { fraction in
            onPhase(.downloading(fraction))
        })

        onPhase(.readyToInstall(localURL))
        return localURL
    }

    // MARK: - Discovery

    /// Finds the current download link, preferring Apple's support page.
    ///
    /// - Returns: A discovered URL, or the pinned fallback when discovery fails.
    private func resolveDownloadURL() async -> URL {
        guard let discovered = try? await discoverDownloadURL() else {
            return ProVideoFormats.fallbackDownloadURL
        }
        return discovered
    }

    /// Reads Apple's support page and extracts the package download link.
    ///
    /// - Returns: The link found on the page.
    /// - Throws: ``InstallerError/noDownloadAvailable`` if the page has no such link.
    private func discoverDownloadURL() async throws -> URL {
        var request = URLRequest(url: ProVideoFormats.supportPageURL)
        request.timeoutInterval = Self.discoveryTimeout

        let (data, _) = try await urlSession.data(for: request)
        guard let html = String(data: data, encoding: .utf8) else {
            throw InstallerError.noDownloadAvailable
        }

        guard let found = Self.firstDownloadLink(in: html) else {
            throw InstallerError.noDownloadAvailable
        }
        return found
    }

    /// Extracts the first Pro Video Formats download link from page markup.
    ///
    /// - Parameter html: The page source.
    /// - Returns: The link, or `nil` if the page contains none.
    static func firstDownloadLink(in html: String) -> URL? {
        guard let regex = try? NSRegularExpression(pattern: downloadLinkPattern) else {
            return nil
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              let matchRange = Range(match.range, in: html) else {
            return nil
        }
        return URL(string: String(html[matchRange]))
    }

    // MARK: - Trust

    /// Rejects any download URL that is not HTTPS on Apple's download host.
    ///
    /// The disk image is unsigned, so this check is what stops a compromised or
    /// altered support page pointing the installer somewhere else.
    ///
    /// - Parameter url: The candidate download URL.
    /// - Throws: ``InstallerError/untrustedDownloadURL(_:)`` when it is not Apple's.
    static func validate(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https" else {
            throw InstallerError.untrustedDownloadURL(url.scheme ?? "no scheme")
        }
        guard url.host?.lowercased() == ProVideoFormats.downloadHost else {
            throw InstallerError.untrustedDownloadURL(url.host ?? "no host")
        }
    }

    // MARK: - Download

    /// Downloads the disk image into the app's caches directory.
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

            // Written incrementally rather than held in memory so progress can be
            // reported, and so a large package never has to fit in RAM.
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
                    // Report at most once per percent; a per-byte callback would cost
                    // more than the download.
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

    /// Bytes buffered before each write to disk.
    private static let writeChunkSize = 64 * 1024

    /// Smallest change in progress worth reporting, as a fraction.
    private static let progressReportInterval = 0.01

    /// Where the downloaded disk image is written.
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
        let destination = caches.appendingPathComponent(diskImageName)
        try? FileManager.default.removeItem(at: destination)
        return destination
    }
}
