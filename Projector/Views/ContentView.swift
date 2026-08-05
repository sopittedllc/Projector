import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import SwiftTimecodeCore
import AppKit
import Combine


/// Main application content view
struct ContentView: View {
    // MARK: - Managers
    // Note: Some properties use internal access to allow extension in ContentView+Setup.swift
    @StateObject var playbackEngine: PlaybackEngine
    @StateObject var timelineManager: TimelineManager
    @StateObject var mediaLibrary: ProjectMediaLibrary
    @StateObject var waveformCache = WaveformCache()
    @StateObject var audioManager = AudioOutputManager()
    @StateObject var projectDocument: ProjectDocument
    @ObservedObject var settings = AppSettings.shared
    @StateObject private var dragContext = DragContext()
    @Environment(\.undoManager) var undoManager

    // MARK: - MIDI Sync (Actor-based for thread safety)
    /// The MIDI sync actor (logic layer) - handles MTC/MMC on dedicated context
    let midiSyncActor: MIDISyncActor
    /// ViewModel bridging actor state to UI
    @StateObject var midiSyncViewModel: MIDISyncViewModel

    // MARK: - Timeline ViewModel
    /// ViewModel for timeline UI state and interactions
    @StateObject var timelineViewModel: TimelineViewModel

    // MARK: - Transport (Actor-based for thread safety)
    /// The transport actor (logic layer) - handles transport state
    let transportActor: TransportActor
    /// ViewModel bridging actor state to UI
    @StateObject var transportViewModel: TransportViewModel

    // MARK: - Missing File Resolution
    /// Service for handling missing file resolution when loading projects
    @StateObject var missingFileService: MissingFileResolutionService

    // MARK: - Media Import Coordination
    /// Coordinator for handling media drag-and-drop and import operations
    @StateObject var mediaImportCoordinator: MediaImportCoordinator

    // MARK: - Project Persistence
    /// Service for project save/load/consolidate operations
    @StateObject var persistenceService: ProjectPersistenceService

    // MARK: - Initialization

    init() {
        // Initialize MIDI sync actor and view model
        let actor = MIDISyncActor()
        self.midiSyncActor = actor
        self._midiSyncViewModel = StateObject(wrappedValue: MIDISyncViewModel(service: actor))

        // Initialize timeline manager, actor, and view model
        let manager = TimelineManager()
        let timelineActor = TimelineActor(timelineManager: manager)
        let timelineVM = TimelineViewModel(service: timelineActor)
        self._timelineManager = StateObject(wrappedValue: manager)
        self._timelineViewModel = StateObject(wrappedValue: timelineVM)

        // Initialize media library, project document, and playback engine
        let library = ProjectMediaLibrary()
        let document = ProjectDocument()
        let engine = PlaybackEngine()
        self._mediaLibrary = StateObject(wrappedValue: library)
        self._projectDocument = StateObject(wrappedValue: document)
        self._playbackEngine = StateObject(wrappedValue: engine)

        // Initialize transport actor and view model (requires playbackEngine, timelineActor, midiSyncActor)
        let transport = TransportActor(
            playbackEngine: engine,
            timelineActor: timelineActor,
            midiSyncService: actor
        )
        self.transportActor = transport
        self._transportViewModel = StateObject(wrappedValue: TransportViewModel(service: transport))

        // Initialize missing file resolution service
        self._missingFileService = StateObject(wrappedValue: MissingFileResolutionService(
            mediaLibrary: library,
            timelineManager: manager,
            projectDocument: document
        ))

        // Initialize media import coordinator
        self._mediaImportCoordinator = StateObject(wrappedValue: MediaImportCoordinator(
            mediaLibrary: library,
            timelineManager: manager,
            timelineViewModel: timelineVM
        ))

        // Initialize persistence service
        self._persistenceService = StateObject(wrappedValue: ProjectPersistenceService(
            projectDocument: document,
            mediaLibrary: library,
            timelineManager: manager,
            playbackEngine: engine
        ))
    }

    // MARK: - Alert & Sheet Coordination
    @StateObject var alerts = AlertCoordinator()

    /// Gathers hard-panned reels so one import raises one split offer.
    @StateObject var splitOffers = SplitOfferCoordinator()

    // MARK: - UI State
    // Note: Some properties use internal access to allow extension in ContentView+Timeline.swift and ContentView+Setup.swift
    @State private var showWelcomeOverlay = false
    @State var isLoadingMedia = false
    @State var midiCancellables = Set<AnyCancellable>()
    @StateObject var thumbnailCache = ThumbnailCache()
    @State var showFileManager = true
    #if DEBUG
    @State var didHandleUITestImport = false
    @State var didHandleUITestDrop = false
    @State var uiTestImportState: String? = "boot"
    #endif

    /// Fraction of the window's flexible height given to the top row.
    ///
    /// The one piece of layout state the app keeps, and it is a *proportion*
    /// rather than a height - see rule 2 of the section authority in
    /// `SectionLayout`. Storing a height meant a window resize either overwrote
    /// the balance the user had set or left it stale; storing the share means the
    /// same balance is re-resolved at whatever size the window happens to be.
    @State var topRowShare: CGFloat = SectionLayout.defaultTopRowShare

    /// Height of the content area, last time the window laid out. Used only to
    /// convert a splitter drag back into a share.
    @State private var contentHeight: CGFloat = SectionLayout.referenceContentSize.height

    // Section splitter drag state.
    @State private var isDraggingSplitter = false
    @State private var isHoveringSplitter = false
    @State private var splitterDragStartHeight: CGFloat = 0
    @State private var splitterDragStartLocationY: CGFloat = 0
    @State private var didPushSplitterCursor = false

    /// How many runloop passes to wait for the window to exist before giving up
    /// on applying the default size.
    static let windowLookupAttempts = 20

    // No measured content sizes are kept here: the section authority sizes
    // content from the window, not the window from its content.

    // Settings panel state (collapsed by default).
    // Internal, not private: ContentView+Helpers restores it from the project.

    // FPS conflict state (internal for ContentView+Timeline.swift extension)
    @State var pendingVideoURL: URL?
    @State var pendingVideoFPS: TimecodeFrameRate?
    @State var pendingVideoInsertFrame: Int?
    @State var videoInsertURL: URL?
    @State var videoAlreadyInTimelineName: String = ""
    @State var audioAlreadyInTimelineName: String = ""

    /// Audio lanes reserved for files in an in-flight batch drop.
    ///
    /// Empty lanes look available to anything scanning for a free lane, so a
    /// video's embedded-audio import would otherwise claim a lane earmarked for
    /// one of the batch's audio files. Cleared once the batch is placed.
    @State var reservedAudioLaneIds: Set<UUID> = []

    /// Lanes created by an in-flight drop, so the ones nothing landed on can be
    /// removed again once it finishes.
    @State var batchCreatedLaneIds: Set<UUID> = []

    /// Flag to prevent concurrent timecode detection from multiple drop events
    @State var isProcessingTimecodeDetection = false

    /// Whether an import is scanning files, for the loading overlay.
    ///
    /// Once the same thing as `isProcessingTimecodeDetection` minus the time a
    /// placement sheet was up. Import asks nothing now, so there is no waiting to
    /// subtract and the two are the same value.
    var isDetectingTimecode: Bool {
        isProcessingTimecodeDetection
    }

    /// Service for detecting embedded timecode from media files
    let embeddedTimecodeService = EmbeddedTimecodeService()

    /// Service for exporting cue lists from audio analysis
    let cueListExportService = CueListExportService()

    // MARK: - Onboarding
    /// Shows the interactive onboarding wizard
    @State private var showOnboarding = false

    // MARK: - Cue List Export
    /// Error message for cue list export failures
    @State var cueListExportError: String?
    /// Whether cue list export error alert is showing
    @State var showCueListExportError = false

    // MARK: - Bug Reporting
    /// Whether the bug report sheet is showing.
    @State var showBugReport = false
    /// Built fresh each time the sheet opens, so the report describes the app as
    /// it was when the user noticed the problem.
    @State var bugReportViewModel: BugReportViewModel?

    var body: some View {
        mainContent
            .alertCoordinator(alerts)
            .sheet(isPresented: Binding(
                get: { alerts.activeAlert?.id == "settings" },
                // Guarded so a dismissal only ever clears the settings sheet.
                // The getter is false for every other alert, and acting on that
                // would dismiss whatever is really on screen.
                set: { if !$0, alerts.activeAlert?.id == "settings" { alerts.dismiss() } }
            )) {
                SettingsView(
                    audioManager: audioManager,
                    isPresented: Binding(
                        get: { alerts.activeAlert?.id == "settings" },
                        set: { if !$0, alerts.activeAlert?.id == "settings" { alerts.dismiss() } }
                    )
                )
            }
            .sheet(isPresented: $showOnboarding, content: onboardingSheetContent)
            .sheet(isPresented: $showBugReport) {
                if let bugReportViewModel {
                    BugReportView(
                        viewModel: bugReportViewModel,
                        isPresented: $showBugReport
                    )
                }
            }
            // Help > Report a Bug reaches the same sheet. The menu is built in
            // AppKit, which has no path to this view's state, so it asks by
            // notification instead.
            .onReceive(
                NotificationCenter.default.publisher(for: .projectorReportBugRequested)
            ) { _ in
                presentBugReport()
            }
            .alert("Export Cue List", isPresented: $showCueListExportError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(cueListExportError ?? "An unknown error occurred.")
            }
            .frame(
                minWidth: HorizontalLayoutConstants.mainWindowMinWidth,
                minHeight: HorizontalLayoutConstants.mainWindowMinHeight
            )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WindowGlassBackground())
        .overlay {
            if showWelcomeOverlay {
                WelcomeOverlayView(isPresented: $showWelcomeOverlay)
            }
        }
        .navigationTitle("")
        .background(WindowTitleConfigurator(
            title: projectDocument.displayName,
            isEdited: projectDocument.hasUnsavedChanges
        ))
        .onReceive(NotificationCenter.default.publisher(for: .videoFileSelected)) { notification in
            // Add dropped video to timeline
            if let url = notification.object as? URL {
                Task {
                    await addVideoToTimeline(url: url, atFrame: nil)
                }
            }
        }
        .onAppear {
            setupMIDICallbacks()
            setupAudioCallback()
            setupTimelineCallbacks()

            // Reclaim the audio earlier versions extracted to disk. Nothing
            // writes these any more. Off the main thread: it stats every file in
            // the temporary directory, and none of it is needed before the
            // window is usable.
            Task.detached(priority: .background) {
                let reclaimed = TemporaryAudioFiles.purgeLegacyFiles()
                if reclaimed > 0 {
                    debugPrint("TemporaryAudioFiles: reclaimed \(reclaimed / 1_000_000) MB")
                }
            }

            // Start transport actor (sets up PlaybackEngine callbacks)
            Task { await transportActor.start() }

            restoreSettings()
            #if DEBUG
            handleUITestImportIfNeeded()
            handleUITestDropIfNeeded()
            #endif
            setupPersistenceServiceCallbacks()
            setupMediaImportCoordinatorCallbacks()

            // Show onboarding for first-time users (replaces welcome overlay)
            if !isUITesting && !AppSettings.shared.hasCompletedWelcome {
                showOnboarding = true
            }
        }
        // Sync unsaved changes state with AppDelegate for quit confirmation
        .onReceive(projectDocument.$hasUnsavedChanges) { hasChanges in
            AppDelegate.hasUnsavedChanges = hasChanges
        }
        // Save handlers - selector-backed commands bypass AppKit's Save validation
        .onReceive(NotificationCenter.default.publisher(for: .saveProject)) { _ in
            if !persistenceService.saveProject() {
                showSaveProjectSheetViaCoordinator()  // No file URL, show Save As
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveProjectAs)) { _ in
            showSaveProjectSheetViaCoordinator()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openProjectFile)) { notification in
            debugPrint("ContentView: received openProjectFile notification")
            if let url = notification.object as? URL {
                debugPrint("ContentView: opening project from %@", url.path)
                persistenceService.openProject(from: url)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openProjectFromMenu)) { _ in
            persistenceService.showOpenProjectPanel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .newProject)) { _ in
            handleNewProject()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showOnboarding)) { _ in
            showOnboarding = true
        }
        .onOpenURL { url in
            debugPrint("ContentView.onOpenURL: %@", url.path)
            if url.pathExtension.lowercased() == "projector" {
                persistenceService.openProject(from: url)
            }
        }
    }

    // MARK: - Main Content (extracted for type-checker performance)

    private var mainContent: some View {
        Group {
            normalView
        }
        #if DEBUG
        .overlay(alignment: .topLeading) {
            if isUITesting {
                VStack(alignment: .leading, spacing: 2) {
                    Text(uiTestImportState ?? "boot")
                        .accessibilityIdentifier("ui-test-status")
                        .accessibilityLabel(uiTestImportState ?? "boot")
                        .accessibilityValue(uiTestImportState ?? "boot")

                    Text(String(uiTestClipCount))
                        .accessibilityIdentifier("ui-test-clip-count")
                        .accessibilityLabel(String(uiTestClipCount))
                        .accessibilityValue(String(uiTestClipCount))
                }
                .font(.system(size: 1))
                .opacity(0.01)
                .allowsHitTesting(false)
            }
        }
        #endif
    }

    // MARK: - View Modes

    private var normalView: some View {
        // The player lives in its own window (PlayerWindowController), so the
        // main window is transport + panels only - no split.
        //
        // The `everything` section: the window's content area, less its margins.
        // The GeometryReader has to be outside anything that could scroll -
        // inside one it would report the content's height, which is the height it
        // is being asked to decide, and the layout would chase its own tail.
        GeometryReader { proxy in
            let sections = SectionLayout.resolve(
                content: CGSize(
                    width: proxy.size.width - SectionLayout.margin * 2,
                    height: proxy.size.height - SectionLayout.margin * 2
                ),
                topRowShare: topRowShare
            )

            // Video and the Media panel share the top row; the timeline gets its
            // own full-width row beneath. It is the widest thing in the app -
            // MTC IN, Start TC, Duration and zoom in one header, over a ruler -
            // so giving it the whole window is what stops it competing with the
            // video column for room. The splitter between them moves the
            // boundary, and stores where the user put it as a share.
            VStack(spacing: 0) {
                topRow(sections)

                sectionSplitter(sections)

                timelinePanel(sections)
            }
            .padding(SectionLayout.margin)
            .onAppear { contentHeight = sections.everything.height }
            .onChangeCompat(of: sections.everything.height) { newValue in
                contentHeight = newValue
            }
            // Outputs defined in Settings are the source of truth for
            // routing; lanes follow. See the audio routing authority in
            // TimelineManager.
            .onChangeCompat(of: audioManager.mappedOutputs) { outputs in
                timelineManager.reconcileOutputMappings(with: outputs)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environmentObject(dragContext)
        .onAppear {
            // Build the player window but leave it hidden - it appears when the
            // first video arrives (see the videoReels observer below), since a
            // project with no video has nothing to show.
            let player = PlayerWindowController.shared
            player.configure(
                playbackEngine: playbackEngine,
                settings: settings,
                dragContext: dragContext,
                onDropURLs: { urls in handlePlaybackAreaDrop(urls: urls) },
                onDropProviders: { providers in mediaImportCoordinator.handleDrop(providers: providers) }
            )
            player.onVisibilityChanged = { visible in
                projectDocument.updateUIState { $0.playerWindowVisible = visible }
            }
            player.onFrameChanged = { frame in
                projectDocument.updateUIState { $0.playerWindowFrame = .init(frame) }
            }
            // The pin can also be toggled from the View menu, so mirror it
            // from the notification rather than only from the window button.
            NotificationCenter.default.addObserver(
                forName: .playerWindowPinDidChange,
                object: nil,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    projectDocument.updateUIState {
                        $0.playerWindowPinned = settings.playerWindowPinnedToFront
                    }
                }
            }

            applyDefaultMainWindowSizeIfNeeded()
            applySavedUIState()
        }
        // Persist layout changes as the user makes them. The window's own frame
        // is captured whenever the content area changes size, which is the only
        // thing a user resize can produce now that nothing resizes the window
        // back at them.
        .onChangeCompat(of: contentHeight) { _ in captureMainWindowFrame() }
        .onChangeCompat(of: topRowShare) { newValue in
            projectDocument.updateUIState { $0.topRowShare = Double(newValue) }
            captureMainWindowFrame()
        }
        .onChangeCompat(of: timelineViewModel.isExpanded) { newValue in
            projectDocument.updateUIState { $0.timelineExpanded = newValue }
        }
        // Reapply when a different project is opened.
        .onChangeCompat(of: projectDocument.fileURL) { _ in applySavedUIState() }
        // Size the player window to the media, so that if it is popped out it
        // arrives on the video's aspect rather than a fixed 640x360.
        //
        // It is no longer *shown* here: the video now appears inline in the
        // main window, and opening the separate window on import would pull the
        // picture straight back out of it.
        .onChangeWithPrevious(of: timelineManager.timeline.videoReels.count) { oldCount, newCount in
            if oldCount == 0 && newCount > 0 {
                // Only when the project has no player layout of its own. A saved
                // frame is a size the user chose - matching the media is a
                // sensible default, not something to impose over that.
                if projectDocument.uiState.playerWindowFrame == nil,
                   let reel = timelineManager.timeline.videoReels.first {
                    Task { await sizePlayerToReel(reel) }
                }
            }
        }
        .simultaneousGesture(
            TapGesture().onEnded {
                dismissTimecodeEditing()
            }
        )
        .onChangeCompat(of: audioManager.mappedOutputs) { outputs in
            guard !outputs.isEmpty else { return }
            let lanes = timelineManager.timeline.audioLanes
            var didAssign = false
            for (index, lane) in lanes.enumerated()
            where lane.outputMappingId == nil && !lane.isOutputDisabled {
                let output = outputs[min(index, outputs.count - 1)]
                timelineManager.setLaneOutputMapping(id: lane.id, mapping: output)
                didAssign = true
            }
            if didAssign {
                syncTimelineToPlaybackEngine()
            }
        }
        // Sync to PlaybackEngine when lane output mappings change (e.g., from dropdown)
        .onChangeCompat(of: timelineManager.timeline.audioLanes.map { LaneOutputState(id: $0.id, mappingId: $0.outputMappingId, offset: $0.outputChannelOffset, count: $0.outputChannelCount) }) { _ in
            syncTimelineToPlaybackEngine()
        }
    }

    // MARK: - Right Panel Section (Settings + Timeline + Media)

    // MARK: - Top Row

    /// Video on the left, Media on the right, both exactly the row's height so
    /// their bottom edges line up without either being derived from the other.
    ///
    /// Neither column measures itself: both are handed a size by
    /// `SectionLayout`, which is what keeps their bottoms level at every window
    /// size rather than only at the one the constants were tuned for.
    private func topRow(_ sections: SectionSizes) -> some View {
        HStack(alignment: .top, spacing: SectionLayout.gap) {
            videoColumn(sections)

            // Absorbs its own overflow. The optimization banner comes and goes;
            // letting that resize the row moved the video with it and broke the
            // alignment.
            shortPanelsColumn
                .frame(width: sections.media.width, height: sections.media.height)
        }
        .frame(width: sections.topRow.width, height: sections.topRow.height, alignment: .leading)
    }

    // MARK: - Video Column

    /// The picture with its controls directly beneath, as tall as the top row.
    ///
    /// No gap between them: the controls used to sit *inside* the video box and
    /// cost it 40pt, and then sat below it behind a 12pt gap. Both came out of
    /// the picture, which is the one thing here that benefits from the space.
    ///
    /// The width comes from the height, not the other way round - see rule 3 of
    /// the section authority - so the column is exactly 16:9 plus its controls
    /// strip at every window size and the picture never letterboxes inside it.
    private func videoColumn(_ sections: SectionSizes) -> some View {
        InlineVideoArea(
            playbackEngine: playbackEngine,
            midiSyncViewModel: midiSyncViewModel,
            settings: settings,
            playerWindow: PlayerWindowController.shared,
            onDropURLs: { urls in handlePlaybackAreaDrop(urls: urls) },
            onDropProviders: { providers in mediaImportCoordinator.handleDrop(providers: providers) },
            onInstallCodec: {
                alerts.show(.proVideoFormatsInstall(
                    codecName: playbackEngine.unplayableCodecName ?? "this format"
                ))
            }
        )
        // Controls are now overlaid on video, so use full height for picture
        .frame(width: sections.video.width, height: sections.video.height)
        // One surface for picture and controls, so the column has a visible
        // bottom edge level with the Media panel beside it. Both columns have
        // always measured the same rectangle (global maxY 633 for each); what
        // differed was how the edge was drawn - a hard-clipped fill against a
        // 1pt stroke reads as a point out at the rounded corner. Stroking this
        // the same way the panels do makes the two edges render identically.
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: PanelLayout.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: PanelLayout.cornerRadius)
                .stroke(Color.white.opacity(PanelLayout.borderOpacity),
                        lineWidth: PanelLayout.borderWidth)
        )
    }

    // MARK: - Section Splitter

    /// The boundary between the top row and the timeline.
    ///
    /// Lives in the gap between the two sections, which is the only honest place
    /// for it: the window's height is fixed while dragging, so whatever the
    /// timeline gains the top row gives up, and the edge under the cursor is the
    /// one that moves. It used to sit along the timeline's bottom edge, where it
    /// worked only because the drag resized the *window* rather than the split.
    ///
    /// Stores a share, not a height - rule 2 - so the balance survives the next
    /// window resize instead of being overwritten by it.
    private func sectionSplitter(_ sections: SectionSizes) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: SectionLayout.gap)
            .contentShape(Rectangle())
            .overlay {
                if isDraggingSplitter {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(height: 2)
                }
            }
            .accessibilityLabel("Resize timeline")
            .onHover { hovering in
                guard !isDraggingSplitter else { return }
                if hovering, !isHoveringSplitter {
                    NSCursor.resizeUpDown.push()
                    isHoveringSplitter = true
                } else if !hovering, isHoveringSplitter {
                    NSCursor.pop()
                    isHoveringSplitter = false
                }
            }
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        if !isDraggingSplitter {
                            splitterDragStartHeight = sections.topRow.height
                            splitterDragStartLocationY = value.startLocation.y
                            isDraggingSplitter = true
                            if !isHoveringSplitter {
                                NSCursor.resizeUpDown.push()
                                didPushSplitterCursor = true
                            } else {
                                didPushSplitterCursor = false
                            }
                        }
                        let delta = value.location.y - splitterDragStartLocationY
                        topRowShare = SectionLayout.share(
                            forTopRowHeight: splitterDragStartHeight + delta,
                            in: sections.everything.height
                        )
                    }
                    .onEnded { _ in
                        isDraggingSplitter = false
                        if didPushSplitterCursor {
                            NSCursor.pop()
                        }
                        didPushSplitterCursor = false
                    }
            )
    }

    // MARK: - Top Row Panels (Settings + Media)

    /// The two short panels, stacked beside the video.
    ///
    /// Both are headers most of the time - Settings is collapsed by default and
    /// Media is a single row of thumbnails - so they fit the video column's
    /// height rather than needing a row of their own.
    private var shortPanelsColumn: some View {
        VStack(spacing: Spacing.md) {
            // Settings used to sit here as a third accordion. It is an overlay
            // now, opened from the gear in the video controls - app
            // configuration rather than part of the project, and as a panel it
            // competed for height with the media it sat above.
            if showFileManager {
                FileManagerView(
                    mediaLibrary: mediaLibrary,
                    projectDocument: projectDocument,
                    timelineManager: timelineManager,
                    onAddToVideoTrack: handleAddToVideoTrack,
                    onAddToAudioLane: handleAddToAudioLane,
                    onDeleteItems: handleDeleteMediaItems,
                    onSaveProject: {
                        showSaveProjectSheetViaCoordinator()
                    }
                )
            }
        }
    }

    // MARK: - Timeline Row

    /// The timeline, across the full width of the window.
    private func timelinePanel(_ sections: SectionSizes) -> some View {
        TimelineAccordionView(
            timelineManager: timelineManager,
            playbackEngine: playbackEngine,
            waveformCache: waveformCache,
            audioOutputManager: audioManager,
            timelineViewModel: timelineViewModel,
            mediaLibrary: mediaLibrary,
            midiSyncViewModel: midiSyncViewModel,
            thumbnailCache: thumbnailCache,
            onDropVideoMedia: handleVideoDropOnTimeline,
            onDropAudioMedia: handleAudioDropOnTimeline,
            onSeek: { frame in playbackEngine.seekToFrame(frame) },
            onSettingsPressed: { alerts.show(.settings(content: AnyView(EmptyView()))) },
            onReportBugPressed: { presentBugReport() },
            onAddAudioLane: {
                let laneNumber = timelineManager.timeline.audioLanes.count + 1
                _ = timelineManager.addAudioLane(name: "Audio \(laneNumber)")
                timelineViewModel.expandIfNeeded()
            },
            onDropMixedMedia: { videoURLs, audioURLs, atFrame in
                handleMixedBatchDrop(videoURLs: videoURLs, audioURLs: audioURLs, atFrame: atFrame)
            },
            onExportCueList: { handleExportCueList() },
            height: sections.timeline.height
        )
        .onChangeCompat(of: mediaLibrary.items.count) { newCount in
            // Auto-expand timeline when media is first imported
            if newCount > 0 && !timelineViewModel.isExpanded {
                timelineViewModel.expandIfNeeded()
            }
        }
    }

    // MARK: - Audio Lane Preset Application

    // MARK: - Bug Reporting

    /// Opens the bug report sheet with a freshly built view model.
    func presentBugReport() {
        // Guarded so the menu command cannot stack a second sheet on top of one
        // the user already has open.
        guard !showBugReport else { return }
        bugReportViewModel = BugReportViewModel(gatherSnapshot: makeDiagnosticSnapshot)
        showBugReport = true
    }

    /// Reads the app's current state for the diagnostic report.
    ///
    /// Deliberately counts rather than contents for the timeline: how many reels
    /// and clips there are diagnoses layout and playback bugs, while the cue
    /// names and timings would say more about the user's unreleased project than
    /// about the app. Media paths are the exception - a missing-media or
    /// permissions bug is unreadable without them - and the sheet shows the user
    /// those paths before anything is sent.
    private func makeDiagnosticSnapshot() -> DiagnosticSnapshot {
        let info = Bundle.main.infoDictionary
        let timeline = timelineManager.timeline
        let processInfo = ProcessInfo.processInfo

        return DiagnosticSnapshot(
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "unknown",
            appBuild: info?["CFBundleVersion"] as? String ?? "unknown",
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
            osVersion: processInfo.operatingSystemVersionString,
            hardwareModel: SystemFacts.hardwareModel,
            architecture: SystemFacts.architecture,
            physicalMemoryGB: Double(processInfo.physicalMemory) / DiagnosticUnits.bytesPerGigabyte,
            uptime: Date().timeIntervalSince(SystemFacts.launchDate),
            audioOutputs: audioManager.mappedOutputs.map {
                "\($0.name) — channel start \($0.channelStart), count \($0.channelCount)"
            },
            midiInputs: midiSyncViewModel.availableInputs,
            selectedMIDIInput: midiSyncViewModel.selectedInputName,
            midiSyncState: String(describing: midiSyncViewModel.mtcState),
            projectPath: projectDocument.fileURL?.path,
            hasUnsavedChanges: projectDocument.hasUnsavedChanges,
            videoReelCount: timeline.videoReels.count,
            audioLaneCount: timeline.audioLanes.count,
            audioClipCount: timeline.audioLanes.reduce(0) { $0 + $1.clips.count },
            timelineFrameRate: String(describing: timeline.config.frameRate),
            timelineDurationFrames: timeline.config.durationFrames,
            mediaPaths: mediaLibrary.items.map { $0.url.path }
        )
    }

    // MARK: - Sheet Content (Extracted for Type Checker)

    private func onboardingSheetContent() -> OnboardingView {
        OnboardingView(
            audioManager: audioManager,
            onComplete: { showOnboarding = false }
        )
    }
}

#Preview {
    ContentView()
}
