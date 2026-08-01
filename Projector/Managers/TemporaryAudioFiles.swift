//
//  TemporaryAudioFiles.swift
//  Projector
//
//  One home, and one naming scheme, for audio the app extracts to disk.
//

import Foundation
import CryptoKit

/// Names and sweeps the audio files the app extracts from media.
///
/// Importing a video writes its audio track out so the timeline has something
/// to play and draw; splitting a hard-panned reel writes one file per side.
/// These are caches - every one can be regenerated from the source - but they
/// are large, a feature-length reel costing a few hundred megabytes each.
///
/// ## Why they piled up
///
/// Both writers named their files in ways that could never be reused:
///
/// - the extracted audio track used `String.hashValue`, which is seeded per
///   process, so the same reel got a different filename on every launch
/// - the split channels appended a fresh UUID, so re-splitting a reel wrote a
///   new pair every time rather than finding the one already there
///
/// Nothing deleted either. A few sessions of work left tens of gigabytes of
/// files that no project referenced and nothing would ever look at again.
///
/// Names are now derived from the source path, so a file that already exists is
/// the file that gets used, and everything lands in one directory that can be
/// swept without touching anything else in the temporary area.
enum TemporaryAudioFiles {

    // MARK: - Constants

    private enum Config {
        /// Own directory, so a sweep can be sure of what it is deleting.
        static let directoryName = "ExtractedAudio"

        /// Characters of the digest kept in a filename.
        ///
        /// 16 hex characters is 64 bits - collision between two source paths on
        /// one machine is not a practical concern, and the whole digest makes
        /// for an unreadable name while debugging.
        static let digestLength = 16

        /// How long an unused file is kept before a sweep takes it.
        ///
        /// Long enough to survive a few days of work on the same reels, which is
        /// the point of a stable name; short enough that a finished job does not
        /// leave gigabytes behind indefinitely.
        static let maximumUnusedDays = 7
    }

    // MARK: - Location

    /// Directory holding every extracted audio file.
    static var directory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(Config.directoryName, isDirectory: true)
    }

    /// A stable file URL for one piece of extracted audio.
    ///
    /// The same source and role always give the same URL, on this launch and the
    /// next, so an extraction already on disk is found rather than rewritten.
    ///
    /// - Parameters:
    ///   - source: Media the audio came from.
    ///   - role: What this file is - a track index, or a channel.
    ///   - fileExtension: Container extension, without the dot.
    /// - Returns: Where that file belongs.
    static func url(for source: URL, role: String, fileExtension: String) -> URL {
        createDirectoryIfNeeded()
        let base = source.deletingPathExtension().lastPathComponent
        let digest = stableDigest(of: "\(source.absoluteString)-\(role)")
        // The readable stem is for whoever is looking in this directory later;
        // the digest is what actually makes the name unique.
        return directory.appendingPathComponent("\(base)-\(role)-\(digest).\(fileExtension)")
    }

    // MARK: - Cleanup

    /// Delete an extracted file that is known to be superseded.
    ///
    /// - Parameter url: File to remove. Ignored if it is not one of ours, so a
    ///   caller cannot delete a user's media by passing the wrong URL.
    static func remove(_ url: URL?) {
        guard let url, isManaged(url) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Remove extracted files nothing has used for a while.
    ///
    /// Age is judged by last access where the filesystem records it, falling
    /// back to modification date. A reel still being worked on is read every
    /// time its waveform or playback is loaded, so it stays; one from a finished
    /// job ages out.
    ///
    /// Deleting a file that is still referenced is safe - a clip whose extracted
    /// audio has gone falls back to reading the original source - which is what
    /// makes an age rule usable at all, since the alternative is knowing every
    /// open document's referenced files.
    ///
    /// - Parameter now: Current date, injectable for tests.
    /// - Returns: Number of bytes reclaimed.
    @discardableResult
    static func purgeUnused(now: Date = Date()) -> Int64 {
        let cutoff = now.addingTimeInterval(
            -Double(Config.maximumUnusedDays) * 24 * 60 * 60
        )
        return purge(before: cutoff)
    }

    /// Remove every extracted file last used before a date.
    ///
    /// - Parameter cutoff: Files untouched since this are deleted.
    /// - Returns: Number of bytes reclaimed.
    @discardableResult
    static func purge(before cutoff: Date) -> Int64 {
        let keys: [URLResourceKey] = [
            .contentAccessDateKey, .contentModificationDateKey, .fileSizeKey
        ]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var reclaimed: Int64 = 0
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: Set(keys))
            let lastUsed = values?.contentAccessDate
                ?? values?.contentModificationDate
                ?? .distantPast
            guard lastUsed < cutoff else { continue }

            let size = Int64(values?.fileSize ?? 0)
            if (try? FileManager.default.removeItem(at: entry)) != nil {
                reclaimed += size
            }
        }
        return reclaimed
    }

    /// Delete extracted audio left by builds that wrote it loose in the
    /// temporary directory.
    ///
    /// Those files can never be reused - the names encoded a per-process hash or
    /// a UUID, so nothing will ever look for them again - and the ordinary sweep
    /// cannot see them because it only reads this type's own directory. Without
    /// this, upgrading carries every gigabyte already accumulated forever.
    ///
    /// Matched narrowly, and only in the app's own temporary directory, which in
    /// a sandboxed build is inside its container.
    ///
    /// - Returns: Number of bytes reclaimed.
    @discardableResult
    static func purgeLegacyFiles() -> Int64 {
        let root = FileManager.default.temporaryDirectory
        let keys: [URLResourceKey] = [.fileSizeKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return 0 }

        var reclaimed: Int64 = 0
        for entry in entries where isLegacyName(entry.lastPathComponent) {
            let size = Int64((try? entry.resourceValues(forKeys: Set(keys)))?.fileSize ?? 0)
            if (try? FileManager.default.removeItem(at: entry)) != nil {
                reclaimed += size
            }
        }
        return reclaimed
    }

    /// Whether a filename is one the older naming schemes produced.
    ///
    /// Deliberately specific: an extracted audio track was
    /// `projector-audio-<hash>.mov`, and a split channel was
    /// `<name>-left-<hex>.caf` or `-right-`, where the hex was the first eight
    /// characters of a UUID. Anything else is left alone.
    ///
    /// The trailing token's length is what separates a legacy split file from a
    /// current one, which shares the `-left-` shape and differs only in carrying
    /// a longer digest. Location already keeps them apart - current files live
    /// in this type's own directory and the legacy sweep only reads the
    /// temporary root - but a name that identifies live data as disposable is
    /// one refactor away from deleting it.
    static func isLegacyName(_ name: String) -> Bool {
        if name.hasPrefix("projector-audio-") && name.hasSuffix(".mov") { return true }
        guard name.hasSuffix(".caf") else { return false }

        let stem = name.dropLast(4)
        guard let separator = stem.range(of: "-", options: .backwards) else { return false }

        let token = stem[separator.upperBound...]
        guard token.count == legacyUniqueLength,
              token.allSatisfy(\.isHexDigit) else { return false }

        let side = stem[..<separator.lowerBound]
        return side.hasSuffix("-left") || side.hasSuffix("-right")
    }

    /// Characters of UUID the old split naming appended.
    private static let legacyUniqueLength = 8

    // MARK: - Helpers

    /// Whether a URL is one this type is responsible for.
    ///
    /// Guards every delete, so a wrong argument cannot reach a user's media.
    static func isManaged(_ url: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL
    }

    private static func createDirectoryIfNeeded() {
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    /// A digest that is the same on every launch.
    ///
    /// `String.hashValue` is not: Swift seeds it per process, so it names the
    /// same file differently every time the app starts, which is how one reel
    /// came to have a copy of its audio on disk for every session it was
    /// opened in.
    private static func stableDigest(of key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.map { String(format: "%02x", $0) }
            .joined()
            .prefix(Config.digestLength)
            .lowercased()
    }
}
