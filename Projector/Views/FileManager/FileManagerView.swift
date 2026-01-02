import SwiftUI
import UniformTypeIdentifiers
import Iconoir
import AppKit

/// File manager panel for importing and organizing media files
struct FileManagerView: View {
    @ObservedObject var mediaLibrary: ProjectMediaLibrary
    let onAddToVideoTrack: (MediaItem) -> Void
    let onAddToAudioLane: (MediaItem, Int) -> Void

    @State private var selectedItemId: UUID?
    @State private var isDropTargeted = false
    @State private var filterType: MediaType? = nil
    @State private var searchText = ""
    @State private var isExpanded = false

    // Focus state for keyboard commands
    @FocusState private var isMediaListFocused: Bool

    private let collapsedHeight: CGFloat = 32
    /// Fixed expanded height for horizontal scroll layout
    private let expandedHeight: CGFloat = 125

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            contentArea
        }
        .frame(height: isExpanded ? expandedHeight : collapsedHeight, alignment: .top)
        .contentShape(Rectangle())
        .clipped()
        .background(
            VisualEffectView(material: .dark, blendingMode: .behindWindow, alphaValue: 0.6)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
        .onChange(of: mediaLibrary.items.count) { _, newCount in
            // Auto-expand when media is first imported
            if newCount > 0 && !isExpanded {
                isExpanded = true
            }
        }
        .focusable()
        .focused($isMediaListFocused)
        .onDeleteCommand {
            deleteSelectedItem()
        }
        // Take focus when an item is selected
        .onChange(of: selectedItemId) { _, newValue in
            if newValue != nil {
                isMediaListFocused = true
            }
        }
    }

    // MARK: - Delete

    private func deleteSelectedItem() {
        guard let itemId = selectedItemId else { return }
        mediaLibrary.removeItem(id: itemId)
        selectedItemId = nil
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 12) {
            // Expand/collapse area - entire left side is clickable
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 12)

                Iconoir.folder.asImage
                    .frame(width: 14, height: 14)
                    .foregroundColor(.secondary)

                Text("Media")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)

                Text("(\(filteredItems.count))")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)

                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture {
                isExpanded.toggle()
            }

            if isExpanded {
                // Filter buttons
                filterButtons

                // Import button
                Button(action: importMedia) {
                    HStack(spacing: 4) {
                        Iconoir.plus.asImage
                            .frame(width: 12, height: 12)
                        Text("Import")
                            .font(.system(size: 11))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.1))
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 32)
        .padding(.horizontal, 12)
    }

    // MARK: - Filter Buttons

    private var filterButtons: some View {
        HStack(spacing: 4) {
            filterButton(title: "All", type: nil)
            filterButton(title: "Video", type: .video)
            filterButton(title: "Audio", type: .audio)
        }
    }

    private func filterButton(title: String, type: MediaType?) -> some View {
        Button(action: { filterType = type }) {
            Text(title)
                .font(.system(size: 10, weight: filterType == type ? .semibold : .regular))
                .foregroundColor(filterType == type ? .accentColor : .secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(filterType == type ? Color.accentColor.opacity(0.1) : Color.clear)
                .cornerRadius(3)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Content Area

    private var contentArea: some View {
        ZStack {
            if filteredItems.isEmpty {
                emptyStateView
            } else {
                itemsList
            }

            // Drop overlay
            if isDropTargeted {
                dropOverlay
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Iconoir.mediaVideo.asImage
                .frame(width: 32, height: 32)
                .foregroundColor(.secondary.opacity(0.5))

            Text("No media files")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            Text("Drop files here or click Import")
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var itemsList: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 8) {
                ForEach(filteredItems) { item in
                    MediaGridCell(
                        item: item,
                        isSelected: selectedItemId == item.id,
                        onSelect: { selectedItemId = item.id },
                        onDoubleClick: { handleDoubleClick(item) }
                    )
                }
            }
            .padding(8)
        }
        .scrollIndicators(.visible)
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 8)
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
            .background(Color.accentColor.opacity(0.1))
            .overlay(
                VStack(spacing: 8) {
                    Iconoir.plus.asImage
                        .frame(width: 32, height: 32)
                        .foregroundColor(.accentColor)

                    Text("Drop to import")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.accentColor)
                }
            )
            .padding(4)
    }

    // MARK: - Computed Properties

    private var filteredItems: [MediaItem] {
        var items = mediaLibrary.items

        // Filter by type
        if let type = filterType {
            items = items.filter { $0.type == type }
        }

        // Filter by search
        if !searchText.isEmpty {
            items = items.filter {
                $0.displayName.localizedCaseInsensitiveContains(searchText)
            }
        }

        return items
    }

    // MARK: - Actions

    private func importMedia() {
        let library = mediaLibrary
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            UTType.movie, UTType.video, UTType.audio,
            UTType(filenameExtension: "mov")!,
            UTType(filenameExtension: "mp4")!,
            UTType(filenameExtension: "wav")!,
            UTType(filenameExtension: "aif")!,
            UTType(filenameExtension: "mxf") ?? UTType.data
        ]

        panel.begin { response in
            if response == .OK {
                for url in panel.urls {
                    Task { @MainActor in
                        try? await library.importFile(from: url)
                    }
                }
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        let library = mediaLibrary
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    Task { @MainActor in
                        try? await library.importFile(from: url)
                    }
                } else if let url = item as? URL {
                    Task { @MainActor in
                        try? await library.importFile(from: url)
                    }
                }
            }
        }
        return true
    }

    private func handleDoubleClick(_ item: MediaItem) {
        switch item.type {
        case .video:
            onAddToVideoTrack(item)
        case .audio:
            onAddToAudioLane(item, 0)
        }
    }
}

/// Grid cell for displaying a media item as an icon
struct MediaGridCell: View {
    let item: MediaItem
    let isSelected: Bool
    let onSelect: () -> Void
    let onDoubleClick: () -> Void

    @State private var lastTapTime: Date?
    @State private var isDragging = false

    var body: some View {
        VStack(spacing: 4) {
            // Thumbnail
            thumbnailView
                .frame(width: 64, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                )

            // Filename
            Text(item.displayName)
                .font(.system(size: 9))
                .foregroundColor(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 80)
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            let now = Date()
            if let last = lastTapTime, now.timeIntervalSince(last) < 0.3 {
                onDoubleClick()
                lastTapTime = nil
            } else {
                onSelect()
                lastTapTime = now
            }
        }
        .opacity(isDragging ? 0.5 : 1.0)
        .onDrag {
            isDragging = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                isDragging = false
            }
            return NSItemProvider(object: item.url as NSURL)
        }
        .help(item.url.lastPathComponent)
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let data = item.thumbnailData, let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 64, height: 48)
                .clipped()
        } else {
            // Placeholder with icon
            Rectangle()
                .fill(Color.secondary.opacity(0.15))
                .overlay(
                    VStack(spacing: 2) {
                        typeIcon
                            .frame(width: 24, height: 24)
                            .foregroundColor(.secondary.opacity(0.6))
                        // Type badge
                        Text(item.fileExtension.uppercased())
                            .font(.system(size: 7, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(typeBadgeColor)
                            .cornerRadius(2)
                    }
                )
        }
    }

    @ViewBuilder
    private var typeIcon: some View {
        switch item.type {
        case .video:
            Iconoir.videoCamera.asImage
        case .audio:
            Iconoir.musicDoubleNote.asImage
        }
    }

    private var typeBadgeColor: Color {
        switch item.type {
        case .video: return .blue
        case .audio: return .green
        }
    }
}

#Preview {
    struct PreviewWrapper: View {
        @StateObject var library = ProjectMediaLibrary()

        var body: some View {
            FileManagerView(
                mediaLibrary: library,
                onAddToVideoTrack: { _ in },
                onAddToAudioLane: { _, _ in }
            )
            .padding()
        }
    }

    return PreviewWrapper()
}
