import SwiftUI
import UniformTypeIdentifiers
import Iconoir

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

    private let collapsedHeight: CGFloat = 32
    private let expandedHeight: CGFloat = 200

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
        .onDeleteCommand {
            deleteSelectedItem()
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
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filteredItems) { item in
                    MediaItemRow(
                        item: item,
                        isSelected: selectedItemId == item.id,
                        onSelect: { selectedItemId = item.id },
                        onDoubleClick: { handleDoubleClick(item) }
                    )

                    if item.id != filteredItems.last?.id {
                        Divider()
                            .padding(.leading, 68)
                    }
                }
            }
        }
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
