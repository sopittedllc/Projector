import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// File manager panel for importing and organizing media files
struct FileManagerView: View {
    @ObservedObject var mediaLibrary: ProjectMediaLibrary
    @ObservedObject var projectDocument: ProjectDocument
    @ObservedObject var timelineManager: TimelineManager
    let onAddToVideoTrack: (MediaItem) -> Void
    let onAddToAudioLane: (MediaItem, Int) -> Void
    let onDeleteItems: ([MediaItem]) -> Void
    let onSaveProject: () -> Void

    /// Whether there are media files stored outside the project folder
    private var hasExternalFiles: Bool {
        guard let projectURL = projectDocument.fileURL else { return false }
        return !mediaLibrary.externalMediaItems(projectURL: projectURL).isEmpty
    }

    /// True if there are external files OR project isn't saved yet (so user sees button and gets save prompt)
    private var showConsolidateButton: Bool {
        // Show button if there are items and either project isn't saved or there are external files
        guard !mediaLibrary.items.isEmpty else { return false }
        if projectDocument.fileURL == nil { return true }
        return hasExternalFiles
    }
    @EnvironmentObject private var dragContext: DragContext

    @State private var selectedItemIds: Set<UUID> = []
    @State private var lastSelectedIndex: Int?
    @State private var isDropTargeted = false
    @State private var filterType: MediaType? = nil
    @State private var searchText = ""
    @State private var isExpanded = true
    @State private var showDeleteAlert = false
    @State private var pendingDeleteItems: [MediaItem] = []
    @State private var isDraggingFromLibrary = false
    @State private var dragEndMonitor: Any?
    @State private var showDuplicateImportAlert = false
    @State private var duplicateImportNames: [String] = []
    @State private var showOptimizationSheet = false
    @State private var showConsolidationSheet = false

    /// ViewModel for optimization - stored in @State to persist across re-renders
    @State private var optimizationViewModel: OptimizationViewModel?

    /// Flag to re-open optimization sheet after project is saved
    @State private var pendingOptimizationAfterSave = false

    /// Flag to re-open consolidation sheet after project is saved
    @State private var pendingConsolidationAfterSave = false

    // Focus state for keyboard commands
    @FocusState private var isMediaListFocused: Bool

    // Marquee selection state
    @State private var isMarqueeSelecting = false
    @State private var marqueeStartPoint: CGPoint = .zero
    @State private var marqueeCurrentPoint: CGPoint = .zero
    @State private var itemFrames: [UUID: CGRect] = [:]
    @State private var scrollContentOffset: CGFloat = 0


    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            contentArea
        }
        .frame(height: isExpanded ? FileManagerLayout.expandedHeight : FileManagerLayout.collapsedHeight, alignment: .top)
        .contentShape(Rectangle())
        .clipped()
        .glassPanel()
        .onChange(of: mediaLibrary.items.count) { _, newCount in
            // Auto-expand when media is first imported
            if newCount > 0 && !isExpanded {
                isExpanded = true
            }
        }
        .focusable()
        .focused($isMediaListFocused)
        .onDeleteCommand {
            requestDeleteSelectedItems()
        }
        .alert("Remove Media Item", isPresented: $showDeleteAlert) {
            Button("Remove", role: .destructive) {
                confirmDeleteSelectedItems()
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {
                pendingDeleteItems = []
            }
            .keyboardShortcut(.cancelAction)
        } message: {
            if pendingDeleteItems.count == 1, let item = pendingDeleteItems.first {
                Text("Remove \"\(item.displayName)\" from the project? This will delete it from the Media panel and remove any timeline clips that use it.")
            } else if pendingDeleteItems.count > 1 {
                Text("Remove \(pendingDeleteItems.count) items from the project? This will delete them from the Media panel and remove any timeline clips that use them.")
            }
        }
        .alert("Already in Project", isPresented: $showDuplicateImportAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(duplicateImportMessage)
        }
        .sheet(isPresented: $showOptimizationSheet, onDismiss: {
            // Reset the ViewModel when sheet is dismissed so a fresh one is created next time
            optimizationViewModel = nil
        }) {
            // Use the stored ViewModel to prevent recreation during re-renders
            if let viewModel = optimizationViewModel {
                OptimizationSheetView(
                    viewModel: viewModel,
                    projectDocument: projectDocument,
                    onSaveProject: onSaveProject,
                    onRequestOptimizationAfterSave: {
                        pendingOptimizationAfterSave = true
                    }
                )
            } else {
                // This shouldn't happen since we create the ViewModel before showing
                ProgressView("Loading...")
                    .onAppear {
                        debugPrint("FileManagerView: ERROR - sheet shown without ViewModel")
                    }
            }
        }
        .onChange(of: showOptimizationSheet) { _, isShowing in
            if isShowing && optimizationViewModel == nil {
                // Create ViewModel when sheet is about to show
                optimizationViewModel = OptimizationViewModel(
                    service: MediaOptimizationService(),
                    mediaLibrary: mediaLibrary,
                    projectDocument: projectDocument,
                    timelineManager: timelineManager
                )
                debugPrint("FileManagerView: created new OptimizationViewModel")
            }
        }
        // Consolidation sheet
        .sheet(isPresented: $showConsolidationSheet) {
            ConsolidationSheetView(
                mediaLibrary: mediaLibrary,
                projectDocument: projectDocument,
                onSaveProject: onSaveProject,
                onRequestConsolidationAfterSave: {
                    pendingConsolidationAfterSave = true
                }
            )
        }
        // Handle File menu consolidation trigger
        .onReceive(NotificationCenter.default.publisher(for: .consolidateMedia)) { _ in
            showConsolidationSheet = true
        }
        // Take focus when an item is selected
        .onChange(of: selectedItemIds) { _, newValue in
            if !newValue.isEmpty {
                isMediaListFocused = true
            }
        }
        // Re-open optimization or consolidation sheet after project is saved
        .onChange(of: projectDocument.fileURL) { oldURL, newURL in
            if oldURL == nil && newURL != nil {
                if pendingOptimizationAfterSave {
                    pendingOptimizationAfterSave = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        showOptimizationSheet = true
                    }
                }
                if pendingConsolidationAfterSave {
                    pendingConsolidationAfterSave = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        showConsolidationSheet = true
                    }
                }
            }
        }
        .onAppear {
            if dragEndMonitor == nil {
                dragEndMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { event in
                    isDraggingFromLibrary = false
                    return event
                }
            }
        }
        .onDisappear {
            if let monitor = dragEndMonitor {
                NSEvent.removeMonitor(monitor)
                dragEndMonitor = nil
            }
        }
    }

    private var duplicateImportMessage: String {
        if duplicateImportNames.count == 1, let name = duplicateImportNames.first {
            return "\"\(name)\" is already in the project."
        }
        return "\(duplicateImportNames.count) files are already in the project."
    }

    // MARK: - Delete

    private func requestDeleteSelectedItems() {
        let items = mediaLibrary.items.filter { selectedItemIds.contains($0.id) }
        guard !items.isEmpty else { return }
        pendingDeleteItems = items
        showDeleteAlert = true
    }

    private func confirmDeleteSelectedItems() {
        let items = pendingDeleteItems
        guard !items.isEmpty else { return }
        onDeleteItems(items)
        pendingDeleteItems = []
        selectedItemIds = []
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: Spacing.md) {
            // Expand/collapse area - entire left side is clickable
            Button(action: { isExpanded.toggle() }) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 12)

                    Image(systemName: "folder")
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
            }
            .buttonStyle(.plain)

            if isExpanded {
                // Filter buttons
                filterButtons

                // Optimize button (only show if there are unoptimized items)
                OptimizeMediaButton(
                    showSheet: $showOptimizationSheet,
                    hasUnoptimizedFiles: mediaLibrary.items.contains { !$0.isOptimized }
                )

                // Consolidate button (only show if there are external files or project unsaved)
                ConsolidateMediaButton(
                    showSheet: $showConsolidationSheet,
                    hasExternalFiles: showConsolidateButton
                )

                // Import button
                Button(action: importMedia) {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "plus")
                            .frame(width: 12, height: 12)
                        Text("Import")
                    }
                }
                .buttonStyle(GlassActionButtonStyle(tint: .accentColor))
            }
        }
        .frame(height: PanelLayout.headerHeight)
        .padding(.horizontal, Spacing.md)
    }

    // MARK: - Filter Buttons

    private var filterButtons: some View {
        HStack(spacing: Spacing.xs) {
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
            if isDropTargeted && !isDraggingFromLibrary {
                dropOverlay
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "film")
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
        GeometryReader { outerGeometry in
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: Spacing.sm) {
                    ForEach(Array(filteredItems.enumerated()), id: \.element.id) { index, item in
                        MediaGridCell(
                            item: item,
                            isSelected: selectedItemIds.contains(item.id),
                            selectedItems: selectedItemIds.contains(item.id) ?
                                mediaLibrary.items.filter { selectedItemIds.contains($0.id) } : [item],
                            onSelect: {
                                handleSelect(item: item, index: index)
                            },
                            onDoubleClick: { handleDoubleClick(item) },
                            onDragStateChange: { isDragging in
                                if isDragging {
                                    isDraggingFromLibrary = true
                                }
                            }
                        )
                        .background(
                            GeometryReader { cellGeometry in
                                Color.clear
                                    .onAppear {
                                        // Store frame in coordinate space of scroll content
                                        itemFrames[item.id] = cellGeometry.frame(in: .named("mediaScrollContent"))
                                    }
                                    .onChange(of: cellGeometry.frame(in: .named("mediaScrollContent"))) { _, newFrame in
                                        itemFrames[item.id] = newFrame
                                    }
                            }
                        )
                    }
                }
                .padding(Spacing.sm)
                .coordinateSpace(name: "mediaScrollContent")
            }
            .scrollIndicators(.visible)
            .coordinateSpace(name: "mediaScrollOuter")
            // Marquee selection gesture - use simultaneous gesture to not block scrolling
            .gesture(
                DragGesture(minimumDistance: 5, coordinateSpace: .named("mediaScrollOuter"))
                    .onChanged { value in
                        // Only start marquee if shift is held or we're clicking on empty space
                        if !isMarqueeSelecting {
                            // Start marquee selection
                            isMarqueeSelecting = true
                            marqueeStartPoint = value.startLocation
                            // Clear selection if not holding shift
                            if !NSEvent.modifierFlags.contains(.shift) {
                                selectedItemIds.removeAll()
                            }
                        }
                        marqueeCurrentPoint = value.location
                        updateMarqueeSelection()
                    }
                    .onEnded { _ in
                        isMarqueeSelecting = false
                    }
            )
            // Marquee selection overlay
            .overlay {
                if isMarqueeSelecting {
                    marqueeSelectionRectangle
                        .allowsHitTesting(false)
                }
            }
        }
    }

    /// Computed marquee rectangle in view coordinates
    private var marqueeRect: CGRect {
        let minX = min(marqueeStartPoint.x, marqueeCurrentPoint.x)
        let minY = min(marqueeStartPoint.y, marqueeCurrentPoint.y)
        let maxX = max(marqueeStartPoint.x, marqueeCurrentPoint.x)
        let maxY = max(marqueeStartPoint.y, marqueeCurrentPoint.y)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Selection rectangle overlay view
    private var marqueeSelectionRectangle: some View {
        Rectangle()
            .stroke(Color.accentColor, lineWidth: 1)
            .background(Color.accentColor.opacity(0.1))
            .frame(width: marqueeRect.width, height: marqueeRect.height)
            .position(x: marqueeRect.midX, y: marqueeRect.midY)
    }

    /// Update selection based on items intersecting with marquee rectangle
    private func updateMarqueeSelection() {
        var newSelection: Set<UUID> = []

        // If shift is held, start with existing selection
        if NSEvent.modifierFlags.contains(.shift) {
            newSelection = selectedItemIds
        }

        // Check each item's frame against the marquee rectangle
        for (itemId, frame) in itemFrames {
            // Adjust frame to account for scroll position if needed
            if marqueeRect.intersects(frame) {
                newSelection.insert(itemId)
            }
        }

        selectedItemIds = newSelection
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 8)
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
            .background(Color.accentColor.opacity(0.1))
            .overlay(
                VStack(spacing: Spacing.sm) {
                    Image(systemName: "plus")
                        .frame(width: 32, height: 32)
                        .foregroundColor(.accentColor)

                    Text("Drop to import")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.accentColor)
                }
            )
            .padding(Spacing.xs)
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
                let urls = panel.urls
                let (newURLs, duplicateNames) = partitionDuplicateImports(urls: urls, library: library)
                if !duplicateNames.isEmpty {
                    duplicateImportNames = duplicateNames
                    showDuplicateImportAlert = true
                }
                for url in newURLs {
                    Task { @MainActor in
                        try? await library.importFile(from: url)
                    }
                }
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        let library = mediaLibrary
        var urls: [URL] = []
        let lock = NSLock()
        let group = DispatchGroup()

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                defer { group.leave() }
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                } else if let url = item as? URL {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
            }
        }

        group.notify(queue: .main) {
            let (newURLs, duplicateNames) = partitionDuplicateImports(urls: urls, library: library)
            if !duplicateNames.isEmpty {
                duplicateImportNames = duplicateNames
                showDuplicateImportAlert = true
            }
            for url in newURLs {
                Task { @MainActor in
                    try? await library.importFile(from: url)
                }
            }
        }
        return true
    }

    private func partitionDuplicateImports(urls: [URL], library: ProjectMediaLibrary) -> ([URL], [String]) {
        let uniqueURLs = Array(Set(urls.map { $0.standardizedFileURL.resolvingSymlinksInPath() }))
        var duplicateNames: [String] = []
        var newURLs: [URL] = []

        for url in uniqueURLs {
            if let existing = library.existingItem(for: url) {
                duplicateNames.append(existing.displayName)
            } else {
                newURLs.append(url)
            }
        }

        return (newURLs, duplicateNames)
    }

    private func handleDoubleClick(_ item: MediaItem) {
        switch item.type {
        case .video:
            onAddToVideoTrack(item)
        case .audio:
            onAddToAudioLane(item, 0)
        }
    }

    private func handleSelect(item: MediaItem, index: Int) {
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.shift), let lastIndex = lastSelectedIndex {
            let lower = min(lastIndex, index)
            let upper = max(lastIndex, index)
            let ids = filteredItems[lower...upper].map { $0.id }
            selectedItemIds = Set(ids)
        } else if modifiers.contains(.command) {
            if selectedItemIds.contains(item.id) {
                selectedItemIds.remove(item.id)
            } else {
                selectedItemIds.insert(item.id)
            }
            lastSelectedIndex = index
        } else {
            selectedItemIds = [item.id]
            lastSelectedIndex = index
        }
    }
}

/// Grid cell for displaying a media item as an icon
struct MediaGridCell: View {
    let item: MediaItem
    let isSelected: Bool
    /// All selected items (for multi-select drag support)
    let selectedItems: [MediaItem]
    let onSelect: () -> Void
    let onDoubleClick: () -> Void
    let onDragStateChange: (Bool) -> Void

    @State private var isDragging = false
    @EnvironmentObject private var dragContext: DragContext

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: Spacing.xs) {
                // Thumbnail
                thumbnailView
                    .frame(width: FileManagerLayout.gridThumbnailWidth, height: FileManagerLayout.gridThumbnailHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                    )
                    .overlay(alignment: .topTrailing) {
                        // Optimization badge
                        if item.isOptimized {
                            Image(systemName: "stopwatch.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.green)
                                .padding(Spacing.xs)
                                .background(Color.black.opacity(0.6))
                                .clipShape(Circle())
                                .padding(Spacing.xs)
                        }
                    }

                // Filename
                Text(item.displayName)
                    .font(.system(size: 9))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: FileManagerLayout.gridLabelWidth)
            }
            .padding(Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            TapGesture(count: 2)
                .onEnded { _ in
                    onDoubleClick()
                }
        )
        .opacity(isDragging ? 0.5 : 1.0)
        .onDrag {
            isDragging = true
            onDragStateChange(true)
            // For multi-select, populate drag context with all selected items
            dragContext.begin(selectedItems)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                isDragging = false
            }
            return MediaDragProvider.provider(for: item)
        }
        .help(item.url.lastPathComponent)
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let data = item.thumbnailData, let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: FileManagerLayout.gridThumbnailWidth, height: FileManagerLayout.gridThumbnailHeight)
                .clipped()
        } else {
            // Placeholder with icon
            Rectangle()
                .fill(Color.secondary.opacity(0.15))
                .overlay(
                    VStack(spacing: Spacing.xs) {
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
            Image(systemName: "video")
        case .audio:
            Image(systemName: "music.note.list")
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
        @StateObject var document = ProjectDocument()
        @StateObject var timelineManager = TimelineManager()

        var body: some View {
            FileManagerView(
                mediaLibrary: library,
                projectDocument: document,
                timelineManager: timelineManager,
                onAddToVideoTrack: { _ in },
                onAddToAudioLane: { _, _ in },
                onDeleteItems: { _ in },
                onSaveProject: { }
            )
            .padding()
        }
    }

    return PreviewWrapper()
}
