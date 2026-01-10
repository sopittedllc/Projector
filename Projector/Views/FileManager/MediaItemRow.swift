import SwiftUI
import Foundation
import UniformTypeIdentifiers
import Iconoir

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
        HStack(spacing: 10) {
            // Thumbnail
            thumbnailView
                .frame(width: 48, height: 36)
                .cornerRadius(4)

            // Info
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                HStack(spacing: 8) {
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

            // Type icon
            typeIcon
                .frame(width: 16, height: 16)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
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
            Iconoir.videoCamera.asImage
        case .audio:
            Iconoir.soundHigh.asImage
        }
    }

    // MARK: - Type Label

    private var typeLabel: some View {
        Text(item.fileExtension.uppercased())
            .font(.system(size: 8, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
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
            Iconoir.videoCamera.asImage
        case .audio:
            Iconoir.soundHigh.asImage
        }
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
