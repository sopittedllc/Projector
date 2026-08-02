//
//  TemporaryAudioFiles.swift
//  Projector
//
//  Clears extracted audio left behind by earlier versions.
//

import Foundation

/// Removes the audio files earlier versions of the app extracted to disk.
///
/// Importing a video used to copy its audio track out so the timeline had
/// something to play and draw, and splitting a hard-panned reel wrote a further
/// file per side. Nothing does either now - audio is read straight from the
/// media, and a split lane takes its half in the mixer - so no new files are
/// written and this exists only to clear what previous versions left.
///
/// ## Why there is anything to clear
///
/// Neither of the old names could ever be reused:
///
/// - the extracted audio track was keyed on `String.hashValue`, which Swift
///   seeds per process, so the same reel got a different filename on every
///   launch
/// - split channels appended a fresh UUID, so re-splitting a reel wrote another
///   pair rather than finding the one already there
///
/// Nothing deleted either, and a feature-length reel costs a few hundred
/// megabytes per file. A few sessions of work left tens of gigabytes that no
/// project referenced and nothing would ever read again.
///
/// This can be deleted once no installation is likely to be carrying them.
enum TemporaryAudioFiles {

    /// Delete extracted audio left by earlier versions.
    ///
    /// Matched narrowly, and only in the app's own temporary directory, which in
    /// a sandboxed build is inside its container. Deleting one is safe even if a
    /// saved project still names it: a clip whose extracted audio is missing
    /// reads its original source instead, which is now the only thing any clip
    /// does.
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

        // The directory a later version wrote into before extraction was
        // removed altogether. Empty by now, but it should not be left behind.
        let managed = root.appendingPathComponent("ExtractedAudio", isDirectory: true)
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: managed,
            includingPropertiesForKeys: keys
        ) {
            for entry in contents {
                let size = Int64((try? entry.resourceValues(forKeys: Set(keys)))?.fileSize ?? 0)
                if (try? FileManager.default.removeItem(at: entry)) != nil {
                    reclaimed += size
                }
            }
            try? FileManager.default.removeItem(at: managed)
        }

        return reclaimed
    }

    /// Whether a filename is one the older naming schemes produced.
    ///
    /// Deliberately specific: an extracted audio track was
    /// `projector-audio-<hash>.mov`, and a split channel was
    /// `<name>-left-<hex>.caf` or `-right-`, where the hex was the first eight
    /// characters of a UUID. A user's own media does not match either, which is
    /// what makes deleting on a name safe.
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
}
