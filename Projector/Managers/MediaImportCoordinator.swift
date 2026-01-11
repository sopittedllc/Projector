import Foundation
import UniformTypeIdentifiers

/// Box to make NSItemProvider Sendable for async operations
private struct ProviderBox: @unchecked Sendable {
    let provider: NSItemProvider
}

/// Coordinates media import operations including drag-and-drop handling,
/// URL extraction, and duplicate detection.
///
/// This coordinator manages the import flow for both video and audio files,
/// working with the media library and timeline to add content appropriately.
@MainActor
final class MediaImportCoordinator: ObservableObject {
    // MARK: - Dependencies

    private let mediaLibrary: ProjectMediaLibrary
    private let timelineManager: TimelineManager
    private let timelineViewModel: TimelineViewModel

    // MARK: - Published State

    /// Whether the duplicate media alert should be shown
    @Published var showDuplicateMediaAlert = false

    /// Names of media files that were duplicates
    @Published var duplicateMediaNames: [String] = []

    // MARK: - Callbacks

    /// Callback to add a video to the timeline at an optional frame position
    var onImportVideo: ((URL, Int?) async -> Void)?

    /// Callback to add an audio file to a lane at an optional frame position
    /// Parameters: (url, laneId, atFrame) -> AudioClip?
    var onImportAudio: ((URL, UUID, Int?) async -> AudioClip?)?

    /// Callback to create a new audio lane
    /// Returns the newly created lane
    var onCreateAudioLane: (() -> AudioLane)?

    /// Callback to expand the timeline after import
    var onExpandTimeline: (() -> Void)?

    // MARK: - Initialization

    /// Creates a new media import coordinator.
    ///
    /// - Parameters:
    ///   - mediaLibrary: The project media library for tracking imported files
    ///   - timelineManager: The timeline manager for accessing timeline state
    ///   - timelineViewModel: The timeline view model for UI state updates
    init(
        mediaLibrary: ProjectMediaLibrary,
        timelineManager: TimelineManager,
        timelineViewModel: TimelineViewModel
    ) {
        self.mediaLibrary = mediaLibrary
        self.timelineManager = timelineManager
        self.timelineViewModel = timelineViewModel
    }

    // MARK: - Drop Handling

    /// Handles a drop of item providers onto the application.
    ///
    /// Processes all dropped items, filtering for supported media types,
    /// detecting duplicates, and importing new files appropriately.
    ///
    /// - Parameter providers: The dropped item providers
    /// - Returns: `true` if the drop was accepted
    func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }

        Task { @MainActor in
            var urls: [URL] = []

            // Load all URLs from providers
            for provider in providers {
                if let url = await loadURL(from: provider) {
                    urls.append(url)
                }
            }

            let supportedURLs = urls.filter { ProjectMediaLibrary.isSupported(url: $0) }
            let (newURLs, duplicateNames) = partitionDuplicateMediaURLs(supportedURLs)

            if !duplicateNames.isEmpty {
                self.duplicateMediaNames = duplicateNames
                self.showDuplicateMediaAlert = true
            }

            // Process each URL sequentially
            for url in newURLs {
                guard let mediaType = ProjectMediaLibrary.mediaType(for: url) else {
                    continue
                }

                switch mediaType {
                case .video:
                    await onImportVideo?(url, nil)

                case .audio:
                    // Create a new audio lane for each audio file
                    if let newLane = onCreateAudioLane?() {
                        _ = await onImportAudio?(url, newLane.id, nil)
                    }
                }
            }

            // Auto-expand timeline after all files are processed
            if !urls.isEmpty {
                onExpandTimeline?()
            }
        }

        return true
    }

    // MARK: - URL Extraction

    /// Loads a URL from an NSItemProvider.
    ///
    /// Attempts to extract a file URL first, falling back to a generic URL if needed.
    ///
    /// - Parameter provider: The item provider to extract the URL from
    /// - Returns: The extracted URL, or `nil` if extraction failed
    func loadURL(from provider: NSItemProvider) async -> URL? {
        let boxedProvider = ProviderBox(provider: provider)
        return await withCheckedContinuation { continuation in
            boxedProvider.provider.loadItem(
                forTypeIdentifier: UTType.fileURL.identifier,
                options: nil
            ) { item, _ in
                if let url = Self.extractURL(from: item) {
                    continuation.resume(returning: url)
                    return
                }
                boxedProvider.provider.loadItem(
                    forTypeIdentifier: UTType.url.identifier,
                    options: nil
                ) { item, _ in
                    continuation.resume(returning: Self.extractURL(from: item))
                }
            }
        }
    }

    /// Extracts a URL from various possible representations.
    ///
    /// - Parameter item: The raw item from the provider (Data, URL, NSURL, or String)
    /// - Returns: The extracted URL, or `nil` if conversion failed
    /// - Note: This is nonisolated to allow calling from NSItemProvider callbacks
    nonisolated static func extractURL(from item: Any?) -> URL? {
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        if let url = item as? URL {
            return url
        }
        if let url = item as? NSURL {
            return url as URL
        }
        if let string = item as? String {
            return URL(string: string)
        }
        return nil
    }

    // MARK: - Duplicate Detection

    /// Partitions a list of URLs into new files and duplicates.
    ///
    /// Checks each URL against the media library to determine if it's already imported.
    ///
    /// - Parameter urls: The URLs to check
    /// - Returns: A tuple of (new URLs to import, names of duplicate files)
    func partitionDuplicateMediaURLs(_ urls: [URL]) -> ([URL], [String]) {
        let uniqueURLs = Array(Set(urls.map { $0.standardizedFileURL.resolvingSymlinksInPath() }))
        var duplicateNames: [String] = []
        var newURLs: [URL] = []

        for url in uniqueURLs {
            if let existing = mediaLibrary.existingItem(for: url) {
                duplicateNames.append(existing.displayName)
            } else {
                newURLs.append(url)
            }
        }

        return (newURLs, duplicateNames)
    }

    // MARK: - Alert Message

    /// Message to display in the duplicate media alert.
    var duplicateMediaAlertMessage: String {
        if duplicateMediaNames.count == 1, let name = duplicateMediaNames.first {
            return "\"\(name)\" is already in the project."
        }
        return "\(duplicateMediaNames.count) files are already in the project."
    }
}
