import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import SwiftTimecodeCore
import AppKit
import Combine


/// Captures the enclosing NSScrollView for the panel stack, so its scroll
/// offset can be inspected and driven directly.
private struct PanelScrollCapture: NSViewRepresentable {
    @Binding var scrollView: NSScrollView?

    func makeNSView(context: Context) -> NSView {
        let v = Finder()
        v.onFound = { found in DispatchQueue.main.async { self.scrollView = found } }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private class Finder: NSView {
        var onFound: ((NSScrollView?) -> Void)?
        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                var v: NSView? = self?.superview
                while let cur = v {
                    if let sv = cur as? NSScrollView { self?.onFound?(sv); return }
                    v = cur.superview
                }
                self?.onFound?(nil)
            }
        }
    }
}

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

    // MARK: - UI State
    // Note: Some properties use internal access to allow extension in ContentView+Timeline.swift and ContentView+Setup.swift
    @State private var showWelcomeOverlay = false
    @State var isLoadingMedia = false
    @State var midiCancellables = Set<AnyCancellable>()
    @StateObject var thumbnailCache = ThumbnailCache()
    @State var showFileManager = true
    @State var didHandleUITestImport = false
    @State var uiTestImportState: String? = "boot"

    // Resizable accordion heights (media panel only - timeline handled by TimelineViewModel)
    @State private var mediaHeight: CGFloat = 200

    // Playback window resizing (internal for ContentView+Helpers.swift extension)
    @State var playbackHeight: CGFloat?
    @State var playbackMeasuredHeight: CGFloat = 0
    @State private var isResizingPlayback = false
    @State var normalViewHeight: CGFloat = 0

    /// Measured height the scrollable panel stack wants, used to size the window.
    @State var panelsContentHeight: CGFloat = 0
    /// The panel stack's scroll view. Internal, not private: the window sizing
    /// authority in ContentView+Helpers normalizes its offset.
    @State var panelsScrollView: NSScrollView?

    /// Whether the panel stack is allowed to scroll. Driven by the window
    /// sizing authority - see rule 6 in ContentView+Helpers.
    @State var panelsCanScroll = false

    /// How many runloop passes to wait for the window to exist before giving up
    /// on applying the default size.
    static let windowLookupAttempts = 20
    @State var videoAreaHeight: CGFloat = 0

    // Settings panel state (collapsed by default).
    // Internal, not private: ContentView+Helpers restores it from the project.

    // FPS conflict state (internal for ContentView+Timeline.swift extension)
    @State var pendingVideoURL: URL?
    @State var pendingVideoFPS: TimecodeFrameRate?
    @State var pendingVideoInsertFrame: Int?
    @State var videoInsertURL: URL?
    @State var videoAlreadyInTimelineName: String = ""
    @State var audioAlreadyInTimelineName: String = ""

    // Embedded timecode detection state (internal for ContentView+Timeline.swift extension)
    @State var pendingTimecodeResult: EmbeddedTimecodeResult?
    @State var pendingTimecodeURL: URL?
    @State var pendingTimecodeDropFrame: Int?
    @State var pendingTimecodeIsVideo = true
    @State var pendingTimecodeLaneId: UUID?

    // Batch timecode detection state (for multiple file drops)
    @State var pendingBatchTimecode: PendingBatchTimecode?

    /// Audio lanes reserved for files in an in-flight batch drop.
    ///
    /// Empty lanes look available to anything scanning for a free lane, so a
    /// video's embedded-audio import would otherwise claim a lane earmarked for
    /// one of the batch's audio files. Cleared once the batch is placed.
    @State var reservedAudioLaneIds: Set<UUID> = []

    /// Lanes created by an in-flight batch drop, so they can be removed again if
    /// the user cancels the confirmation sheet.
    @State var batchCreatedLaneIds: Set<UUID> = []

    // Spot media sheet state (for single file drops with enhanced placement options)
    @State var pendingSpotURL: URL?
    @State var pendingSpotFilenameTC: String?
    @State var pendingSpotMetadataTC: EmbeddedTimecodeResult?
    @State var pendingSpotDropFrame: Int = 0
    @State var pendingSpotIsVideo: Bool = true
    @State var pendingSpotLaneId: UUID?

    /// User's remembered spot placement choice for the session (nil = ask each time)
    @State var rememberedSpotChoice: SpotPlacementOption?

    /// Flag to prevent concurrent timecode detection from multiple drop events
    @State var isProcessingTimecodeDetection = false

    /// Whether timecode detection is actively scanning files, as opposed to
    /// waiting on the user in one of the placement sheets.
    ///
    /// `isProcessingTimecodeDetection` stays true for the whole drop flow -
    /// including while a sheet is up - so it can't drive the loading overlay on
    /// its own without dimming the sheet the user is trying to read.
    var isDetectingTimecode: Bool {
        isProcessingTimecodeDetection
            && !isShowingBatchTimecodeSheet
            && !isShowingEmbeddedTimecodeAlert
            && !isShowingSpotMediaSheet
    }

    /// Service for detecting embedded timecode from media files
    let embeddedTimecodeService = EmbeddedTimecodeService()

    // MARK: - Onboarding
    /// Shows the interactive onboarding wizard
    @State private var showOnboarding = false

    var body: some View {
        mainContent
            .alertCoordinator(alerts)
            .sheet(isPresented: Binding(
                get: { alerts.activeAlert?.id == "settings" },
                set: { if !$0 { alerts.dismiss() } }
            )) {
                SettingsView(
                    audioManager: audioManager,
                    isPresented: Binding(
                        get: { alerts.activeAlert?.id == "settings" },
                        set: { if !$0 { alerts.dismiss() } }
                    )
                )
            }
            .sheet(isPresented: $showOnboarding, content: onboardingSheetContent)
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

            // Start transport actor (sets up PlaybackEngine callbacks)
            Task { await transportActor.start() }

            restoreSettings()
            handleUITestImportIfNeeded()
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
    }

    // MARK: - View Modes

    private var normalView: some View {
        // The player lives in its own window (PlayerWindowController), so the
        // main window is transport + panels only - no split.
        Group {
            // Video on the left, panels on the right, both anchored to the top.
            // The video keeps a fixed size as the window grows taller with added
            // lanes - the space beneath it is left empty rather than stretching
            // the picture or pushing the panels down.
            // Video and the two short panels share the top row; the timeline
            // gets its own full-width row beneath. It is the widest thing in the
            // app - MTC IN, Start TC, Duration and zoom in one header, over a
            // ruler - so giving it the whole window is what stops it competing
            // with the video column for room.
            ScrollView(.vertical) {
              VStack(spacing: Spacing.md) {
                topRow

                timelinePanel
              }
              .padding(Spacing.md)
              // Measure the whole content, not one column: this is what the
              // window sizes itself to.
              .background(
                  GeometryReader { proxy in
                      Color.clear
                          .onAppear { updatePanelsContentHeight(proxy.size.height) }
                          .onChange(of: proxy.size.height) { _, newValue in
                              updatePanelsContentHeight(newValue)
                          }
                  }
              )
              .background(PanelScrollCapture(scrollView: $panelsScrollView))
              .onChange(of: timelineViewModel.isExpanded) { _, _ in
                  syncWindowToContent()
              }
              .onChange(of: showFileManager) { _, _ in
                  syncWindowToContent()
              }
              // Outputs defined in Settings are the source of truth for
              // routing; lanes follow. See the audio routing authority in
              // TimelineManager.
              .onChange(of: audioManager.mappedOutputs) { _, outputs in
                  timelineManager.reconcileOutputMappings(with: outputs)
              }
            }
            .scrollDisabled(!panelsCanScroll)
            .scrollIndicators(panelsCanScroll ? .automatic : .hidden)
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
        // Persist layout changes as the user makes them.
        .onChange(of: normalViewHeight) { _, _ in captureMainWindowFrame() }
        .onChange(of: timelineViewModel.expandedHeight) { _, newValue in
            projectDocument.updateUIState { $0.timelineExpandedHeight = Double(newValue) }
        }
        .onChange(of: timelineViewModel.isExpanded) { _, newValue in
            projectDocument.updateUIState { $0.timelineExpanded = newValue }
        }
        // Fit the window to the panels whenever the timeline's height changes
        // (lanes added/removed, panel collapsed). Absolute target, grow-only.
        .onChange(of: timelineViewModel.expandedHeight) { _, _ in
            syncWindowToContent()
        }
        .onChange(of: timelineViewModel.isExpanded) { _, _ in
            syncWindowToContent()
        }
        // Reapply when a different project is opened.
        .onChange(of: projectDocument.fileURL) { _, _ in applySavedUIState() }
        // Size the player window to the media, so that if it is popped out it
        // arrives on the video's aspect rather than a fixed 640x360.
        //
        // It is no longer *shown* here: the video now appears inline in the
        // main window, and opening the separate window on import would pull the
        // picture straight back out of it.
        .onChange(of: timelineManager.timeline.videoReels.count) { oldCount, newCount in
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
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        DispatchQueue.main.async {
                            normalViewHeight = proxy.size.height
                        }
                    }
                    .onChange(of: proxy.size.height) { _, newValue in
                        if newValue != normalViewHeight {
                            DispatchQueue.main.async {
                                normalViewHeight = newValue
                            }
                        }
                    }
            }
        )
        .onChange(of: audioManager.mappedOutputs) { _, outputs in
            guard !outputs.isEmpty else { return }
            let lanes = timelineManager.timeline.audioLanes
            var didAssign = false
            for (index, lane) in lanes.enumerated() where lane.outputMappingId == nil {
                let output = outputs[min(index, outputs.count - 1)]
                timelineManager.setLaneOutputMapping(id: lane.id, mapping: output)
                didAssign = true
            }
            if didAssign {
                syncTimelineToPlaybackEngine()
            }
        }
        // Sync to PlaybackEngine when lane output mappings change (e.g., from dropdown)
        .onChange(of: timelineManager.timeline.audioLanes.map { LaneOutputState(id: $0.id, mappingId: $0.outputMappingId, offset: $0.outputChannelOffset, count: $0.outputChannelCount) }) { _, _ in
            syncTimelineToPlaybackEngine()
        }
    }

    // MARK: - Right Panel Section (Settings + Timeline + Media)

    // MARK: - Top Row

    /// Video on the left, Media on the right, both exactly the row's height so
    /// their bottom edges line up without either being derived from the other.
    private var topRow: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            videoColumn

            // Fixed height, absorbing its own overflow. The optimization banner
            // comes and goes; letting that resize the row moved the video with
            // it and broke the alignment.
            shortPanelsColumn
                .frame(minWidth: HorizontalLayoutConstants.minPanelWidth)
                .frame(height: MainWindowLayout.topRowHeight)
        }
    }

    // MARK: - Video Column

    /// The picture with its controls directly beneath, as tall as the top row.
    ///
    /// No gap between them: the controls used to sit *inside* the video box and
    /// cost it 40pt, and then sat below it behind a 12pt gap. Both came out of
    /// the picture, which is the one thing here that benefits from the space.
    private var videoColumn: some View {
        VStack(spacing: 0) {
            let video = InlineVideoArea(
                playbackEngine: playbackEngine,
                midiSyncViewModel: midiSyncViewModel,
                settings: settings,
                playerWindow: PlayerWindowController.shared,
                onDropURLs: { urls in handlePlaybackAreaDrop(urls: urls) },
                onDropProviders: { providers in mediaImportCoordinator.handleDrop(providers: providers) },
                onOpenSettings: { alerts.show(.settings(content: AnyView(EmptyView()))) }
            )
            video
            video.controlsSection
        }
        .frame(height: MainWindowLayout.topRowHeight)
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
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { updateVideoAreaHeight(proxy.size.height) }
                    .onChange(of: proxy.size.height) { _, newValue in
                        updateVideoAreaHeight(newValue)
                    }
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
    private var timelinePanel: some View {
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
            onSettingsPressed: { },
            onAddAudioLane: {
                let laneNumber = timelineManager.timeline.audioLanes.count + 1
                _ = timelineManager.addAudioLane(name: "Audio \(laneNumber)")
                timelineViewModel.expandIfNeeded()
            },
            onDropMixedMedia: { videoURLs, audioURLs, atFrame in
                handleMixedBatchDrop(videoURLs: videoURLs, audioURLs: audioURLs, atFrame: atFrame)
            }
        )
        .onChange(of: mediaLibrary.items.count) { oldCount, newCount in
            // Auto-expand timeline when media is first imported
            if newCount > 0 && !timelineViewModel.isExpanded {
                timelineViewModel.expandIfNeeded()
            }
        }
    }

    /// Record the video area's measured height and refit the window.
    ///
    /// The refit matters as much as the measurement: the video area settles a
    /// frame after the panels do, so the launch fit used to run while this was
    /// still 0 and sized the window as though the video were not there - about
    /// 160pt short, which is what put the media panel behind the window edge.
    private func updateVideoAreaHeight(_ height: CGFloat) {
        guard height > 0, abs(height - videoAreaHeight) > 1 else { return }
        videoAreaHeight = height
        DispatchQueue.main.async {
            syncWindowToContent()
        }
    }

    /// Record the panels' measured height and refit the window.
    ///
    /// Debounced by a 1pt threshold: SwiftUI republishes this during
    /// animations, and refitting on every frame would fight the animation.
    private func updatePanelsContentHeight(_ height: CGFloat) {
        guard height > 0, abs(height - panelsContentHeight) > 1 else { return }
        panelsContentHeight = height
        DispatchQueue.main.async {
            syncWindowToContent()
        }
    }

    // MARK: - Audio Lane Preset Application

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
