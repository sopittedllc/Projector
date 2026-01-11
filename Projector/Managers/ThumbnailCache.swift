import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - ThumbnailCache

/// A multi-resolution thumbnail cache for video reels with lazy generation.
///
/// `ThumbnailCache` manages thumbnail atlases for video reels, generating thumbnails
/// on-demand at various resolution levels (bucket counts). The cache supports:
/// - **Multi-resolution levels**: 24, 48, 96, 192, 384, 768 thumbnails per reel
/// - **Lazy generation**: Thumbnails are generated asynchronously on first access
/// - **Best-fit fallback**: Returns the closest available resolution if exact match unavailable
/// - **Prewarm support**: Pre-generate thumbnails before they're needed
///
/// ## Architecture
///
/// ```
/// ┌─────────────────────────────────────────────────────────────────┐
/// │                     ThumbnailCache                               │
/// │  ┌─────────────────────────────────────────────────────────────┐│
/// │  │ atlases: [UUID: ThumbnailAtlas]                             ││
/// │  │   └── ThumbnailAtlas                                        ││
/// │  │         ├── level[24]: ThumbnailStrip (24 thumbnails)       ││
/// │  │         ├── level[48]: ThumbnailStrip (48 thumbnails)       ││
/// │  │         └── level[96]: ThumbnailStrip (96 thumbnails)       ││
/// │  └─────────────────────────────────────────────────────────────┘│
/// │  ┌─────────────────────────────────────────────────────────────┐│
/// │  │ generationTasks: [ThumbnailRequestKey: Task]                ││
/// │  │   └── Tracks in-flight generation to prevent duplicates    ││
/// │  └─────────────────────────────────────────────────────────────┘│
/// └─────────────────────────────────────────────────────────────────┘
/// ```
///
/// ## Thread Safety
///
/// - The cache is `@MainActor` isolated for safe UI observation
/// - Thumbnail generation runs on background threads via `Task`
/// - `generateStrip` is `nonisolated static` for concurrent execution
///
/// ## Usage
///
/// ```swift
/// @StateObject var thumbnailCache = ThumbnailCache()
///
/// // Get a thumbnail for a specific time
/// if let data = thumbnailCache.thumbnail(for: reel, at: 30.5, targetCount: 100) {
///     Image(nsImage: NSImage(data: data)!)
/// }
///
/// // Prewarm when reel is added
/// thumbnailCache.prewarm(for: reel)
///
/// // Clean up when reel is removed
/// thumbnailCache.remove(reelId: reel.id)
/// ```
@MainActor
final class ThumbnailCache: ObservableObject {

    // MARK: - Published Properties

    /// Thumbnail atlases keyed by video reel ID.
    ///
    /// Each atlas contains multiple resolution levels (ThumbnailStrips) for a single reel.
    /// Published to allow SwiftUI views to observe changes and re-render when new
    /// thumbnails become available.
    @Published private(set) var atlases: [UUID: ThumbnailAtlas] = [:]

    // MARK: - Private Properties

    /// In-flight generation tasks keyed by reel ID and bucket count.
    ///
    /// Prevents duplicate generation requests for the same resolution level.
    /// Tasks are removed upon completion or cancellation.
    private var generationTasks: [ThumbnailRequestKey: Task<Void, Never>] = [:]

    /// Predefined bucket counts for thumbnail resolution levels.
    ///
    /// These values represent the number of thumbnails generated for a reel.
    /// The cache snaps requests to the nearest bucket for efficient caching.
    private let bucketCounts: [Int] = [24, 48, 96, 192, 384, 768]

    /// Maximum number of thumbnails allowed per resolution level.
    ///
    /// Caps bucket counts to prevent excessive memory usage for very long videos.
    private let maxThumbnails = 800

    /// Target size for generated thumbnails (96×54 pixels, 16:9 aspect ratio).
    private let thumbnailSize = CGSize(width: 96, height: 54)

    /// JPEG compression quality for thumbnail storage (0.7 = 70%).
    ///
    /// Balances image quality against memory usage.
    private let jpegCompression: CGFloat = 0.7

    // MARK: - Public Methods

    /// Returns a thumbnail for a video reel at a specific source time.
    ///
    /// This is the primary method for retrieving thumbnails. It automatically:
    /// 1. Finds or creates a `ThumbnailStrip` at the appropriate resolution
    /// 2. Looks up the nearest thumbnail to the requested time
    /// 3. Triggers background generation if the strip doesn't exist
    ///
    /// - Parameters:
    ///   - reel: The video reel to get a thumbnail for
    ///   - sourceTime: Time in seconds from the start of the source video
    ///   - targetCount: Desired number of thumbnails (snapped to nearest bucket)
    /// - Returns: JPEG image data if available, `nil` if still generating
    ///
    /// ## Example
    /// ```swift
    /// // Get thumbnail for 30 seconds into a video at ~100 thumbnails resolution
    /// if let jpegData = cache.thumbnail(for: reel, at: 30.0, targetCount: 100) {
    ///     let image = NSImage(data: jpegData)
    /// }
    /// ```
    func thumbnail(for reel: VideoReel, at sourceTime: Double, targetCount: Int) -> Data? {
        guard let strip = strip(for: reel, targetCount: targetCount) else { return nil }
        return strip.thumbnail(at: sourceTime)
    }

    /// Returns a thumbnail strip for a video reel, triggering generation if needed.
    ///
    /// The method follows this resolution strategy:
    /// 1. If an exact bucket match exists, return it
    /// 2. Otherwise, start async generation for the requested bucket
    /// 3. Return the best available fallback (closest resolution) or `nil`
    ///
    /// - Parameters:
    ///   - reel: The video reel to get thumbnails for
    ///   - targetCount: Desired number of thumbnails (snapped to nearest bucket)
    /// - Returns: The best available `ThumbnailStrip`, or `nil` if none ready
    ///
    /// - Note: This method triggers background generation as a side effect.
    ///         Subsequent calls will return the generated strip once complete.
    func strip(for reel: VideoReel, targetCount: Int) -> ThumbnailStrip? {
        let bucketCount = bucketCount(for: targetCount)
        if let atlas = atlases[reel.id], let level = atlas.level(for: bucketCount) {
            return level
        }

        startGeneration(for: reel, bucketCount: bucketCount)

        if let atlas = atlases[reel.id] {
            return atlas.bestLevel(for: targetCount)
        }

        return nil
    }

    /// Pre-generates thumbnails for a reel at the lowest resolution level.
    ///
    /// Call this when a reel is added to the timeline to ensure thumbnails
    /// are available before the user zooms in. The lowest resolution (24 thumbnails)
    /// generates quickly and provides immediate visual feedback.
    ///
    /// - Parameter reel: The video reel to prewarm thumbnails for
    ///
    /// ## Example
    /// ```swift
    /// // When adding a new reel to the timeline
    /// timeline.addReel(reel)
    /// thumbnailCache.prewarm(for: reel)
    /// ```
    func prewarm(for reel: VideoReel) {
        _ = strip(for: reel, targetCount: bucketCounts.first ?? 48)
    }

    /// Removes all thumbnails and cancels pending generation for a reel.
    ///
    /// Call this when a reel is removed from the timeline to free memory.
    /// Any in-flight generation tasks are cancelled immediately.
    ///
    /// - Parameter reelId: The UUID of the video reel to remove
    ///
    /// ## Example
    /// ```swift
    /// // When removing a reel from the timeline
    /// timeline.removeReel(reelId: reel.id)
    /// thumbnailCache.remove(reelId: reel.id)
    /// ```
    func remove(reelId: UUID) {
        atlases.removeValue(forKey: reelId)

        for (key, task) in generationTasks where key.reelId == reelId {
            task.cancel()
            generationTasks.removeValue(forKey: key)
        }
    }

    // MARK: - Private Methods

    /// Maps a target count to the nearest predefined bucket count.
    ///
    /// The bucket algorithm:
    /// 1. Clamps the target to at least 1
    /// 2. Caps at `maxThumbnails` (800)
    /// 3. If above the largest predefined bucket, uses the exact count
    /// 4. Otherwise, snaps to the nearest predefined bucket
    ///
    /// - Parameter targetCount: The desired number of thumbnails
    /// - Returns: The bucket count to use for caching
    ///
    /// - Complexity: O(n) where n is the number of bucket counts (6)
    private func bucketCount(for targetCount: Int) -> Int {
        let clampedTarget = max(1, targetCount)
        let cappedTarget = min(clampedTarget, maxThumbnails)
        if cappedTarget > (bucketCounts.max() ?? 0) {
            return cappedTarget
        }
        return bucketCounts.min(by: { abs($0 - cappedTarget) < abs($1 - cappedTarget) }) ?? cappedTarget
    }

    /// Starts asynchronous thumbnail generation for a reel at a specific bucket count.
    ///
    /// This method is idempotent - if generation is already in progress for the
    /// given reel/bucket combination, no new task is started.
    ///
    /// The generation flow:
    /// 1. Create a unique key for this reel/bucket combination
    /// 2. Check if generation is already in progress (early return if so)
    /// 3. Spawn a background task to generate thumbnails
    /// 4. On completion, update the atlas and remove the task
    ///
    /// - Parameters:
    ///   - reel: The video reel to generate thumbnails for
    ///   - bucketCount: Number of thumbnails to generate
    ///
    /// - Note: Errors are logged but not propagated; the cache simply remains empty.
    private func startGeneration(for reel: VideoReel, bucketCount: Int) {
        let key = ThumbnailRequestKey(reelId: reel.id, bucketCount: bucketCount)
        guard generationTasks[key] == nil else { return }

        let task = Task {
            do {
                let strip = try await Self.generateStrip(
                    for: reel,
                    bucketCount: bucketCount,
                    maxThumbnails: maxThumbnails,
                    thumbnailSize: thumbnailSize,
                    jpegCompression: jpegCompression
                )

                await MainActor.run { () -> Void in
                    var atlas = self.atlases[reel.id] ?? ThumbnailAtlas(duration: strip.sourceDuration)
                    atlas.addLevel(strip, bucketCount: bucketCount)
                    self.atlases[reel.id] = atlas
                    self.generationTasks.removeValue(forKey: key)
                }
            } catch {
                debugPrint("ThumbnailCache: Failed to generate thumbnails for \(reel.id): \(error)")
                await MainActor.run { () -> Void in
                    self.generationTasks.removeValue(forKey: key)
                }
            }
        }

        generationTasks[key] = task
    }

    // MARK: - Static Generation Methods

    /// Generates a thumbnail strip for a video reel using AVFoundation.
    ///
    /// This method is `nonisolated static` to allow concurrent generation across
    /// multiple reels without blocking the main actor.
    ///
    /// The generation process:
    /// 1. Load the video asset and its duration
    /// 2. Calculate evenly-spaced sample times
    /// 3. Configure an `AVAssetImageGenerator` with appropriate tolerance
    /// 4. Generate all thumbnails asynchronously via callback
    /// 5. Collect results into a `ThumbnailStrip`
    ///
    /// - Parameters:
    ///   - reel: The video reel to generate thumbnails for
    ///   - bucketCount: Number of thumbnails to generate
    ///   - maxThumbnails: Maximum cap for bucket count
    ///   - thumbnailSize: Target size for each thumbnail
    ///   - jpegCompression: JPEG quality (0.0 to 1.0)
    /// - Returns: A populated `ThumbnailStrip` with JPEG data
    /// - Throws: If the video asset cannot be loaded
    ///
    /// - Note: Security-scoped URL access must be managed by the caller
    ///         (handled by `TimelineManager.addVideoReel`).
    private nonisolated static func generateStrip(
        for reel: VideoReel,
        bucketCount: Int,
        maxThumbnails: Int,
        thumbnailSize: CGSize,
        jpegCompression: CGFloat
    ) async throws -> ThumbnailStrip {
        // Use source URL directly - security access is managed by TimelineManager.addVideoReel
        // and stays active until the reel is removed from the timeline
        let asset = AVAsset(url: reel.sourceURL)
        let duration = try await asset.load(.duration)
        let durationSeconds = duration.seconds
        guard durationSeconds > 0 else {
            return ThumbnailStrip(sourceDuration: 0, interval: 0)
        }

        let safeBucketCount = max(1, min(bucketCount, maxThumbnails))
        let interval = durationSeconds / Double(safeBucketCount)
        let timeScale: CMTimeScale = 600
        let maxTime = max(0, durationSeconds - 0.001)

        var times: [NSValue] = []
        times.reserveCapacity(safeBucketCount)
        for index in 0..<safeBucketCount {
            let time = min(maxTime, Double(index) * interval)
            times.append(NSValue(time: CMTime(seconds: time, preferredTimescale: timeScale)))
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = thumbnailSize
        let toleranceSeconds = max(0.0, interval / 2)
        let tolerance = CMTime(seconds: toleranceSeconds, preferredTimescale: timeScale)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let collector = ThumbnailCollector(sourceDuration: durationSeconds, interval: interval)

        let timesCount = times.count
        let _: Void = await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var completedCount = 0
            let lock = NSLock()

            generator.generateCGImagesAsynchronously(forTimes: times) { requestedTime, cgImage, _, _, _ in
                if let cgImage = cgImage,
                   let data = jpegData(from: cgImage, compression: jpegCompression) {
                    collector.add(time: requestedTime.seconds, data: data)
                }

                lock.lock()
                completedCount += 1
                let done = completedCount >= timesCount
                lock.unlock()

                if done {
                    continuation.resume()
                }
            }
        }

        return collector.buildStrip()
    }

    /// Compresses a CGImage to JPEG data using ImageIO.
    ///
    /// Uses `CGImageDestination` for efficient JPEG encoding with configurable quality.
    ///
    /// - Parameters:
    ///   - cgImage: The source image to compress
    ///   - compression: JPEG quality (0.0 = maximum compression, 1.0 = lossless)
    /// - Returns: JPEG data, or `nil` if compression fails
    private nonisolated static func jpegData(from cgImage: CGImage, compression: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        let properties: CFDictionary = [kCGImageDestinationLossyCompressionQuality: compression] as CFDictionary
        CGImageDestinationAddImage(destination, cgImage, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

// MARK: - ThumbnailRequestKey

/// A hashable key for tracking in-flight thumbnail generation tasks.
///
/// Combines reel ID and bucket count to create a unique identifier for
/// each generation request, preventing duplicate concurrent generations.
private struct ThumbnailRequestKey: Hashable {
    /// The video reel being generated.
    let reelId: UUID

    /// The target number of thumbnails.
    let bucketCount: Int
}
