import Foundation
import AVFoundation
import AppKit
import SwiftUI

/// Type of media content
enum MediaType: String, Codable, CaseIterable {
    case video
    case audio
}

/// Shared drag state for internal Media panel drags.
///
/// Supports both single and multi-item drags from the Media panel.
@MainActor
final class DragContext: ObservableObject {
    /// The items currently being dragged (supports multi-select)
    @Published var mediaItems: [MediaItem] = []

    /// Legacy single-item accessor for backwards compatibility
    var mediaItem: MediaItem? { mediaItems.first }

    /// Begin dragging a single item
    func begin(_ item: MediaItem) {
        mediaItems = [item]
    }

    /// Begin dragging multiple items
    func begin(_ items: [MediaItem]) {
        mediaItems = items
    }

    /// End the drag operation
    func end() {
        mediaItems = []
    }

    /// Whether there's an active drag
    var isDragging: Bool { !mediaItems.isEmpty }
}

/// Represents a media file in the project library
struct MediaItem: Identifiable, Codable, Equatable {
    /// Unique identifier
    let id: UUID

    /// Source file URL
    let url: URL

    /// Security-scoped bookmark for sandbox access
    var bookmark: Data?

    /// Type of media
    let type: MediaType

    /// Duration in seconds
    let duration: Double

    /// Frame rate (for video files)
    let frameRate: Double?

    /// Video dimensions (for video files)
    let videoSize: CGSize?

    /// Audio channel count (for audio files, or first audio track of video)
    let channelCount: Int?

    /// Audio sample rate (for audio files, or first audio track of video)
    let sampleRate: Double?

    /// Bitrate in bits per second (estimated from file size / duration)
    let bitrate: Int?

    /// Date the file was imported
    let importedAt: Date

    /// Whether this media has been optimized
    var isOptimized: Bool

    /// Cached thumbnail image (not persisted)
    var thumbnailData: Data?

    /// Display name derived from filename
    var displayName: String {
        url.deletingPathExtension().lastPathComponent
    }

    /// File extension
    var fileExtension: String {
        url.pathExtension.lowercased()
    }

    /// Formatted duration string
    var formattedDuration: String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Video dimensions string
    var dimensionsString: String? {
        guard let size = videoSize else { return nil }
        return "\(Int(size.width))x\(Int(size.height))"
    }

    /// Audio format string
    var audioFormatString: String? {
        guard let channels = channelCount else { return nil }
        switch channels {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(channels)ch"
        }
    }

    /// Formatted bitrate string (e.g., "4.5 Mbps", "320 kbps")
    var formattedBitrate: String? {
        guard let bps = bitrate else { return nil }
        if bps >= 1_000_000 {
            return String(format: "%.1f Mbps", Double(bps) / 1_000_000)
        } else if bps >= 1_000 {
            return String(format: "%d kbps", bps / 1_000)
        } else {
            return "\(bps) bps"
        }
    }

    init(
        id: UUID = UUID(),
        url: URL,
        bookmark: Data? = nil,
        type: MediaType,
        duration: Double,
        frameRate: Double? = nil,
        videoSize: CGSize? = nil,
        channelCount: Int? = nil,
        sampleRate: Double? = nil,
        bitrate: Int? = nil,
        importedAt: Date = Date(),
        isOptimized: Bool = false,
        thumbnailData: Data? = nil
    ) {
        self.id = id
        self.url = url
        self.bookmark = bookmark
        self.type = type
        self.duration = duration
        self.frameRate = frameRate
        self.videoSize = videoSize
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        self.bitrate = bitrate
        self.importedAt = importedAt
        self.isOptimized = isOptimized
        self.thumbnailData = thumbnailData
    }
}

// MARK: - Codable Conformance

extension MediaItem {
    enum CodingKeys: String, CodingKey {
        case id
        case path
        case bookmark
        case type
        case duration
        case frameRate
        case videoWidth
        case videoHeight
        case channelCount
        case sampleRate
        case bitrate
        case importedAt
        case isOptimized
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        let path = try container.decode(String.self, forKey: .path)
        url = URL(fileURLWithPath: path)
        bookmark = try container.decodeIfPresent(Data.self, forKey: .bookmark)
        type = try container.decode(MediaType.self, forKey: .type)
        duration = try container.decode(Double.self, forKey: .duration)
        frameRate = try container.decodeIfPresent(Double.self, forKey: .frameRate)

        if let width = try container.decodeIfPresent(CGFloat.self, forKey: .videoWidth),
           let height = try container.decodeIfPresent(CGFloat.self, forKey: .videoHeight) {
            videoSize = CGSize(width: width, height: height)
        } else {
            videoSize = nil
        }

        channelCount = try container.decodeIfPresent(Int.self, forKey: .channelCount)
        sampleRate = try container.decodeIfPresent(Double.self, forKey: .sampleRate)
        bitrate = try container.decodeIfPresent(Int.self, forKey: .bitrate)
        importedAt = try container.decode(Date.self, forKey: .importedAt)
        isOptimized = try container.decodeIfPresent(Bool.self, forKey: .isOptimized) ?? false
        thumbnailData = nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(id, forKey: .id)
        try container.encode(url.path, forKey: .path)
        try container.encodeIfPresent(bookmark, forKey: .bookmark)
        try container.encode(type, forKey: .type)
        try container.encode(duration, forKey: .duration)
        try container.encodeIfPresent(frameRate, forKey: .frameRate)
        try container.encodeIfPresent(videoSize?.width, forKey: .videoWidth)
        try container.encodeIfPresent(videoSize?.height, forKey: .videoHeight)
        try container.encodeIfPresent(channelCount, forKey: .channelCount)
        try container.encodeIfPresent(sampleRate, forKey: .sampleRate)
        try container.encodeIfPresent(bitrate, forKey: .bitrate)
        try container.encode(importedAt, forKey: .importedAt)
        try container.encode(isOptimized, forKey: .isOptimized)
    }
}
