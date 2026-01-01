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

    /// URL of the loaded video file
    @Published var videoURL: URL? {
        didSet { if oldValue != videoURL { markDirty() } }
    }

    /// Timecode offset for the project
    @Published var timecodeOffset: Timecode {
        didSet { if oldValue != timecodeOffset { markDirty() } }
    }

    /// Frame rate of the project
    @Published var frameRate: TimecodeFrameRate {
        didSet { if oldValue != frameRate { markDirty() } }
    }

    /// Audio track routing configuration
    @Published var audioRouting: [Int: Int] = [:] { // trackIndex -> outputChannelOffset
        didSet { if oldValue != audioRouting { markDirty() } }
    }

    // MARK: - Initialization

    init() {
        self.timecodeOffset = Timecode(.components(h: 0, m: 0, s: 0, f: 0), at: .fps24, by: .clamping)
        self.frameRate = .fps24
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
        videoURL = nil
        timecodeOffset = Timecode(.components(h: 0, m: 0, s: 0, f: 0), at: .fps24, by: .clamping)
        frameRate = .fps24
        audioRouting = [:]
        hasUnsavedChanges = false
    }

    // MARK: - Serialization

    /// Project data structure for saving/loading
    struct ProjectData: Codable {
        var videoPath: String?
        var timecodeOffsetFrames: Int
        var frameRateIdentifier: String
        var audioRouting: [String: Int]
        var version: Int = 1
    }

    /// Encode project to data
    func encode() throws -> Data {
        let data = ProjectData(
            videoPath: videoURL?.path,
            timecodeOffsetFrames: timecodeOffset.frameCount.wholeFrames,
            frameRateIdentifier: frameRate.stringValueVerbose,
            audioRouting: audioRouting.reduce(into: [:]) { $0[String($1.key)] = $1.value }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(data)
    }

    /// Decode project from data
    func decode(from data: Data) throws {
        let decoder = JSONDecoder()
        let projectData = try decoder.decode(ProjectData.self, from: data)

        if let path = projectData.videoPath {
            videoURL = URL(fileURLWithPath: path)
        } else {
            videoURL = nil
        }

        // Parse frame rate
        frameRate = TimecodeFrameRate.allCases.first {
            $0.stringValueVerbose == projectData.frameRateIdentifier
        } ?? .fps24

        // Parse timecode offset
        timecodeOffset = Timecode(
            .frames(projectData.timecodeOffsetFrames),
            at: frameRate,
            by: .clamping
        )

        // Parse audio routing
        audioRouting = projectData.audioRouting.reduce(into: [:]) {
            if let key = Int($1.key) {
                $0[key] = $1.value
            }
        }

        hasUnsavedChanges = false
    }

    // MARK: - File Operations

    /// Save project to the specified URL
    func save(to url: URL) throws {
        let data = try encode()
        try data.write(to: url)
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

    /// Load project from the specified URL
    func load(from url: URL) throws {
        let data = try Data(contentsOf: url)
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
