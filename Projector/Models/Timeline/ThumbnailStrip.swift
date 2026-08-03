import Foundation
import AppKit

/// Thread-safe collector for building ThumbnailStrip from async callbacks
final class ThumbnailCollector: @unchecked Sendable {
    private var thumbnails: [(time: Double, data: Data)] = []
    private let lock = NSLock()
    private let sourceDuration: Double
    private let interval: Double

    init(sourceDuration: Double, interval: Double) {
        self.sourceDuration = sourceDuration
        self.interval = interval
    }

    func add(time: Double, data: Data) {
        lock.lock()
        thumbnails.append((time: time, data: data))
        lock.unlock()
    }

    func buildStrip() -> ThumbnailStrip {
        lock.lock()
        let sorted = thumbnails.sorted { $0.time < $1.time }
        lock.unlock()

        var strip = ThumbnailStrip(sourceDuration: sourceDuration, interval: interval)
        for thumb in sorted {
            strip.addThumbnail(at: thumb.time, imageData: thumb.data)
        }
        return strip
    }
}

/// Holds multiple thumbnails for a video reel, indexed by source time
struct ThumbnailStrip {
    /// Individual thumbnail with its source time position
    struct Thumbnail {
        let sourceTime: Double  // Time in seconds from source start
        let imageData: Data
    }

    /// Thumbnails sorted by source time
    private(set) var thumbnails: [Thumbnail] = []

    /// Duration of the source video in seconds
    let sourceDuration: Double

    /// Interval between thumbnails in seconds
    let interval: Double

    init(sourceDuration: Double, interval: Double = 5.0) {
        self.sourceDuration = sourceDuration
        self.interval = interval
    }

    /// Add a thumbnail at a specific source time
    mutating func addThumbnail(at sourceTime: Double, imageData: Data) {
        let thumbnail = Thumbnail(sourceTime: sourceTime, imageData: imageData)
        thumbnails.append(thumbnail)
        thumbnails.sort { $0.sourceTime < $1.sourceTime }
    }

    /// Index of the thumbnail nearest a source time.
    ///
    /// Binary search rather than a scan. The filmstrip asks once per cell it
    /// draws, so a linear pass made the cost of a frame quadratic in the strip:
    /// at 800 thumbnails and a few hundred visible cells that was hundreds of
    /// thousands of comparisons per layout pass, before a single pixel was
    /// drawn.
    ///
    /// - Parameter sourceTime: Time in seconds from the source start.
    /// - Returns: Index into ``thumbnails``, or `nil` when the strip is empty.
    func index(at sourceTime: Double) -> Int? {
        guard !thumbnails.isEmpty else { return nil }

        var low = 0
        var high = thumbnails.count - 1
        while low < high {
            let mid = (low + high) / 2
            if thumbnails[mid].sourceTime < sourceTime {
                low = mid + 1
            } else {
                high = mid
            }
        }

        // `low` is the first entry at or after the time; its predecessor may
        // still be the nearer of the two.
        if low > 0 {
            let after = abs(thumbnails[low].sourceTime - sourceTime)
            let before = abs(thumbnails[low - 1].sourceTime - sourceTime)
            if before <= after { return low - 1 }
        }
        return low
    }

    /// Get the best thumbnail for a given source time (finds nearest match)
    func thumbnail(at sourceTime: Double) -> Data? {
        guard let index = index(at: sourceTime) else { return nil }
        return thumbnails[index].imageData
    }

    /// Get thumbnail by index (for sequential access)
    func thumbnail(atIndex index: Int) -> Data? {
        guard index >= 0, index < thumbnails.count else {
            return thumbnails.last?.imageData
        }
        return thumbnails[index].imageData
    }

    /// Number of thumbnails available
    var count: Int {
        thumbnails.count
    }

    /// First thumbnail (for fallback/preview)
    var first: Data? {
        thumbnails.first?.imageData
    }
}

/// Multi-resolution thumbnail collection keyed by bucket count.
struct ThumbnailAtlas: Sendable {
    let duration: Double
    private(set) var levels: [Int: ThumbnailStrip] = [:]

    init(duration: Double, levels: [Int: ThumbnailStrip] = [:]) {
        self.duration = duration
        self.levels = levels
    }

    mutating func addLevel(_ strip: ThumbnailStrip, bucketCount: Int) {
        levels[bucketCount] = strip
    }

    func level(for bucketCount: Int) -> ThumbnailStrip? {
        levels[bucketCount]
    }

    func bestLevel(for targetCount: Int) -> ThumbnailStrip? {
        guard !levels.isEmpty else { return nil }
        let clampedTarget = max(1, targetCount)
        let best = levels.min { abs($0.key - clampedTarget) < abs($1.key - clampedTarget) }
        return best?.value
    }

    func thumbnail(at sourceTime: Double, targetCount: Int) -> Data? {
        bestLevel(for: targetCount)?.thumbnail(at: sourceTime)
    }
}
