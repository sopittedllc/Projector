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

    /// Get the best thumbnail for a given source time (finds nearest match)
    func thumbnail(at sourceTime: Double) -> Data? {
        guard !thumbnails.isEmpty else { return nil }

        // Find the thumbnail with the closest time
        var best = thumbnails[0]
        var bestDiff = abs(best.sourceTime - sourceTime)

        for thumb in thumbnails {
            let diff = abs(thumb.sourceTime - sourceTime)
            if diff < bestDiff {
                best = thumb
                bestDiff = diff
            }
        }

        return best.imageData
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
