import SwiftUI
import Foundation
import UniformTypeIdentifiers

enum MediaDragProvider {
    static func provider(for item: MediaItem) -> NSItemProvider {
        let provider = NSItemProvider(item: item.url as NSURL, typeIdentifier: UTType.fileURL.identifier)
        provider.suggestedName = item.url.lastPathComponent
        if item.type == .audio {
            provider.registerDataRepresentation(forTypeIdentifier: UTType.audio.identifier, visibility: .all) { completion in
                completion(Data(), nil)
                return nil
            }
        } else if item.type == .video {
            provider.registerDataRepresentation(forTypeIdentifier: UTType.movie.identifier, visibility: .all) { completion in
                completion(Data(), nil)
                return nil
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: [
            "id": item.id.uuidString,
            "url": item.url.absoluteString,
            "type": item.type.rawValue,
            "duration": item.duration
        ]) {
            provider.registerDataRepresentation(forTypeIdentifier: UTType.projectorMediaItem.identifier, visibility: .all) { completion in
                completion(data, nil)
                return nil
            }
        }
        return provider
    }
}

extension UTType {
    static let projectorMediaItem = UTType(exportedAs: "com.projector.media-item")
}

/// A row displaying a media item in the file manager
struct MediaItemRow: View {
    let item: MediaItem
    let isSelected: Bool
    let onSelect: () -> Void
    let onDoubleClick: () -> Void

    @State private var isDragging = false
    @EnvironmentObject private var dragContext: DragContext

    var body: some View {
        HStack(spacing: Spacing.sm) {
            // Thumbnail
            thumbnailView
                .frame(width: 48, height: 36)
                .cornerRadius(4)

            // Info
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(item.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                HStack(spacing: Spacing.sm) {
                    // Type indicator
                    typeLabel

                    // Duration
                    Text(item.formattedDuration)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)

                    // Additional info
                    additionalInfo
                }
            }

            Spacer()

            // Optimization status badge
            optimizationBadge

            // Type icon
            typeIcon
                .frame(width: 16, height: 16)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .contentShape(Rectangle())
        // Use Button instead of onTapGesture to avoid ScrollView latency (GP-003)
        .overlay {
            Button(action: onSelect) {
                Color.clear
            }
            .buttonStyle(.plain)
            .simultaneousGesture(
                TapGesture(count: 2)
                    .onEnded { _ in
                        onDoubleClick()
                    }
            )
        }
        .opacity(isDragging ? 0.5 : 1.0)
        .onDrag {
            isDragging = true
            dragContext.begin(item)
            return MediaDragProvider.provider(for: item)
        }
        .onChange(of: isDragging) { _, newValue in
            // Reset dragging state after a delay
            if newValue {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    isDragging = false
                }
            }
        }
    }

    // MARK: - Thumbnail

    @ViewBuilder
    private var thumbnailView: some View {
        if let data = item.thumbnailData, let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .clipped()
        } else {
            Rectangle()
                .fill(Color.secondary.opacity(0.2))
                .overlay(
                    thumbnailPlaceholderIcon
                        .frame(width: 20, height: 20)
                        .foregroundColor(.secondary.opacity(0.5))
                )
        }
    }

    @ViewBuilder
    private var thumbnailPlaceholderIcon: some View {
        switch item.type {
        case .video:
            Image(systemName: "video")
        case .audio:
            Image(systemName: "speaker.wave.3")
        }
    }

    // MARK: - Type Label

    private var typeLabel: some View {
        Text(item.fileExtension.uppercased())
            .font(.system(size: 8, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, 2) // Intentionally small for compact badge
            .background(typeLabelColor)
            .cornerRadius(2)
    }

    private var typeLabelColor: Color {
        switch item.type {
        case .video: return .blue
        case .audio: return .green
        }
    }

    // MARK: - Additional Info

    @ViewBuilder
    private var additionalInfo: some View {
        switch item.type {
        case .video:
            if let fps = item.frameRate {
                Text(String(format: "%.2ffps", fps))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            if let bitrate = item.formattedBitrate {
                Text(bitrate)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        case .audio:
            if let format = item.audioFormatString {
                Text(format)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            if let rate = item.sampleRate {
                Text(String(format: "%.0fkHz", rate / 1000))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            if let bitrate = item.formattedBitrate {
                Text(bitrate)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Type Icon

    @ViewBuilder
    private var typeIcon: some View {
        switch item.type {
        case .video:
            Image(systemName: "video")
        case .audio:
            Image(systemName: "speaker.wave.3")
        }
    }

    // MARK: - Optimization Badge

    @ViewBuilder
    private var optimizationBadge: some View {
        let status = OptimizationStatusHelper.status(for: item)

        switch status {
        case .optimized:
            HStack(spacing: 2) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 8))
                Text("Optimized")
                    .font(.system(size: 8, weight: .medium))
            }
            .foregroundColor(.green)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, 2)
            .background(Color.green.opacity(0.15))
            .cornerRadius(4)
            .help("This file has been optimized for smooth playback")

        case .needsOptimization(let reason):
            HStack(spacing: 2) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 8))
                Text(reason.shortLabel)
                    .font(.system(size: 8, weight: .medium))
            }
            .foregroundColor(.orange)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.15))
            .cornerRadius(4)
            .help(reason.fullDescription)

        case .noAction:
            EmptyView()
        }
    }
}

// MARK: - Optimization Status Helper

/// Helper to determine optimization status for media items
enum OptimizationStatusHelper {

    /// Reasons why optimization might be recommended
    enum OptimizationReason {
        /// Large file that could benefit from compression
        case largeFile(sizeGB: Double)
        /// High-bitrate video that could be compressed
        case highBitrate(mbps: Double)
        /// ProRes or other production codec
        case productionCodec
        /// Large resolution that exceeds playback needs
        case highResolution(width: Int)

        var shortLabel: String {
            switch self {
            case .largeFile: return "Large"
            case .highBitrate: return "High Bitrate"
            case .productionCodec: return "ProRes"
            case .highResolution: return "4K+"
            }
        }

        var fullDescription: String {
            switch self {
            case .largeFile(let gb):
                return String(format: "This %.1f GB file could be compressed to save space", gb)
            case .highBitrate(let mbps):
                return String(format: "%.0f Mbps video could be optimized for smoother playback", mbps)
            case .productionCodec:
                return "ProRes files can be converted to playback proxies to reduce disk usage"
            case .highResolution(let width):
                return "\(width)p video could be downscaled to 720p for lighter playback"
            }
        }
    }

    enum Status {
        case optimized
        case needsOptimization(reason: OptimizationReason)
        case noAction
    }

    /// Thresholds for suggesting optimization
    private enum Thresholds {
        /// Files larger than 500 MB get a warning
        static let largeFileSizeBytes: UInt64 = 500_000_000
        /// Bitrate above 10 Mbps suggests optimization
        static let highBitrateBps: Int = 10_000_000
        /// Resolution wider than 1920 suggests downscaling
        static let highResolutionWidth: CGFloat = 1920
    }

    /// Determine optimization status for a media item
    static func status(for item: MediaItem) -> Status {
        // Already optimized - show green badge
        if item.isOptimized {
            return .optimized
        }

        // Check for production codecs (by file extension as proxy)
        let proResExtensions = ["mov", "mxf"]
        if proResExtensions.contains(item.fileExtension) {
            // Additional check: if bitrate is very high, it's likely ProRes
            if let bitrate = item.bitrate, bitrate > 50_000_000 {
                return .needsOptimization(reason: .productionCodec)
            }
        }

        // Check for high resolution video
        if item.type == .video, let size = item.videoSize {
            if size.width > Thresholds.highResolutionWidth {
                return .needsOptimization(reason: .highResolution(width: Int(size.width)))
            }
        }

        // Check for high bitrate
        if let bitrate = item.bitrate, bitrate > Thresholds.highBitrateBps {
            return .needsOptimization(reason: .highBitrate(mbps: Double(bitrate) / 1_000_000))
        }

        // No optimization needed
        return .noAction
    }
}

#Preview {
    VStack(spacing: 0) {
        MediaItemRow(
            item: MediaItem(
                url: URL(fileURLWithPath: "/path/to/video.mov"),
                type: .video,
                duration: 125.5,
                frameRate: 24.0,
                videoSize: CGSize(width: 1920, height: 1080)
            ),
            isSelected: false,
            onSelect: {},
            onDoubleClick: {}
        )

        Divider()

        MediaItemRow(
            item: MediaItem(
                url: URL(fileURLWithPath: "/path/to/audio.wav"),
                type: .audio,
                duration: 180.0,
                channelCount: 2,
                sampleRate: 48000
            ),
            isSelected: true,
            onSelect: {},
            onDoubleClick: {}
        )
    }
    .frame(width: 300)
    .background(Color(nsColor: .controlBackgroundColor))
}
