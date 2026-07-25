import Foundation
import SwiftTimecodeCore
import Combine

/// Represents a saveable Projector project document
@MainActor
final class ProjectDocument: ObservableObject {
    // MARK: - Published Properties

    /// Whether the project has unsaved changes
    @Published private(set) var hasUnsavedChanges: Bool = false

    /// The project file URL (nil if never saved)
    @Published private(set) var fileURL: URL?

    /// The project display name
    var displayName: String {
        if let url = fileURL {
            return url.deletingPathExtension().lastPathComponent
        }
        return "Untitled Projector Project"
    }

    // MARK: - Project State

    /// The master timeline with video reels and audio lanes
    @Published var timeline: Timeline {
        didSet { markDirty() }
    }

    /// Media library containing all imported media files
    @Published var mediaLibrary: [MediaItem] = [] {
        didSet { markDirty() }
    }

    /// Window sizes and panel states for this project.
    ///
    /// Deliberately does NOT call `markDirty()`: resizing a window or
    /// collapsing a panel shouldn't leave the project showing unsaved changes
    /// or prompt to save on quit. The layout rides along with the next real
    /// save instead.
    @Published var uiState: ProjectUIState = .default

    // MARK: - Initialization

    init() {
        self.timeline = .empty
    }

    // MARK: - Change Tracking

    /// Mark the document as having unsaved changes
    func markDirty() {
        hasUnsavedChanges = true
    }

    /// Mark the document as saved (no unsaved changes)
    func markClean() {
        hasUnsavedChanges = false
    }

    /// Reset to a new empty project
    func newProject() {
        fileURL = nil
        timeline = .empty
        mediaLibrary = []
        uiState = .default
        hasUnsavedChanges = false
    }

    /// Update the stored UI state without marking the document dirty.
    func updateUIState(_ mutate: (inout ProjectUIState) -> Void) {
        var state = uiState
        mutate(&state)
        guard state != uiState else { return }
        uiState = state
    }

    // MARK: - Serialization

    /// Project data structure
    struct ProjectData: Codable {
        var version: Int = 2
        var timeline: Timeline
        var mediaLibrary: [MediaItem]
        /// Optional so projects written before UI state existed still decode -
        /// a synthesized decoder throws on a missing non-optional key.
        var uiState: ProjectUIState?
    }

    /// Encode project to data
    func encode() throws -> Data {
        let data = ProjectData(
            version: 2,
            timeline: timeline,
            mediaLibrary: mediaLibrary,
            uiState: uiState
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(data)
    }

    /// Decode project from data
    func decode(from data: Data) throws {
        let decoder = JSONDecoder()
        let projectData = try decoder.decode(ProjectData.self, from: data)

        timeline = projectData.timeline
        mediaLibrary = projectData.mediaLibrary
        // Projects saved before UI state existed fall back to the defaults.
        uiState = projectData.uiState ?? .default

        // Resolve bookmarks for timeline video reels
        resolveTimelineBookmarks()

        // Resolve bookmarks for media library
        resolveMediaLibraryBookmarks()

        hasUnsavedChanges = false
    }

    /// Resolve security-scoped bookmarks for timeline video reels
    private func resolveTimelineBookmarks() {
        for i in 0..<timeline.videoReels.count {
            if let bookmark = timeline.videoReels[i].sourceBookmark {
                var isStale = false
                if let url = try? URL(
                    resolvingBookmarkData: bookmark,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                ) {
                    _ = url.startAccessingSecurityScopedResource()
                    timeline.videoReels[i].sourceURL = url
                }
            }
        }

        for laneIndex in 0..<timeline.audioLanes.count {
            for clipIndex in 0..<timeline.audioLanes[laneIndex].clips.count {
                if let bookmark = timeline.audioLanes[laneIndex].clips[clipIndex].sourceBookmark {
                    var isStale = false
                    if let url = try? URL(
                        resolvingBookmarkData: bookmark,
                        options: .withSecurityScope,
                        relativeTo: nil,
                        bookmarkDataIsStale: &isStale
                    ) {
                        _ = url.startAccessingSecurityScopedResource()
                        timeline.audioLanes[laneIndex].clips[clipIndex].sourceURL = url
                    }
                }
            }
        }
    }

    /// Resolve security-scoped bookmarks for media library items
    private func resolveMediaLibraryBookmarks() {
        for i in 0..<mediaLibrary.count {
            if let bookmark = mediaLibrary[i].bookmark {
                var isStale = false
                if let url = try? URL(
                    resolvingBookmarkData: bookmark,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                ) {
                    _ = url.startAccessingSecurityScopedResource()
                    // MediaItem is a struct, need to update the entire item
                    var item = mediaLibrary[i]
                    item = MediaItem(
                        id: item.id,
                        url: url,
                        bookmark: item.bookmark,
                        type: item.type,
                        duration: item.duration,
                        frameRate: item.frameRate,
                        videoSize: item.videoSize,
                        channelCount: item.channelCount,
                        sampleRate: item.sampleRate,
                        importedAt: item.importedAt,
                        thumbnailData: item.thumbnailData
                    )
                    mediaLibrary[i] = item
                }
            }
        }
    }

    // MARK: - File Operations

    /// The filename for project data inside the package
    private static let projectDataFilename = "project.json"

    /// Save project to the specified URL (as a package directory)
    func save(to url: URL) throws {
        let data = try encode()
        debugPrint("ProjectDocument.save: saving to %@", url.path)

        // Create package directory if it doesn't exist
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }

        // Write project data inside the package
        let dataURL = url.appendingPathComponent(Self.projectDataFilename)
        try data.write(to: dataURL)

        fileURL = url
        hasUnsavedChanges = false
    }

    /// Save project to current file URL (must have been saved before)
    func save() throws {
        guard let url = fileURL else {
            throw ProjectError.noFileURL
        }
        try save(to: url)
    }

    /// Load project from the specified URL (package directory)
    func load(from url: URL) throws {
        debugPrint("ProjectDocument.load: loading from %@", url.path)

        // Read project data from inside the package
        let dataURL = url.appendingPathComponent(Self.projectDataFilename)
        let data = try Data(contentsOf: dataURL)

        try decode(from: data)
        fileURL = url
    }

    // MARK: - Errors

    enum ProjectError: LocalizedError {
        case noFileURL

        var errorDescription: String? {
            switch self {
            case .noFileURL:
                return "No file URL specified. Use Save As first."
            }
        }
    }
}

// MARK: - Project UI State

/// Window geometry and panel states saved with the project, so a project
/// reopens laid out the way the user left it.
///
/// Frames are stored as plain numbers rather than `CGRect` to keep the JSON
/// readable and stable. A nil frame means "never positioned" - the window
/// falls back to its default size and centers itself.
struct ProjectUIState: Codable, Equatable {
    /// A saved window frame in screen coordinates.
    struct WindowFrame: Codable, Equatable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double
    }

    // MARK: Windows

    /// Frame of the main Projector window.
    var mainWindowFrame: WindowFrame?

    /// Frame of the standalone player window.
    var playerWindowFrame: WindowFrame?

    /// Whether the player window was on screen when the project was saved.
    var playerWindowVisible: Bool

    /// Whether the player window was pinned above other apps.
    var playerWindowPinned: Bool

    // MARK: Panels

    /// Height of the expanded timeline accordion.
    var timelineExpandedHeight: Double?

    /// Whether the timeline accordion was expanded.
    var timelineExpanded: Bool

    /// Whether the Settings accordion was expanded.
    var settingsExpanded: Bool

    /// Whether the Media panel was expanded.
    var mediaPanelExpanded: Bool

    /// Defaults for a brand new project.
    static let `default` = ProjectUIState(
        mainWindowFrame: nil,
        playerWindowFrame: nil,
        playerWindowVisible: false,
        playerWindowPinned: false,
        timelineExpandedHeight: nil,
        timelineExpanded: true,
        settingsExpanded: false,
        mediaPanelExpanded: true
    )
}

extension ProjectUIState.WindowFrame {
    init(_ rect: CGRect) {
        self.init(
            x: Double(rect.origin.x),
            y: Double(rect.origin.y),
            width: Double(rect.size.width),
            height: Double(rect.size.height)
        )
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}
