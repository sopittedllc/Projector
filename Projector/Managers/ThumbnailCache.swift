import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class ThumbnailCache: ObservableObject {
    @Published private(set) var atlases: [UUID: ThumbnailAtlas] = [:]

    private var generationTasks: [ThumbnailRequestKey: Task<Void, Never>] = [:]
    private let bucketCounts: [Int] = [24, 48, 96, 192, 384, 768]
    private let maxThumbnails = 800
    private let thumbnailSize = CGSize(width: 96, height: 54)
    private let jpegCompression: CGFloat = 0.7

    func thumbnail(for reel: VideoReel, at sourceTime: Double, targetCount: Int) -> Data? {
        guard let strip = strip(for: reel, targetCount: targetCount) else { return nil }
        return strip.thumbnail(at: sourceTime)
    }

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

    func prewarm(for reel: VideoReel) {
        _ = strip(for: reel, targetCount: bucketCounts.first ?? 48)
    }

    func remove(reelId: UUID) {
        atlases.removeValue(forKey: reelId)

        for (key, task) in generationTasks where key.reelId == reelId {
            task.cancel()
            generationTasks.removeValue(forKey: key)
        }
    }

    private func bucketCount(for targetCount: Int) -> Int {
        let clampedTarget = max(1, targetCount)
        let cappedTarget = min(clampedTarget, maxThumbnails)
        if cappedTarget > (bucketCounts.max() ?? 0) {
            return cappedTarget
        }
        return bucketCounts.min(by: { abs($0 - cappedTarget) < abs($1 - cappedTarget) }) ?? cappedTarget
    }

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

private struct ThumbnailRequestKey: Hashable {
    let reelId: UUID
    let bucketCount: Int
}
