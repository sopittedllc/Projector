import Foundation
import CryptoKit

// MARK: - WaveformDiskStore

/// Keeps generated waveform atlases on disk so a source file is analysed once.
///
/// `WaveformCache` holds atlases in memory for the life of the app. Without
/// this store every project open, and every relaunch, decoded every audio
/// clip again - minutes of reading for a feature's worth of stems, producing
/// the same numbers each time. Now the first analysis is written here and the
/// next one is a file read.
///
/// ## Where
///
/// The app's Caches directory (inside the sandbox container), not the project
/// package: the same stem used in three projects is analysed once, an unsaved
/// project benefits too, and the project file stays small and portable. macOS
/// may purge Caches when space is short; a purged atlas is simply generated
/// again on demand.
///
/// ## Keying
///
/// An atlas is a pure function of the audio it came from and the analysis
/// settings, so the key hashes the source's filesystem identity, creation date,
/// size and modification date, plus the track and split channel read from it.
/// The sample density, resolution ladder, and ``formatVersion`` are included.
/// Moves on the same volume preserve identity; copies generate a new atlas. Two clips
/// cut from the same file share one atlas. Editing the file changes its size or
/// date and so its key; the stale file is never matched again.
///
/// ## Format
///
/// A binary property list of ``StoredAtlas`` - the float arrays travel as raw
/// `Data`, which bplist stores as bytes - compressed with LZFSE. Anything that
/// fails to decode is treated as a miss, never an error: this is a cache.
///
/// Stateless: every function is a plain file operation with an atomic write,
/// so concurrent generation tasks need no coordination.
enum WaveformDiskStore {

    // MARK: - Constants

    /// Bumped whenever the atlas contents or encoding change. Old files are
    /// then never matched again and age out with the rest of Caches.
    static let formatVersion = 2

    /// Folder inside the app's Caches directory.
    static let directoryName = "Waveforms"

    /// Extension of one stored atlas.
    static let fileExtension = "waveform"

    /// Default location: `<container>/Library/Caches/Waveforms`.
    ///
    /// `nil` only if the Caches directory cannot be found, in which case the
    /// cache is silently off and generation behaves as it did before.
    static var defaultDirectory: URL? {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    // MARK: - Key

    /// Identity of the audio an atlas is derived from, as a filename-safe hash.
    ///
    /// Must be called while the caller holds read access to `sourceURL`: the
    /// file is stat'ed for its size and modification date.
    ///
    /// - Parameters:
    ///   - sourceURL: The original media file (never a temporary extraction -
    ///     those are re-made with new dates and would never hit).
    ///   - trackIndex: Audio track read from the file.
    ///   - channel: Split channel isolated from a stereo track, if any.
    ///   - samplesPerSecond: Analysis density the atlas was built at.
    ///   - bucketCounts: Resolution ladder the atlas holds.
    /// - Returns: A hex digest, or nil if the file cannot be stat'ed - the
    ///   caller then generates without caching.
    static func key(
        sourceURL: URL,
        trackIndex: Int,
        channel: SplitChannel?,
        samplesPerSecond: Int,
        bucketCounts: [Int]
    ) -> String? {
        // Not `URL.resourceValues`: NSURL caches those per instance, so a file
        // rewritten under the same URL would keep its old key.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: sourceURL.path),
              let size = attributes[.size] as? UInt64,
              let modified = attributes[.modificationDate] as? Date,
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else {
            return nil
        }
        // Optional: not every volume reports a birth time (NFS, some shares),
        // and media living there must still be cacheable.
        let created = (attributes[.creationDate] as? Date)?.timeIntervalSince1970
        let identity = [
            "v\(formatVersion)",
            "device\(device)",
            "inode\(inode)",
            "created\(created.map { "\($0)" } ?? "none")",
            "\(size)",
            "\(modified.timeIntervalSince1970)",
            "t\(trackIndex)",
            channel?.rawValue ?? "sum",
            "sps\(samplesPerSecond)",
            bucketCounts.map(String.init).joined(separator: ",")
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(identity.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Load / Store

    /// Reads a stored atlas.
    ///
    /// - Parameters:
    ///   - key: From ``key(sourceURL:trackIndex:channel:samplesPerSecond:bucketCounts:)``.
    ///   - directory: Where to look; the default is the app's Caches folder.
    /// - Returns: The atlas, or nil for a miss or an unreadable file.
    static func load(key: String, in directory: URL? = defaultDirectory) -> WaveformAtlas? {
        guard let directory else { return nil }
        let url = fileURL(for: key, in: directory)
        guard let compressed = try? Data(contentsOf: url),
              let data = try? (compressed as NSData).decompressed(using: .lzfse) as Data,
              let stored = try? PropertyListDecoder().decode(StoredAtlas.self, from: data),
              stored.version == formatVersion else {
            return nil
        }
        return stored.atlas
    }

    /// Writes an atlas, replacing any file already under that key.
    ///
    /// Failures are logged and otherwise ignored - a cache that cannot be
    /// written costs another analysis next time, nothing more.
    ///
    /// - Parameters:
    ///   - atlas: The freshly generated atlas.
    ///   - key: From ``key(sourceURL:trackIndex:channel:samplesPerSecond:bucketCounts:)``.
    ///   - directory: Where to write; the default is the app's Caches folder.
    static func store(_ atlas: WaveformAtlas, key: String, in directory: URL? = defaultDirectory) {
        guard let directory else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let data = try encoder.encode(StoredAtlas(atlas))
            let compressed = try (data as NSData).compressed(using: .lzfse) as Data
            try compressed.write(to: fileURL(for: key, in: directory), options: .atomic)
        } catch {
            diagnosticLog(.warning, .media, "Waveform cache write failed: \(error.localizedDescription)")
        }
    }

    /// The file one key lives in.
    static func fileURL(for key: String, in directory: URL) -> URL {
        directory.appendingPathComponent(key).appendingPathExtension(fileExtension)
    }

    // MARK: - Stored Form

    /// Serialisable shape of ``WaveformAtlas``.
    ///
    /// The level dictionaries become arrays carrying their bucket count, and
    /// each float array becomes its raw bytes. `rmsFloor`/`rmsPeak` are stored
    /// rather than recomputed so a loaded level draws identically to the one
    /// that was generated.
    struct StoredAtlas: Codable {
        var version: Int
        var duration: Double
        var levels: [StoredLevel]
        var channelLevels: [[StoredLevel]]

        init(_ atlas: WaveformAtlas) {
            version = WaveformDiskStore.formatVersion
            duration = atlas.duration
            levels = atlas.levels.map { StoredLevel(bucketCount: $0.key, level: $0.value) }
            channelLevels = atlas.channelLevels.map { channel in
                channel.map { StoredLevel(bucketCount: $0.key, level: $0.value) }
            }
        }

        /// Rebuilds the atlas, or nil if any level is internally inconsistent.
        var atlas: WaveformAtlas? {
            guard let summed = Self.dictionary(from: levels) else { return nil }
            var channels: [[Int: WaveformLevel]] = []
            for channel in channelLevels {
                guard let rebuilt = Self.dictionary(from: channel) else { return nil }
                channels.append(rebuilt)
            }
            return WaveformAtlas(duration: duration, levels: summed, channelLevels: channels)
        }

        private static func dictionary(from stored: [StoredLevel]) -> [Int: WaveformLevel]? {
            var result: [Int: WaveformLevel] = [:]
            for entry in stored {
                guard let level = entry.level else { return nil }
                result[entry.bucketCount] = level
            }
            return result
        }
    }

    /// One resolution of a stored atlas.
    struct StoredLevel: Codable {
        var bucketCount: Int
        var min: Data
        var max: Data
        var rms: Data
        var rmsFloor: Float
        var rmsPeak: Float

        init(bucketCount: Int, level: WaveformLevel) {
            self.bucketCount = bucketCount
            min = Self.bytes(level.min)
            max = Self.bytes(level.max)
            rms = Self.bytes(level.rms)
            rmsFloor = level.rmsFloor
            rmsPeak = level.rmsPeak
        }

        /// The level, or nil if the three arrays disagree on length.
        var level: WaveformLevel? {
            let minValues = Self.floats(min)
            let maxValues = Self.floats(max)
            let rmsValues = Self.floats(rms)
            guard minValues.count == maxValues.count, minValues.count == rmsValues.count else {
                return nil
            }
            return WaveformLevel(
                min: minValues, max: maxValues, rms: rmsValues,
                rmsFloor: rmsFloor, rmsPeak: rmsPeak
            )
        }

        private static func bytes(_ values: [Float]) -> Data {
            values.withUnsafeBufferPointer { Data(buffer: $0) }
        }

        /// Copies rather than rebinding: `Data` makes no alignment promise.
        private static func floats(_ data: Data) -> [Float] {
            let count = data.count / MemoryLayout<Float>.stride
            return [Float](unsafeUninitializedCapacity: count) { buffer, initialized in
                let copied = data.copyBytes(to: buffer)
                initialized = copied / MemoryLayout<Float>.stride
            }
        }
    }
}
