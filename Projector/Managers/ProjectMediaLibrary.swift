import Foundation
import AVFoundation
import Combine
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - ProjectFolders

/// The folders a project owns on disk, and the test for whether a file is in one.
///
/// A project is not just the `.projector` package. It is a session folder, and
/// the media lives beside the package rather than inside it:
///
/// ```
/// ProjectFolder/
///   Project.projector/     <- the package, holding project.json
///   Media/                 <- created at save; consolidating copies here
///   Optimized Media/       <- created at save; written by optimizing
///   Raw Files/             <- only if originals are moved aside after optimizing
/// ```
///
/// Projects consolidated before this layout have their media at
/// `Project.projector/Media/`; that location is still recognised as ours.
///
/// Consolidating asks "is this file already ours?", and the answer has to cover
/// all of them. Asking only the package meant every optimized file read as
/// external media, so finishing an optimize pass *raised* the Consolidate
/// button - offering to copy the app's own output back into the project.
///
/// The sibling folders are matched by name rather than by taking the whole
/// enclosing directory: a project saved straight to the Desktop would otherwise
/// claim everything on the Desktop as already consolidated.
enum ProjectFolders {

    /// Media copied by consolidating, beside the package.
    static let mediaFolderName = "Media"

    /// Playback-friendly re-encodes, written beside the package.
    static let optimizedMediaFolderName = "Optimized Media"

    /// Originals moved aside after optimizing, written beside the package.
    static let rawFilesFolderName = "Raw Files"

    /// Whether the package lives in its own session folder, as the Save sheet creates.
    ///
    /// True when the enclosing folder's name equals the package's name without
    /// its extension (`Cut/Cut.projector`). Only then is the sibling "Media"
    /// folder ours.
    ///
    /// "Media" is gated because it is a generic name: a hand-placed
    /// `Desktop/Cut.projector` must not claim `Desktop/Media/`. "Optimized Media"
    /// and "Raw Files" are distinctively named and only ever written by this app,
    /// so they are recognised beside any package without the gate.
    ///
    /// - Parameter projectURL: The `.projector` package.
    static func isInSessionFolder(projectURL: URL) -> Bool {
        let packageName = projectURL.deletingPathExtension().lastPathComponent
        return projectURL.deletingLastPathComponent().lastPathComponent == packageName
    }

    /// Where consolidating copies media for a project.
    ///
    /// In a session folder that is the sibling "Media" folder; otherwise the
    /// legacy in-package `X.projector/Media/`, so nothing is ever written into
    /// an unrelated neighbouring folder.
    ///
    /// - Parameter projectURL: The `.projector` package.
    static func mediaFolder(forProjectAt projectURL: URL) -> URL {
        let base = isInSessionFolder(projectURL: projectURL)
            ? projectURL.deletingLastPathComponent()
            : projectURL
        return base.appendingPathComponent(mediaFolderName)
    }

    /// Creates the folders a saved project always has: "Media" and "Optimized Media".
    ///
    /// Safe to call on a project that already has them.
    ///
    /// "Raw Files" is deliberately not created. It exists only as the result of
    /// the user choosing to move their originals aside, so an empty one would
    /// claim a decision that was never made.
    ///
    /// - Parameter projectURL: The `.projector` package; the folders are made beside it.
    /// - Throws: Any error from creating a directory.
    static func createStandardFolders(forProjectAt projectURL: URL) throws {
        let enclosing = projectURL.deletingLastPathComponent()
        for name in [mediaFolderName, optimizedMediaFolderName] {
            try FileManager.default.createDirectory(
                at: enclosing.appendingPathComponent(name),
                withIntermediateDirectories: true
            )
        }
    }

    /// The "Optimized Media" folder for a project, or `nil` if it is unsaved.
    static func optimizedMediaFolder(forProjectAt projectURL: URL?) -> URL? {
        projectURL?.deletingLastPathComponent().appendingPathComponent(optimizedMediaFolderName)
    }

    /// The "Raw Files" folder for a project, or `nil` if it is unsaved.
    static func rawFilesFolder(forProjectAt projectURL: URL?) -> URL? {
        projectURL?.deletingLastPathComponent().appendingPathComponent(rawFilesFolderName)
    }

    /// Whether a file already lives in one of the project's own folders.
    ///
    /// - Parameters:
    ///   - url: The file to test.
    ///   - projectURL: The `.projector` package.
    /// - Returns: `true` if the file is inside the package or one of its
    ///   sibling project folders.
    static func contains(_ url: URL, projectURL: URL) -> Bool {
        let enclosing = projectURL.deletingLastPathComponent()
        var roots = [
            // The package itself stays a root: projects consolidated before the
            // session-folder layout hold their media at `X.projector/Media/`,
            // and those files must still read as ours.
            projectURL,
            enclosing.appendingPathComponent(optimizedMediaFolderName),
            enclosing.appendingPathComponent(rawFilesFolderName)
        ]
        if isInSessionFolder(projectURL: projectURL) {
            roots.append(enclosing.appendingPathComponent(mediaFolderName))
        }
        return roots.contains { isDescendant(url, of: $0) }
    }

    /// Whether a file is this project's own optimized output.
    ///
    /// - Parameters:
    ///   - url: The file to test.
    ///   - projectURL: The `.projector` package.
    /// - Returns: `true` if the file is inside the project's "Optimized Media" folder.
    static func isOptimizedOutput(_ url: URL, projectURL: URL) -> Bool {
        guard let folder = optimizedMediaFolder(forProjectAt: projectURL) else { return false }
        return isDescendant(url, of: folder)
    }

    /// Whether `url` sits inside `folder`, compared a path component at a time.
    ///
    /// String prefixes are the wrong tool here twice over: `/Movies/Show` is a
    /// textual prefix of `/Movies/Showreel/clip.mov`, which is a different
    /// directory entirely, and the same file arrives spelled `/var/...` or
    /// `/private/var/...` depending on who resolved it.
    private static func isDescendant(_ url: URL, of folder: URL) -> Bool {
        let fileParts = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let folderParts = folder.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard fileParts.count > folderParts.count else { return false }
        return Array(fileParts.prefix(folderParts.count)) == folderParts
    }
}

// MARK: - ProjectMediaLibrary

/// Manages the project's media library - importing, organizing, and providing filtered views.
///
/// `ProjectMediaLibrary` is the central repository for all media assets in a Projector project.
/// It handles importing files from disk, maintaining security-scoped bookmarks for sandbox access,
/// and providing filtered views of the library contents.
///
/// ## Architecture
///
/// ```
/// ┌─────────────────────────────────────────────────────────────────┐
/// │                    ProjectDocument                              │
/// │  (owns and persists ProjectMediaLibrary)                        │
/// └─────────────────────────────────────────────────────────────────┘
///                               │
///                               ▼
/// ┌─────────────────────────────────────────────────────────────────┐
/// │              ProjectMediaLibrary (this file)                    │
/// │  - Imports media files with metadata extraction                 │
/// │  - Maintains security-scoped bookmarks                          │
/// │  - Provides filtered views (video/audio, search)                │
/// │  - Supports media consolidation into the project's Media folder   │
/// └─────────────────────────────────────────────────────────────────┘
///                               │
///                               ▼
/// ┌─────────────────────────────────────────────────────────────────┐
/// │                       MediaItem                                 │
/// │  (Codable model with URL, bookmark, metadata)                   │
/// └─────────────────────────────────────────────────────────────────┘
/// ```
///
/// ## Thread Safety
///
/// This class is confined to `@MainActor` for safe UI observation via `@Published` properties.
/// All file I/O operations use `async` methods that don't block the main thread.
///
/// ## Usage
///
/// ```swift
/// let library = ProjectMediaLibrary()
///
/// // Import a video file
/// let item = try await library.importFile(from: videoURL)
///
/// // Search the library
/// let results = library.search(query: "interview")
///
/// // Filter by type
/// let videos = library.videoItems
/// ```
///
/// ## Security-Scoped Access
///
/// When files are imported, security-scoped bookmarks are created to maintain sandbox access
/// across app launches. Use ``refreshAccess(for:)`` to re-establish access when needed.
@MainActor
final class ProjectMediaLibrary: ObservableObject {
    // MARK: - Published Properties

    /// All media items in the library
    @Published private(set) var items: [MediaItem] = []

    /// Whether there are unsaved changes
    @Published private(set) var hasChanges: Bool = false

    /// Currently importing items (for progress display)
    @Published private(set) var importingCount: Int = 0

    /// Successful security-scope acquisitions owned by their media item.
    private var activeSecurityScopedURLs: [UUID: URL] = [:]

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

    /// Callback invoked when the library contents change.
    ///
    /// Used by `ProjectDocument` to trigger auto-save when media is added or removed.
    var onLibraryChanged: (() -> Void)?

    // MARK: - Initialization

    /// Creates a new media library with optional initial items.
    ///
    /// - Parameter items: Initial media items to populate the library (default empty).
    init(items: [MediaItem] = []) {
        self.items = items
    }

    deinit {
        for url in activeSecurityScopedURLs.values {
            url.stopAccessingSecurityScopedResource()
        }
    }

    // MARK: - Change Tracking

    /// Marks the library as having unsaved changes.
    ///
    /// Triggers the ``onLibraryChanged`` callback for auto-save.
    private func markDirty() {
        hasChanges = true
        onLibraryChanged?()
    }

    /// Clears the unsaved changes flag after successful save.
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
        var codecName: String?
        var isDecodable: Bool?

        // Identify the codec and whether this Mac can decode it.
        //
        // Reading this at import is what lets Projector name a format it cannot play.
        // Extension checks cannot: a QuickTime file carrying Avid DNxHD is a perfectly
        // valid .mov, and everything else here - duration, frame rate, timecode -
        // reads correctly from it whether or not a decoder exists.
        if type == .video, let support = try? await VideoCodecSupport.inspect(asset) {
            codecName = support.displayName
            isDecodable = support.isDecodable
            if !support.isDecodable {
                diagnosticLog(
                    .error, .media,
                    "No decoder for \(support.displayName) (\(support.fourCC)) in \(url.lastPathComponent)"
                )
            }
        }

        // Get video track info
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        if let videoTrack = videoTracks.first {
            let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
            frameRate = Double(nominalFrameRate)

            // Apply the track's preferred transform: `naturalSize` is the
            // encoded size, which for rotated footage has width and height the
            // wrong way round. Anything sizing itself to the media - the player
            // window, resolution readouts - needs the *display* size.
            let naturalSize = try await videoTrack.load(.naturalSize)
            let transform = try await videoTrack.load(.preferredTransform)
            let displayRect = CGRect(origin: .zero, size: naturalSize).applying(transform).standardized
            videoSize = CGSize(width: abs(displayRect.width), height: abs(displayRect.height))
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

        var item = MediaItem(
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
        item.codecName = codecName
        item.isDecodable = isDecodable

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

    /// Imports multiple media files into the library.
    ///
    /// Processes each URL sequentially and collects results. Failed imports don't prevent
    /// other files from being imported.
    ///
    /// - Parameter urls: Array of file URLs to import.
    /// - Returns: Array of results, one per URL, indicating success or failure.
    func importFiles(from urls: [URL]) async -> [Result<MediaItem, Error>] {
        var results: [Result<MediaItem, Error>] = []

        for url in urls {
            do {
                let item = try await importFile(from: url)
                diagnosticLog(.info, .media, "Imported \(url.lastPathComponent) (\(item.type), \(String(format: "%.1f", item.duration))s)")
                results.append(.success(item))
            } catch {
                diagnosticLog(.error, .media, "Import failed for \(url.lastPathComponent): \(error.localizedDescription)")
                results.append(.failure(error))
            }
        }

        return results
    }

    /// Removes a media item from the library.
    ///
    /// - Parameter id: The unique identifier of the item to remove.
    /// - Note: This does not delete the source file from disk.
    func removeItem(id: UUID) {
        releaseAccess(for: id)
        items.removeAll { $0.id == id }
        markDirty()
    }

    /// Removes multiple items from the library.
    ///
    /// - Parameter ids: Set of unique identifiers for items to remove.
    /// - Note: This does not delete source files from disk.
    func removeItems(ids: Set<UUID>) {
        for id in ids {
            releaseAccess(for: id)
        }
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
            debugPrint("ProjectMediaLibrary.updateItemURL: item not found for id=\(id)")
            return
        }
        let item = items[index]
        let newIsOptimized = isOptimized ?? item.isOptimized
        debugPrint("ProjectMediaLibrary.updateItemURL: id=\(id), oldURL=\(item.url.lastPathComponent), newURL=\(newURL.lastPathComponent), oldIsOptimized=\(item.isOptimized), newIsOptimized=\(newIsOptimized)")

        let bookmark = newBookmark ?? (try? newURL.bookmarkData(options: .withSecurityScope))

        // Any active scope belongs to the old URL. Releasing it before the
        // replacement ensures a later refresh resolves and acquires the new
        // bookmark instead of returning a stale success for the old file.
        releaseAccess(for: id)

        // A different file may hold a different codec (optimizing turns DNxHR into
        // HEVC). Unknown is honest; the old name would not be.
        if items[index].url.standardizedFileURL != newURL.standardizedFileURL {
            items[index].codecName = nil
        }
        items[index].url = newURL
        items[index].bookmark = bookmark
        items[index].isOptimized = newIsOptimized
        debugPrint("ProjectMediaLibrary.updateItemURL: UPDATED - items[\(index)].isOptimized = \(items[index].isOptimized)")
        markDirty()
    }

    /// Retrieves a media item by its unique identifier.
    ///
    /// - Parameter id: The unique identifier of the item to retrieve.
    /// - Returns: The matching `MediaItem`, or `nil` if not found.
    func item(withId id: UUID) -> MediaItem? {
        items.first { $0.id == id }
    }

    /// Refreshes file access for an item using its security-scoped bookmark.
    ///
    /// Call this method to re-establish sandbox access to a file that was previously imported.
    /// The bookmark is stored with the media item and can survive app relaunches.
    ///
    /// - Parameter itemId: The unique identifier of the item to refresh.
    /// - Returns: `true` if access was successfully restored, `false` otherwise.
    /// - Note: Returns `false` if the item doesn't exist, has no bookmark, or the file was moved.
    func refreshAccess(for itemId: UUID) -> Bool {
        if activeSecurityScopedURLs[itemId] != nil {
            return true
        }

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
                activeSecurityScopedURLs[itemId] = url
                return true
            }
        } catch {
            debugPrint("ProjectMediaLibrary: Failed to refresh access: \(error)")
        }

        return false
    }

    /// Releases a security scope previously acquired for a media item.
    private func releaseAccess(for itemId: UUID) {
        activeSecurityScopedURLs.removeValue(forKey: itemId)?
            .stopAccessingSecurityScopedResource()
    }

    // MARK: - Thumbnail Generation

    /// Generates a thumbnail image for a video asset.
    ///
    /// Extracts a frame at 1 second into the video and encodes it as PNG data.
    /// Uses CoreGraphics/ImageIO to avoid AppKit dependency in the Logic layer.
    ///
    /// - Parameter asset: The AVAsset to extract a thumbnail from.
    /// - Returns: PNG-encoded image data, or `nil` if extraction fails.
    /// - Note: Maximum thumbnail size is 640×360 pixels.
    private func generateThumbnail(for asset: AVAsset) async -> Data? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 360)

        do {
            let time = CMTime(seconds: 1, preferredTimescale: 600)
            // `image(at:)` is macOS 13. The continuation-wrapped callback API
            // is available on Monterey and returns the same picture.
            let cgImage: CGImage = try await withCheckedThrowingContinuation { continuation in
                generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, _, _, error in
                    if let image {
                        continuation.resume(returning: image)
                    } else {
                        continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                    }
                }
            }

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

    /// Retrieves thumbnail data for a media item.
    ///
    /// Returns cached thumbnail data if available, otherwise generates a new thumbnail
    /// for video items. Audio items return `nil`.
    ///
    /// - Parameter itemId: The unique identifier of the media item.
    /// - Returns: PNG-encoded thumbnail data, or `nil` if unavailable.
    /// - Note: The View layer is responsible for converting Data to NSImage/Image.
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

    /// Loads the library from a persisted array of items.
    ///
    /// Replaces all current items and clears the unsaved changes flag.
    /// Used by `ProjectDocument` when loading a saved project.
    ///
    /// - Parameter items: Array of `MediaItem` objects from saved data.
    func load(items: [MediaItem]) {
        for url in activeSecurityScopedURLs.values {
            url.stopAccessingSecurityScopedResource()
        }
        activeSecurityScopedURLs.removeAll()
        self.items = items
        hasChanges = false
    }

    /// Exports all items for persistence.
    ///
    /// - Returns: Array of all `MediaItem` objects in the library.
    func exportItems() -> [MediaItem] {
        items
    }

    // MARK: - Media Consolidation

    /// Result of a media consolidation operation.
    ///
    /// Summarizes the outcome of copying external media files into the project's Media folder.
    struct ConsolidationResult {
        /// Number of files successfully copied into the project.
        let copiedCount: Int

        /// Number of files skipped (already inside project).
        let skippedCount: Int

        /// Number of files that failed to copy.
        let failedCount: Int

        /// Error messages for failed copies.
        let errors: [String]
    }

    /// Finds media items stored outside the project's own folders.
    ///
    /// Use this to identify which files need consolidation before sharing a project.
    /// The Consolidate Media button is shown from exactly this answer, so files the
    /// app itself wrote beside the package - optimized media, moved originals - must
    /// not count as external. See ``ProjectFolders``.
    ///
    /// - Parameter projectURL: The URL of the `.projector` package.
    /// - Returns: Array of `MediaItem` objects with external file references.
    func externalMediaItems(projectURL: URL) -> [MediaItem] {
        return items.filter { item in
            !ProjectFolders.contains(item.url, projectURL: projectURL)
        }
    }

    /// Consolidate all external media into the project's Media folder
    ///
    /// This copies files from external locations into the project's "Media" folder
    /// (beside the package in a session folder), updating the media library references to point to
    /// the local copies.
    ///
    /// - Parameter projectURL: The URL of the .projector package
    /// - Returns: A result summarizing what was consolidated
    func consolidateMedia(projectURL: URL) async -> ConsolidationResult {
        let mediaFolder = ProjectFolders.mediaFolder(forProjectAt: projectURL)
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
            // Skip anything already in one of the project's own folders - the same
            // test that decides whether this job is offered at all.
            if ProjectFolders.contains(item.url, projectURL: projectURL) {
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
                debugPrint("Consolidated: \(originalName) -> \(destinationURL.lastPathComponent)")

            } catch {
                failedCount += 1
                errors.append("\(item.displayName): \(error.localizedDescription)")
                debugPrint("Failed to consolidate \(originalName): \(error)")
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

/// Errors that can occur during media library operations.
enum MediaLibraryError: LocalizedError {
    /// The file format is not in the list of supported extensions.
    case unsupportedFormat

    /// The file could not be located on disk.
    case fileNotFound

    /// Import failed with a specific reason.
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
