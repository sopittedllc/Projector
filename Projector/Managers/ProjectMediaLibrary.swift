import Foundation
import AVFoundation
import Combine
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Manages the project's media library - importing, organizing, and providing filtered views
@MainActor
final class ProjectMediaLibrary: ObservableObject {
    // MARK: - Published Properties

    /// All media items in the library
    @Published private(set) var items: [MediaItem] = []

    /// Whether there are unsaved changes
    @Published private(set) var hasChanges: Bool = false

    /// Currently importing items (for progress display)
    @Published private(set) var importingCount: Int = 0

    // MARK: - Computed Properties

    /// Video items only
    var videoItems: [MediaItem] {
        items.filter { $0.type == .video }
    }

    /// Audio items only
    var audioItems: [MediaItem] {
        items.filter { $0.type == .audio }
    }

    /// Items sorted by import date (most recent first)
    var recentItems: [MediaItem] {
        items.sorted { $0.importedAt > $1.importedAt }
    }

    // MARK: - Callbacks

    var onLibraryChanged: (() -> Void)?

    // MARK: - Initialization

    init(items: [MediaItem] = []) {
        self.items = items
    }

    // MARK: - Change Tracking

    private func markDirty() {
        hasChanges = true
        onLibraryChanged?()
    }

    func markClean() {
        hasChanges = false
    }

    // MARK: - Import Operations

    /// Supported video file extensions
    static let videoExtensions = ["mov", "mp4", "m4v", "avi", "mkv", "mxf", "mpg", "mpeg"]

    /// Supported audio file extensions
    static let audioExtensions = ["wav", "aif", "aiff", "mp3", "m4a", "aac", "flac", "ogg"]

    /// All supported file extensions
    static var supportedExtensions: [String] {
        videoExtensions + audioExtensions
    }

    /// Check if a URL is a supported media file
    static func isSupported(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return supportedExtensions.contains(ext)
    }

    /// Determine media type from file extension
    static func mediaType(for url: URL) -> MediaType? {
        let ext = url.pathExtension.lowercased()
        if videoExtensions.contains(ext) { return .video }
        if audioExtensions.contains(ext) { return .audio }
        return nil
    }

    /// Import a media file into the library
    func importFile(from url: URL) async throws -> MediaItem {
        importingCount += 1
        defer { importingCount -= 1 }

        guard Self.isSupported(url: url) else {
            throw MediaLibraryError.unsupportedFormat
        }

        // Check if already imported
        if let existing = existingItem(for: url) {
            return existing
        }

        // Start security-scoped access before creating bookmark
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        // Create security-scoped bookmark (while access is active)
        let bookmark = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        // Determine media type
        guard let type = Self.mediaType(for: url) else {
            throw MediaLibraryError.unsupportedFormat
        }

        // Load asset metadata
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)

        var frameRate: Double?
        var videoSize: CGSize?
        var channelCount: Int?
        var sampleRate: Double?

        // Get video track info
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        if let videoTrack = videoTracks.first {
            let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
            frameRate = Double(nominalFrameRate)

            let naturalSize = try await videoTrack.load(.naturalSize)
            videoSize = naturalSize
        }

        // Get audio track info
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        if let audioTrack = audioTracks.first {
            let formatDescriptions = try await audioTrack.load(.formatDescriptions)
            if let formatDesc = formatDescriptions.first {
                let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
                if let format = asbd?.pointee {
                    channelCount = Int(format.mChannelsPerFrame)
                    sampleRate = format.mSampleRate
                }
            }
        }

        // Generate thumbnail for video
        var thumbnailData: Data?
        if type == .video {
            thumbnailData = await generateThumbnail(for: asset)
        }

        // Calculate bitrate from file size and duration
        var bitrate: Int?
        if duration.seconds > 0 {
            let fileAttributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            if let fileSize = fileAttributes?[.size] as? UInt64 {
                bitrate = Int((Double(fileSize) * 8) / duration.seconds)
            }
        }

        let item = MediaItem(
            url: url,
            bookmark: bookmark,
            type: type,
            duration: duration.seconds,
            frameRate: frameRate,
            videoSize: videoSize,
            channelCount: channelCount,
            sampleRate: sampleRate,
            bitrate: bitrate,
            thumbnailData: thumbnailData
        )

        items.append(item)
        markDirty()

        return item
    }

    /// Find an existing media item by URL (normalized)
    func existingItem(for url: URL) -> MediaItem? {
        let normalized = url.standardizedFileURL.resolvingSymlinksInPath()
        return items.first { item in
            item.url.standardizedFileURL.resolvingSymlinksInPath() == normalized
        }
    }

    /// Import multiple files
    func importFiles(from urls: [URL]) async -> [Result<MediaItem, Error>] {
        var results: [Result<MediaItem, Error>] = []

        for url in urls {
            do {
                let item = try await importFile(from: url)
                results.append(.success(item))
            } catch {
                results.append(.failure(error))
            }
        }

        return results
    }

    /// Remove a media item from the library
    func removeItem(id: UUID) {
        items.removeAll { $0.id == id }
        markDirty()
    }

    /// Remove multiple items
    func removeItems(ids: Set<UUID>) {
        items.removeAll { ids.contains($0.id) }
        markDirty()
    }

    /// Update the URL for an item (used when relocating missing files or after optimization)
    ///
    /// - Parameters:
    ///   - id: The media item ID
    ///   - newURL: The new file URL
    ///   - newBookmark: Optional pre-created bookmark (created if nil)
    func updateItemURL(id: UUID, newURL: URL, newBookmark: Data? = nil, isOptimized: Bool? = nil) {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            NSLog(">>> ProjectMediaLibrary.updateItemURL: item not found for id=\(id)")
            return
        }
        let item = items[index]
        let newIsOptimized = isOptimized ?? item.isOptimized
        NSLog(">>> ProjectMediaLibrary.updateItemURL: id=\(id), oldURL=\(item.url.lastPathComponent), newURL=\(newURL.lastPathComponent), oldIsOptimized=\(item.isOptimized), newIsOptimized=\(newIsOptimized)")

        let bookmark = newBookmark ?? (try? newURL.bookmarkData(options: .withSecurityScope))

        items[index] = MediaItem(
            id: item.id,
            url: newURL,
            bookmark: bookmark,
            type: item.type,
            duration: item.duration,
            frameRate: item.frameRate,
            videoSize: item.videoSize,
            channelCount: item.channelCount,
            sampleRate: item.sampleRate,
            bitrate: item.bitrate,
            importedAt: item.importedAt,
            isOptimized: newIsOptimized,
            thumbnailData: item.thumbnailData
        )
        NSLog(">>> ProjectMediaLibrary.updateItemURL: UPDATED - items[\(index)].isOptimized = \(items[index].isOptimized)")
        markDirty()
    }

    /// Get an item by ID
    func item(withId id: UUID) -> MediaItem? {
        items.first { $0.id == id }
    }

    /// Refresh file access for an item using its bookmark
    func refreshAccess(for itemId: UUID) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == itemId }),
              let bookmark = items[index].bookmark else {
            return false
        }

        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if url.startAccessingSecurityScopedResource() {
                return true
            }
        } catch {
            NSLog(">>> ProjectMediaLibrary: Failed to refresh access: \(error)")
        }

        return false
    }

    // MARK: - Thumbnail Generation

    /// Generate a thumbnail image for a video asset (returns PNG data)
    /// Uses CoreGraphics/ImageIO to avoid AppKit dependency in the Logic layer
    private func generateThumbnail(for asset: AVAsset) async -> Data? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 360)

        do {
            let time = CMTime(seconds: 1, preferredTimescale: 600)
            let cgImage = try await generator.image(at: time).image

            // Convert CGImage to PNG data using ImageIO
            let mutableData = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                mutableData as CFMutableData,
                UTType.png.identifier as CFString,
                1,
                nil
            ) else {
                return nil
            }

            CGImageDestinationAddImage(destination, cgImage, nil)
            guard CGImageDestinationFinalize(destination) else {
                return nil
            }

            return mutableData as Data
        } catch {
            return nil
        }
    }

    /// Get thumbnail data for an item (loads from cache or generates)
    /// Returns raw PNG data - the View layer converts to NSImage/Image
    func thumbnailData(for itemId: UUID) async -> Data? {
        guard let item = item(withId: itemId) else { return nil }

        // Return cached thumbnail
        if let data = item.thumbnailData {
            return data
        }

        // Generate for video items
        guard item.type == .video else { return nil }

        let asset = AVURLAsset(url: item.url)
        if let data = await generateThumbnail(for: asset) {
            // Update cached data
            if let index = items.firstIndex(where: { $0.id == itemId }) {
                items[index].thumbnailData = data
            }
            return data
        }

        return nil
    }

    // MARK: - Search

    /// Search items by name
    func search(query: String) -> [MediaItem] {
        guard !query.isEmpty else { return items }
        let lowercased = query.lowercased()
        return items.filter { $0.displayName.lowercased().contains(lowercased) }
    }

    /// Filter items by type and search query
    func filter(type: MediaType?, query: String = "") -> [MediaItem] {
        var filtered = items

        if let type = type {
            filtered = filtered.filter { $0.type == type }
        }

        if !query.isEmpty {
            let lowercased = query.lowercased()
            filtered = filtered.filter { $0.displayName.lowercased().contains(lowercased) }
        }

        return filtered
    }

    // MARK: - Serialization

    /// Load library from array of items
    func load(items: [MediaItem]) {
        self.items = items
        hasChanges = false
    }

    /// Export items for serialization
    func exportItems() -> [MediaItem] {
        items
    }

    // MARK: - Media Consolidation

    /// Result of a consolidation operation
    struct ConsolidationResult {
        let copiedCount: Int
        let skippedCount: Int
        let failedCount: Int
        let errors: [String]
    }

    /// Find media items that are stored outside the project folder
    func externalMediaItems(projectURL: URL) -> [MediaItem] {
        return items.filter { item in
            !item.url.path.hasPrefix(projectURL.path)
        }
    }

    /// Consolidate all external media into the project's Media folder
    ///
    /// This copies files from external locations into the project package,
    /// updating the media library references to point to the local copies.
    ///
    /// - Parameter projectURL: The URL of the .projector package
    /// - Returns: A result summarizing what was consolidated
    func consolidateMedia(projectURL: URL) async -> ConsolidationResult {
        let mediaFolder = projectURL.appendingPathComponent("Media")
        let fileManager = FileManager.default

        // Create Media folder if needed
        if !fileManager.fileExists(atPath: mediaFolder.path) {
            do {
                try fileManager.createDirectory(at: mediaFolder, withIntermediateDirectories: true)
            } catch {
                return ConsolidationResult(
                    copiedCount: 0,
                    skippedCount: 0,
                    failedCount: items.count,
                    errors: ["Failed to create Media folder: \(error.localizedDescription)"]
                )
            }
        }

        var copiedCount = 0
        var skippedCount = 0
        var failedCount = 0
        var errors: [String] = []

        for item in items {
            // Skip if already inside project
            if item.url.path.hasPrefix(projectURL.path) {
                skippedCount += 1
                continue
            }

            // Determine destination filename (handle duplicates)
            let originalName = item.url.lastPathComponent
            var destinationURL = mediaFolder.appendingPathComponent(originalName)
            var counter = 1

            while fileManager.fileExists(atPath: destinationURL.path) {
                let nameWithoutExt = item.url.deletingPathExtension().lastPathComponent
                let ext = item.url.pathExtension
                destinationURL = mediaFolder.appendingPathComponent("\(nameWithoutExt)_\(counter).\(ext)")
                counter += 1
            }

            do {
                // Start security-scoped access to source
                let didStartAccess = item.url.startAccessingSecurityScopedResource()
                defer {
                    if didStartAccess {
                        item.url.stopAccessingSecurityScopedResource()
                    }
                }

                // Copy the file
                try fileManager.copyItem(at: item.url, to: destinationURL)

                // Create new bookmark for the local copy
                let newBookmark = try destinationURL.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )

                // Update the media item
                updateItemURL(id: item.id, newURL: destinationURL, newBookmark: newBookmark)

                copiedCount += 1
                NSLog(">>> Consolidated: \(originalName) -> \(destinationURL.lastPathComponent)")

            } catch {
                failedCount += 1
                errors.append("\(item.displayName): \(error.localizedDescription)")
                NSLog(">>> Failed to consolidate \(originalName): \(error)")
            }
        }

        return ConsolidationResult(
            copiedCount: copiedCount,
            skippedCount: skippedCount,
            failedCount: failedCount,
            errors: errors
        )
    }
}

// MARK: - Errors

enum MediaLibraryError: LocalizedError {
    case unsupportedFormat
    case fileNotFound
    case importFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "The file format is not supported."
        case .fileNotFound:
            return "The file could not be found."
        case .importFailed(let reason):
            return "Import failed: \(reason)"
        }
    }
}
