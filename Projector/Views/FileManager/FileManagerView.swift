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

    // MARK: - Media Actions
    //
    // Both are the same shape: a project must be on disk before either can run,
    // because both write files next to it. If it is unsaved we raise the save
    // sheet and remember what was being attempted - `onChange(of:
    // projectDocument.fileURL)` resumes it once a URL exists. Previously the
    // prompt told the user to save and then dropped the request, so saving
    // appeared to do nothing.

    /// Copy external media into the project folder.
    private func startConsolidate() {
        guard projectDocument.fileURL != nil else {
            pendingConsolidationAfterSave = true
            onSaveProject()
            return
        }
        showConsolidationSheet = true
    }

    /// Re-encode heavy media for smoother playback.
    private func startOptimize() {
        guard projectDocument.fileURL != nil else {
            pendingOptimizationAfterSave = true
            onSaveProject()
            return
        }
        showOptimizationSheet = true
    }

    /// Whether optimizing has anything to offer.
    ///
    /// Answered from the media itself, never from whether the project has been saved.
    /// An unsaved project used to show the button unconditionally, so a project holding
    /// nothing but already-light files still offered to optimize them - and clicking it
    /// prompted for a save first, which made saving look like a precondition for a job
    /// there was no reason to run.
    ///
    /// Saving is still required before optimizing can *start* - `startOptimize()`
    /// handles that - but that is a step in the task, not a reason to advertise it.
    private var showOptimizeButton: Bool {
        mediaLibrary.items.contains { item in
            if case .needsOptimization = OptimizationStatusHelper.status(for: item) { return true }
            return false
        }
    }

    /// Whether consolidating has anything to offer.
    ///
    /// Answered from the media, the same way ``showOptimizeButton`` is: the button
    /// appears only when some file is not already in one of the project's own
    /// folders. Optimized output counts as ours even though it sits beside the
    /// package rather than inside it - see ``ProjectFolders`` - so finishing an
    /// optimize pass no longer leaves a Consolidate button offering to copy the
    /// app's own output back into the project.
    ///
    /// An unsaved project has no folders yet, so every file it holds is outside
    /// them and the button stands. Saving is a step inside the job -
    /// `startConsolidate()` raises the save sheet - not a reason to advertise it.
    private var showConsolidateButton: Bool {
        guard let projectURL = projectDocument.fileURL else {
            return !mediaLibrary.items.isEmpty
        }
        return !mediaLibrary.externalMediaItems(projectURL: projectURL).isEmpty
    }

    /// Height for the optimization banner when visible
    private static let bannerHeight: CGFloat = 70

    /// The media grid's rows, for a given amount of vertical room.
    ///
    /// Cells stay a fixed size - a thumbnail is the same whether the panel holds
    /// two files or two hundred - so a taller panel earns more *rows* rather
    /// than bigger cells. That is what makes the top row growing with the window
    /// worth something here: without it the extra height was dead space beneath
    /// two rows that would not use it.
    ///
    /// Two rows is the floor, matching `FileManagerLayout.expandedHeight`.
    private static func mediaGridRows(forHeight height: CGFloat) -> [GridItem] {
        let rowPitch = FileManagerLayout.gridCellHeight + Spacing.sm
        let usable = height - FileManagerLayout.scrollIndicatorHeight - Spacing.sm * 2
        let fits = Int(((usable + Spacing.sm) / rowPitch).rounded(.down))
        return Array(
            repeating: GridItem(.fixed(FileManagerLayout.gridCellHeight), spacing: Spacing.sm),
            count: max(2, fits)
        )
    }

    /// Calculate minimum height based on expanded state and banner visibility
    @EnvironmentObject private var dragContext: DragContext

    /// Measured width of the header bar, used to pick full vs compact controls.
    /// Starts at infinity so the first (unmeasured) frame renders the full
    /// variant rather than flashing compact.
    @State private var headerBarWidth: CGFloat = .infinity

    @State private var selectedItemIds: Set<UUID> = []
    @State private var lastSelectedIndex: Int?
    @State private var isDropTargeted = false
    @State private var filterType: MediaType? = nil

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

    /// Tracks dismissed suggestion types for this session (prevents re-showing after dismiss)
    @State private var dismissedSuggestionTypes: Set<String> = []

    /// The suggestion worth making about the current media, if any.
    ///
    /// Derived, never stored. Held in `@State` it could only be refreshed by
    /// something remembering to refresh it, and the only trigger wired up was a
    /// change in the *number* of media items - which optimizing does not change.
    /// So the banner went on advertising work after that work was done, unless
    /// the user happened to start the job from the banner itself, which cleared
    /// it by hand.
    ///
    /// Asking the media each time means the banner appears when there is
    /// something to offer and disappears when there is not, with no bookkeeping.
    private var activeSuggestion: OptimizationSuggestion? {
        var productionCodecCount = 0
        var otherHeavyCount = 0

        for item in mediaLibrary.items {
            guard case .needsOptimization = OptimizationStatusHelper.status(for: item) else { continue }
            if OptimizationStatusHelper.isProductionCodec(item) {
                productionCodecCount += 1
            } else {
                otherHeavyCount += 1
            }
        }

        if productionCodecCount > 0, !dismissedSuggestionTypes.contains(Self.proResDismissalKey) {
            return .proResDetected(count: productionCodecCount)
        }
        if otherHeavyCount > 0, !dismissedSuggestionTypes.contains(Self.heavyMediaDismissalKey) {
            return .highBitrateImport(count: otherHeavyCount)
        }
        return nil
    }

    // Keys recording which kinds of suggestion the user has waved off this session.
    private static let proResDismissalKey = "proRes"
    private static let heavyMediaDismissalKey = "highBitrate"

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

            // Optimization suggestion banner - below header divider for
            // symmetric header padding. Hidden while collapsed - it does
            // not fit the header-height frame, and importing auto-expands the
            // panel anyway, so a live suggestion is still seen.
            if let suggestion = activeSuggestion {
                OptimizationSuggestionBanner(
                    suggestion: suggestion,
                    onOptimize: {
                        // Same destination as the header button - one place to
                        // reason about media housekeeping. The banner is not
                        // dismissed here: it stands until the media stops
                        // qualifying, so cancelling the sheet leaves the
                        // still-pending work on offer.
                        startOptimize()
                    },
                    onDismiss: {
                        // Track dismissed type to prevent re-showing
                        switch suggestion {
                        case .highBitrateImport:
                            dismissedSuggestionTypes.insert(Self.heavyMediaDismissalKey)
                        case .proResDetected:
                            dismissedSuggestionTypes.insert(Self.proResDismissalKey)
                        }
                    }
                )
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xs)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            contentArea
        }
        // maxWidth is explicit because nothing else supplies it once collapsed:
        // the content area was the only child that stretched, so with it gone
        // the panel shrank to the header's intrinsic width and sat centred.
        // Fills whatever the top row gives it. Collapsing was removed with the
        // accordion chrome: the panel has a set height now, so a disclosure
        // that toggled between that height and a header served no purpose.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .clipped()
        .glassPanel()
        .onAppear {
        }
        // The banner is derived from the media, so it needs no change trigger -
        // only something to animate the appearance and disappearance.
        .animation(AppAnimations.standard, value: activeSuggestion)
        .focusable()
        .focused($isMediaListFocused)
        .onDeleteCommand {
            requestDeleteSelectedItems()
        }
        .onReceive(NotificationCenter.default.publisher(for: .editSelectAll)) { _ in
            // Only select all if this view has focus
            if isMediaListFocused {
                selectedItemIds = Set(filteredItems.map { $0.id })
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .editDeselectAll)) { _ in
            if isMediaListFocused {
                selectedItemIds.removeAll()
            }
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
        .onChangeCompat(of: showOptimizationSheet) { isShowing in
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
        // Take focus when an item is selected
        .onChangeCompat(of: selectedItemIds) { newValue in
            if !newValue.isEmpty {
                isMediaListFocused = true
            }
        }
        // Re-open optimization or consolidation sheet after project is saved
        .onChangeWithPrevious(of: projectDocument.fileURL) { oldURL, newURL in
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
            // A title, not a control. The panel has a set height, so there is
            // nothing for a disclosure to toggle between.
            HStack(spacing: Spacing.sm) {
                Image(systemName: "folder")
                    .frame(width: 14, height: 14)
                    .foregroundColor(.secondary)

                Text("Media")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                Text("(\(filteredItems.count))")
                    .font(Typography.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .accessibilityLabel("Media, \(filteredItems.count) items")

            do {
                Spacer(minLength: 0)

                // A single variant chosen by measured width, not ViewThatFits.
                // ViewThatFits builds BOTH variants and only lays out one; the
                // hidden duplicate registered its own tooltip regions, which
                // broke .help() on the visible controls. One rendered subtree
                // means one set of tooltip regions.
                expandedHeaderControls(compact: headerBarWidth < FileManagerLayout.headerFullControlsMinWidth)
            }
        }
        .frame(height: PanelLayout.headerHeight)
        .padding(.horizontal, Spacing.md)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { headerBarWidth = geo.size.width }
                    .onChangeCompat(of: geo.size.width) { newWidth in
                        headerBarWidth = newWidth
                    }
            }
        )
    }

    /// Filters, consolidate, and import controls.
    /// - Parameter compact: When true, renders icon-only buttons (with `.help()` tooltips)
    ///   instead of icon+label, for use as the fallback in `ViewThatFits`.
    private func expandedHeaderControls(compact: Bool) -> some View {
        HStack(spacing: Spacing.md) {
            // Filter buttons
            filterButtons

            // Two buttons, two jobs. They were briefly one "Prepare Media"
            // sheet with checkable steps; separated again because consolidating
            // and optimizing answer different questions and are wanted at
            // different times.
            ConsolidateMediaButton(
                hasWork: showConsolidateButton,
                compact: compact,
                action: { startConsolidate() }
            )

            PrepareMediaButton(
                hasWork: showOptimizeButton,
                compact: compact,
                action: { startOptimize() }
            )
            .fixedSize(horizontal: true, vertical: false)

            // Import button
            Button(action: importMedia) {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "plus")
                        .frame(width: 12, height: 12)
                    if !compact {
                        Text("Import")
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
            // Tooltip goes through the style, not .help(): NSToolTip never
            // fires through the macOS 26 glassEffect layer this button sits on.
            // Compact only - when the "Import" label is visible the tooltip
            // would just repeat it.
            .buttonStyle(GlassActionButtonStyle(tint: AppColors.accent, help: compact ? "Import media files" : nil))
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("Import media files")
        }
        .fixedSize(horizontal: true, vertical: false)
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
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xs)
                .background(filterType == type ? Color.accentColor.opacity(0.1) : Color.clear)
                .cornerRadius(Spacing.xs)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Content Area

    private var contentArea: some View {
        ZStack {
            if filteredItems.isEmpty {
                // An empty library and an over-narrow filter are different
                // problems with different fixes - telling someone with 50 files
                // that they have "no media files" just because their search
                // missed sends them to the Import button for no reason.
                if mediaLibrary.items.isEmpty {
                    emptyStateView
                } else {
                    noMatchesStateView
                }
            } else {
                itemsList
            }

            // Drop overlay
            if isDropTargeted && !isDraggingFromLibrary {
                dropOverlay
            }
        }
        .padding(Spacing.md) // Equal padding on ALL sides
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "film")
                .font(.system(size: 32))
                .foregroundColor(.secondary.opacity(0.5))

            Text("No media files")
                .font(Typography.heading)
                .foregroundColor(.secondary)

            Text("Drop files here or click Import")
                .font(Typography.bodySmall)
                .foregroundColor(.secondary.opacity(0.7))
        }
    }

    /// Shown when the library has media but the current search or type filter
    /// excludes all of it. Offers a way back rather than a dead end.
    private var noMatchesStateView: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32))
                .foregroundColor(.secondary.opacity(0.5))

            Text(noMatchesTitle)
                .font(Typography.heading)
                .foregroundColor(.secondary)
                .lineLimit(1)

            Button("Clear filters") {
                filterType = nil
            }
            .buttonStyle(.link)
            .font(Typography.bodySmall)
            .help("Show all \(mediaLibrary.items.count) media files again")
        }
        .frame(maxWidth: .infinity)
    }

    private var noMatchesTitle: String {
        switch filterType {
        case .video: return "No video files in this project"
        case .audio: return "No audio files in this project"
        case nil: return "No media matches the current filters"
        }
    }

    private var itemsList: some View {
        GeometryReader { outerGeometry in
            ScrollView(.horizontal, showsIndicators: true) {
                // Filled column by column, still scrolling sideways. A single
                // HStack meant the panel was one thumbnail tall no matter how
                // much media a project held.
                LazyHGrid(rows: Self.mediaGridRows(forHeight: outerGeometry.size.height),
                          spacing: Spacing.sm) {
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
                                    .onChangeCompat(of: cellGeometry.frame(in: .named("mediaScrollContent"))) { newFrame in
                                        itemFrames[item.id] = newFrame
                                    }
                            }
                        )
                    }
                }
                .padding(Spacing.sm)
                .coordinateSpace(name: "mediaScrollContent")
            }
            // Kept exactly as it was wherever the modifier exists. Below
            // macOS 13 the indicators follow the system default instead, which
            // means they fade rather than staying visible.
            .modifier(AlwaysVisibleScrollIndicators())
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

        // Newest first. Was one of three user-selectable orders; with the sort
        // menu gone this is the order the library always had by default.
        items.sort { (a: MediaItem, b: MediaItem) -> Bool in
            a.importedAt > b.importedAt
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
                        // Optimization status badge
                        optimizationBadge
                    }

                // Filename
                Text(item.displayName)
                    .font(Typography.captionSmall)
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

    /// Marks media that still has optimizing to offer.
    ///
    /// Only that. Optimized media used to carry a green checkmark for the life of
    /// the project, which left the grid permanently flagged for a job that was
    /// finished - a badge earns its place by pointing at work, and there is none
    /// left on a file that has been optimized.
    @ViewBuilder
    private var optimizationBadge: some View {
        let status = OptimizationStatusHelper.status(for: item)
        switch status {
        case .optimized:
            EmptyView()
        case .needsOptimization(let reason):
            Image(systemName: reason.icon)
                .font(Typography.caption)
                .foregroundColor(reason.color)
                .padding(Spacing.xs)
                .background(Color.black.opacity(0.6))
                .clipShape(Circle())
                .padding(Spacing.xs)
                .help("\(reason.shortLabel) - optimization recommended")
        case .noAction:
            EmptyView()
        }
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

// MARK: - Optimization Status Helper

/// Helper to determine optimization status for media items
enum OptimizationStatusHelper {

    /// Reasons why optimization might be recommended
    enum OptimizationReason {
        case highBitrate(mbps: Double)
        case productionCodec
        case highResolution(width: Int)

        var shortLabel: String {
            switch self {
            case .highBitrate: return "High Bitrate"
            case .productionCodec: return "ProRes"
            case .highResolution: return "4K+"
            }
        }

        var color: Color {
            switch self {
            case .highBitrate: return .orange
            case .productionCodec: return .purple
            case .highResolution: return .blue
            }
        }

        var icon: String {
            switch self {
            case .highBitrate: return "speedometer"
            case .productionCodec: return "film"
            case .highResolution: return "4k.tv"
            }
        }
    }

    enum Status {
        case optimized
        case needsOptimization(reason: OptimizationReason)
        case noAction
    }

    private enum Thresholds {
        static let highBitrateBps: Int = 10_000_000
        static let highResolutionWidth: CGFloat = 1920
        static let productionCodecBps: Int = 50_000_000
    }

    /// Container formats that carry production codecs.
    private static let productionCodecExtensions = ["mov", "mxf"]

    /// Whether an item is a heavy production-codec file.
    ///
    /// The container alone does not settle it - plenty of ordinary deliveries are
    /// `.mov` - so the bitrate has to agree.
    static func isProductionCodec(_ item: MediaItem) -> Bool {
        guard productionCodecExtensions.contains(item.fileExtension) else { return false }
        guard let bitrate = item.bitrate else { return false }
        return bitrate > Thresholds.productionCodecBps
    }

    static func status(for item: MediaItem) -> Status {
        if item.isOptimized {
            return .optimized
        }

        // Check for production codecs
        if isProductionCodec(item) {
            return .needsOptimization(reason: .productionCodec)
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

        return .noAction
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


/// Pins scroll indicators visible where `scrollIndicators(_:)` exists.
///
/// macOS 13 introduced the modifier. Older systems fall through unchanged, so
/// their indicators behave as the system decides.
private struct AlwaysVisibleScrollIndicators: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 13, *) {
            content.scrollIndicators(.visible)
        } else {
            content
        }
    }
}
