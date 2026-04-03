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

    // MARK: - UI State
    // Note: Some properties use internal access to allow extension in ContentView+Timeline.swift and ContentView+Setup.swift
    @State private var showWelcomeOverlay = false
    @State var isLoadingMedia = false
    @State var midiCancellables = Set<AnyCancellable>()
    @StateObject var thumbnailCache = ThumbnailCache()
    @State var showFileManager = true
    @State var isFullScreen = false
    @State var didHandleUITestImport = false
    @State var uiTestImportState: String? = "boot"

    // Resizable accordion heights (media panel only - timeline handled by TimelineViewModel)
    @State private var mediaHeight: CGFloat = 200

    // Playback window resizing (internal for ContentView+Helpers.swift extension)
    @State var playbackHeight: CGFloat?
    @State var playbackMeasuredHeight: CGFloat = 0
    @State private var isResizingPlayback = false
    @State var normalViewHeight: CGFloat = 0
    @State var vitalControlsHeight: CGFloat = 0

    // Floating video window state
    @State private var isVideoFloating = false

    // Settings panel state (collapsed by default)
    @State private var isSettingsExpanded = false

    // FPS conflict state (internal for ContentView+Timeline.swift extension)
    @State var pendingVideoURL: URL?
    @State var pendingVideoFPS: TimecodeFrameRate?
    @State var pendingVideoInsertFrame: Int?
    @State var videoInsertURL: URL?
    @State var videoAlreadyInTimelineName: String = ""
    @State var audioAlreadyInTimelineName: String = ""
    @State private var isPlaybackDropTargeted = false

    // Embedded timecode detection state (internal for ContentView+Timeline.swift extension)
    @State var pendingTimecodeResult: EmbeddedTimecodeResult?
    @State var pendingTimecodeURL: URL?
    @State var pendingTimecodeDropFrame: Int?
    @State var pendingTimecodeIsVideo = true
    @State var pendingTimecodeLaneId: UUID?

    // Batch timecode detection state (for multiple file drops)
    @State var pendingBatchTimecode: PendingBatchTimecode?

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

    /// Service for detecting embedded timecode from media files
    let embeddedTimecodeService = EmbeddedTimecodeService()

    // MARK: - Onboarding & Audio Routing
    /// Shows the interactive onboarding wizard
    @State private var showOnboarding = false
    /// Shows the audio routing configuration sheet
    @State private var showAudioRouting = false

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
            .sheet(isPresented: $showAudioRouting, content: audioRoutingSheetContent)
            .frame(minWidth: 1100, minHeight: 500)
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
            if !AppSettings.shared.hasCompletedWelcome {
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
        // Note: .consolidateMedia notification is handled by FileManagerView
        .onReceive(NotificationCenter.default.publisher(for: .showAudioRouting)) { _ in
            showAudioRouting = true
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
        // Listen for window full screen changes
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            isFullScreen = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            isFullScreen = true
        }
        // Escape key exits full screen
        .onKeyPress(.escape) {
            if isFullScreen {
                exitFullScreen()
                return .handled
            }
            return .ignored
        }
    }

    // MARK: - Main Content (extracted for type-checker performance)

    private var mainContent: some View {
        Group {
            if isFullScreen {
                fullScreenView
            } else {
                normalView
            }
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
        // Horizontal split: Video (left) | Controls + Panels (right)
        HSplitView {
            // Left: Video player section (in glass container)
            videoSection
                .frame(minWidth: HorizontalLayoutConstants.minVideoWidth)

            // Right: Transport bar (pinned) + Scrollable panels
            VStack(spacing: 0) {
                // Vital Controls bar - pinned at top
                VitalControlsBar(
                    timelineManager: timelineManager,
                    playbackEngine: playbackEngine,
                    timelineViewModel: timelineViewModel
                )
                .padding(.horizontal, Spacing.md)
                .padding(.top, Spacing.md)
                .padding(.bottom, Spacing.sm)
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear {
                                DispatchQueue.main.async {
                                    vitalControlsHeight = proxy.size.height
                                }
                            }
                            .onChange(of: proxy.size.height) { _, newValue in
                                if newValue != vitalControlsHeight {
                                    DispatchQueue.main.async {
                                        vitalControlsHeight = newValue
                                    }
                                }
                            }
                    }
                )

                // Scrollable panels section
                rightPanelSection
            }
            .frame(minWidth: HorizontalLayoutConstants.minPanelWidth)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environmentObject(dragContext)
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

    // MARK: - Video Section (Left Panel)

    private var videoSection: some View {
        ZStack {
            if isVideoFloating {
                // Placeholder when video is floating
                videoFloatingPlaceholder
            } else {
                // Embedded video player
                embeddedVideoPlayer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: PanelLayout.cornerRadius))
        .glassPanel()
        .padding(Spacing.md)
    }

    private var embeddedVideoPlayer: some View {
        VideoContentViewForEngine(
            playbackEngine: playbackEngine,
            showTimecode: settings.showTimecodeOverlay,
            overlayPosition: settings.timecodeOverlayPosition,
            overlayOpacity: 0.3,
            extraTrailingPadding: (settings.timecodeOverlayPosition == .bottomRight || settings.timecodeOverlayPosition == .bottomLeft) ? 80 : 0
        )
        .onDrop(of: [UTType.fileURL, UTType.url, UTType.projectorMediaItem], isTargeted: $isPlaybackDropTargeted) { providers in
            // Check for internal drag from media panel first
            if dragContext.isDragging && !dragContext.mediaItems.isEmpty {
                let urls = dragContext.mediaItems.map { $0.url }
                handlePlaybackAreaDrop(urls: urls)
                dragContext.end()
                return true
            }
            // Fall back to external drop handling
            return mediaImportCoordinator.handleDrop(providers: providers)
        }
        .overlay {
            DropTargetOverlay(isTargeted: $isPlaybackDropTargeted)
        }
        .animation(AppAnimations.quick, value: isPlaybackDropTargeted)
        .overlay {
            LoadingOverlay(isLoading: isLoadingMedia)
        }
        .overlay(alignment: .bottomTrailing) {
            // Video control buttons
            HStack(spacing: Spacing.sm) {
                // Float button
                Button(action: { floatVideoWindow() }) {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .frame(width: 32, height: 32)
                        .background(AppColors.overlayDarker)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("Float video in separate window")

                // Full screen button
                FullScreenToggleButton(isFullScreen: false, action: enterFullScreen)
            }
            .padding(Spacing.sm)
        }
    }

    private var videoFloatingPlaceholder: some View {
        VStack(spacing: Spacing.lg) {
            Image(systemName: "rectangle.portrait.and.arrow.right.fill")
                .font(.system(size: 48))
                .foregroundColor(AppColors.textTertiary)

            Text("Video is floating")
                .font(Typography.heading)
                .foregroundColor(AppColors.textSecondary)

            Text("The video is in a separate window")
                .font(Typography.caption)
                .foregroundColor(AppColors.textTertiary)

            Button("Return Video Here") {
                returnVideoFromFloat()
            }
            .buttonStyle(.borderedProminent)
            .tint(AppColors.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Right Panel Section (Settings + Timeline + Media)

    private var rightPanelSection: some View {
        ScrollView(.vertical) {
            VStack(spacing: Spacing.md) {
                // Collapsible Settings section (collapsed by default)
                SettingsAccordionView(
                    audioManager: audioManager,
                    isExpanded: $isSettingsExpanded
                )

                // Timeline accordion
                TimelineAccordionView(
                    timelineManager: timelineManager,
                    playbackEngine: playbackEngine,
                    waveformCache: waveformCache,
                    audioOutputManager: audioManager,
                    timelineViewModel: timelineViewModel,
                    mediaLibrary: mediaLibrary,
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
                .onChange(of: mediaLibrary.items.count) { _, newCount in
                    // Auto-expand timeline when media is first imported
                    if newCount > 0 && !timelineViewModel.isExpanded {
                        timelineViewModel.expandIfNeeded()
                    }
                }

                // File Manager panel
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
            .padding(Spacing.md)
        }
    }

    // MARK: - Floating Video Actions

    private func floatVideoWindow() {
        isVideoFloating = true
        FloatingVideoPanelController.shared.showPanel(
            playbackEngine: playbackEngine,
            settings: settings,
            onClose: {
                returnVideoFromFloat()
            }
        )
    }

    private func returnVideoFromFloat() {
        FloatingVideoPanelController.shared.closePanel()
        isVideoFloating = false
    }

    private var fullScreenView: some View {
        FullScreenVideoView(
            playbackEngine: playbackEngine,
            settings: settings,
            mediaImportCoordinator: mediaImportCoordinator,
            onExitFullScreen: exitFullScreen
        )
    }

    // MARK: - Audio Lane Preset Application

    // MARK: - Sheet Content (Extracted for Type Checker)

    private func onboardingSheetContent() -> OnboardingView {
        OnboardingView(
            audioManager: audioManager,
            onComplete: { showOnboarding = false }
        )
    }

    private func audioRoutingSheetContent() -> AudioRoutingSheet {
        AudioRoutingSheet(
            audioManager: audioManager,
            timelineManager: timelineManager,
            onApply: { preset, configs in
                applyAudioLanePreset(preset: preset, configs: configs)
            },
            onCancel: { }
        )
    }

    // MARK: - Audio Lane Preset Application

    /// Apply a lane preset configuration to the timeline
    private func applyAudioLanePreset(preset: LanePreset, configs: [LaneConfig]) {
        // Clear existing lanes if applying a preset
        let existingLanes = timelineManager.timeline.audioLanes
        for lane in existingLanes {
            timelineManager.removeAudioLane(id: lane.id)
        }

        // Create new lanes from preset config
        for config in configs {
            let lane = timelineManager.addAudioLane(name: config.name)

            // Map to output channels if available
            let outputIndex = config.channelStart / 2  // Stereo pairs
            if outputIndex < audioManager.mappedOutputs.count {
                timelineManager.setLaneOutputMapping(
                    id: lane.id,
                    mapping: audioManager.mappedOutputs[outputIndex]
                )
            }
        }

        // Sync changes
        syncTimelineToPlaybackEngine()
    }
}

#Preview {
    ContentView()
}
