import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import SwiftTimecodeCore
import AppKit
import Iconoir
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

        // Initialize timeline manager and view model
        let manager = TimelineManager()
        let viewModel = TimelineViewModel(manager: manager)
        self._timelineManager = StateObject(wrappedValue: manager)
        self._timelineViewModel = StateObject(wrappedValue: viewModel)

        // Initialize media library, project document, and playback engine
        let library = ProjectMediaLibrary()
        let document = ProjectDocument()
        let engine = PlaybackEngine()
        self._mediaLibrary = StateObject(wrappedValue: library)
        self._projectDocument = StateObject(wrappedValue: document)
        self._playbackEngine = StateObject(wrappedValue: engine)

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
            timelineViewModel: viewModel
        ))

        // Initialize persistence service
        self._persistenceService = StateObject(wrappedValue: ProjectPersistenceService(
            projectDocument: document,
            mediaLibrary: library,
            timelineManager: manager,
            playbackEngine: engine
        ))
    }

    // MARK: - License
    @StateObject private var licenseManager = LicenseManager.shared

    // MARK: - UI State
    // Note: Some properties use internal access to allow extension in ContentView+Timeline.swift and ContentView+Setup.swift
    @State private var showLicenseOverlay = false
    @State private var showWelcomeOverlay = false
    @State private var showSettings = false
    @State var isLoadingMedia = false
    @State var loadError: String?
    @State var showErrorAlert = false
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

    // FPS conflict state (internal for ContentView+Timeline.swift extension)
    @State var showFPSConflictAlert = false
    @State var pendingVideoURL: URL?
    @State var pendingVideoFPS: TimecodeFrameRate?
    @State var pendingVideoInsertFrame: Int?
    @State var showVideoInsertSheet = false
    @State var videoInsertURL: URL?
    @State var showVideoAlreadyInTimelineAlert = false
    @State var videoAlreadyInTimelineName: String = ""
    @State var showAudioAlreadyInTimelineAlert = false
    @State private var showSaveProjectSheet = false
    @State var audioAlreadyInTimelineName: String = ""
    @State private var isPlaybackDropTargeted = false

    // Embedded timecode detection state (internal for ContentView+Timeline.swift extension)
    @State var showEmbeddedTimecodeAlert = false
    @State var pendingTimecodeResult: EmbeddedTimecodeResult?
    @State var pendingTimecodeURL: URL?
    @State var pendingTimecodeDropFrame: Int?
    @State var pendingTimecodeIsVideo = true
    @State var pendingTimecodeLaneId: UUID?

    /// Service for detecting embedded timecode from media files
    let embeddedTimecodeService = EmbeddedTimecodeService()

    var body: some View {
        mainContent
            .modifier(SheetsModifier(
                showSettings: $showSettings,
                showVideoInsertSheet: $showVideoInsertSheet,
                showSaveProjectSheet: $showSaveProjectSheet,
                videoInsertURL: $videoInsertURL,
                frameRate: timelineManager.timeline.config.frameRate,
                startTimecode: timelineManager.timeline.config.startTimecode,
                onVideoInsertConfirm: { url, frame in
                    Task {
                        await addVideoToTimeline(url: url, atFrame: frame)
                    }
                },
                settingsView: AnyView(SettingsView(
                    audioManager: audioManager,
                    isPresented: $showSettings
                )),
                saveProjectSheet: AnyView(SaveProjectSheet(onSave: persistenceService.handleProjectSave))
            ))
            .modifier(AlertsModifier(
                showErrorAlert: $showErrorAlert,
                showVideoAlreadyInTimelineAlert: $showVideoAlreadyInTimelineAlert,
                showAudioAlreadyInTimelineAlert: $showAudioAlreadyInTimelineAlert,
                showDuplicateMediaAlert: $mediaImportCoordinator.showDuplicateMediaAlert,
                showMissingFilesAlert: $missingFileService.showAlert,
                showFPSConflictAlert: $showFPSConflictAlert,
                showEmbeddedTimecodeAlert: $showEmbeddedTimecodeAlert,
                loadError: loadError,
                videoAlreadyInTimelineName: videoAlreadyInTimelineName,
                audioAlreadyInTimelineName: audioAlreadyInTimelineName,
                duplicateMediaAlertMessage: mediaImportCoordinator.duplicateMediaAlertMessage,
                missingFileMessage: missingFileService.currentMissingFileMessage,
                fpsConflictMessage: fpsConflictMessage,
                embeddedTimecodeMessage: embeddedTimecodeMessage,
                embeddedTimecodeButtonLabel: embeddedTimecodeButtonLabel,
                onLocateMissingFile: { missingFileService.locateMissingFile() },
                onSkipMissingFile: { missingFileService.skipMissingFile() },
                onSkipAllMissingFiles: { missingFileService.skipAllMissingFiles() },
                onChangeProjectFPS: handleFPSConflictChangeProject,
                onCancelFPSConflict: {
                    pendingVideoURL = nil
                    pendingVideoFPS = nil
                    pendingVideoInsertFrame = nil
                },
                onPlaceAtTimecode: { handleTimecodeChoice(useEmbeddedTimecode: true) },
                onPlaceAtDropLocation: { handleTimecodeChoice(useEmbeddedTimecode: false) },
                onCancelTimecode: { clearPendingTimecode() }
            ))
            .frame(minWidth: 640, minHeight: 400)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WindowGlassBackground())
        .overlay {
            if showLicenseOverlay {
                LicenseOverlayView(isPresented: $showLicenseOverlay)
            }
        }
        .overlay {
            if showWelcomeOverlay && !showLicenseOverlay {
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
            restoreSettings()
            handleUITestImportIfNeeded()
            setupPersistenceServiceCallbacks()
            setupMediaImportCoordinatorCallbacks()

            // Check license status
            if !licenseManager.isLicensed {
                showLicenseOverlay = true
            }

            // Show welcome overlay if user hasn't completed it (and is licensed)
            if !AppSettings.shared.hasCompletedWelcome && !showLicenseOverlay {
                showWelcomeOverlay = true
            }
        }
        // Update license overlay when license status changes
        .onChange(of: licenseManager.isLicensed) { _, isLicensed in
            if isLicensed {
                showLicenseOverlay = false
                // Show welcome after license activation if not completed
                if !AppSettings.shared.hasCompletedWelcome {
                    showWelcomeOverlay = true
                }
            }
        }
        // Sync unsaved changes state with AppDelegate for quit confirmation
        .onReceive(projectDocument.$hasUnsavedChanges) { hasChanges in
            AppDelegate.hasUnsavedChanges = hasChanges
        }
        // Save handlers - selector-backed commands bypass AppKit's Save validation
        .onReceive(NotificationCenter.default.publisher(for: .saveProject)) { _ in
            if !persistenceService.saveProject() {
                showSaveProjectSheet = true  // No file URL, show Save As
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveProjectAs)) { _ in
            showSaveProjectSheet = true
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
        VStack(spacing: 0) {
            // Video content area
            VideoContentViewForEngine(
                playbackEngine: playbackEngine,
                showTimecode: settings.showTimecodeOverlay,
                overlayPosition: settings.timecodeOverlayPosition,
                overlayOpacity: settings.timecodeOverlayOpacity,
                extraTrailingPadding: settings.timecodeOverlayPosition == .bottomRight ? 50 : 0
            )
            .onDrop(of: [UTType.fileURL, UTType.url], isTargeted: $isPlaybackDropTargeted) { providers in
                mediaImportCoordinator.handleDrop(providers: providers)
            }
            .overlay {
                DropTargetOverlay(isTargeted: $isPlaybackDropTargeted)
            }
            .animation(.easeInOut(duration: 0.15), value: isPlaybackDropTargeted)
            .frame(minWidth: 480, minHeight: 200)
            .frame(height: playbackHeight)
            .transaction { $0.animation = nil }
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear {
                            DispatchQueue.main.async {
                                playbackMeasuredHeight = proxy.size.height
                            }
                        }
                        .onChange(of: proxy.size.height) { _, newValue in
                            if !isResizingPlayback, newValue != playbackMeasuredHeight {
                                DispatchQueue.main.async {
                                    playbackMeasuredHeight = newValue
                                }
                            }
                        }
                }
            )
            .overlay {
                LoadingOverlay(isLoading: isLoadingMedia)
            }
            .overlay(alignment: .bottom) {
                PlaybackResizeHandle(
                    playbackHeight: $playbackHeight,
                    playbackMeasuredHeight: playbackMeasuredHeight,
                    minHeight: playbackMinHeight,
                    maxHeight: playbackMaxHeight,
                    isResizing: $isResizingPlayback
                )
            }
            .overlay(alignment: .bottomTrailing) {
                FullScreenToggleButton(isFullScreen: false, action: enterFullScreen)
            }

            // Vital Controls bar (always visible)
            VitalControlsBar(
                timelineManager: timelineManager,
                playbackEngine: playbackEngine,
                timelineViewModel: timelineViewModel,
                onSettingsPressed: { showSettings = true }
            )
            .padding(.horizontal, 16)
            .padding(.top, 8)
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
                                    clampPlaybackHeightIfNeeded()
                                }
                            }
                        }
                }
            )

            ScrollView(.vertical) {
                VStack(spacing: 0) {
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
                        onSettingsPressed: { showSettings = true },
                        onAddAudioLane: {
                            let laneNumber = timelineManager.timeline.audioLanes.count + 1
                            _ = timelineManager.addAudioLane(name: "Audio \(laneNumber)")
                            timelineViewModel.expandIfNeeded()
                        }
                    )
                    .padding(.horizontal, Spacing.lg)
                    .padding(.top, Spacing.sm)
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
                            onSaveProject: { showSaveProjectSheet = true }
                        )
                        .padding(.horizontal, Spacing.lg)
                        .padding(.top, Spacing.sm)
                        .padding(.bottom, Spacing.sm)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .frame(minHeight: lowerPanelsMinHeight)
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
                                clampPlaybackHeightIfNeeded()
                            }
                        }
                    }
            }
        )
        .onChange(of: showFileManager) { _, _ in
            clampPlaybackHeightIfNeeded()
        }
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

    private var fullScreenView: some View {
        FullScreenVideoView(
            playbackEngine: playbackEngine,
            settings: settings,
            mediaImportCoordinator: mediaImportCoordinator,
            onExitFullScreen: exitFullScreen
        )
    }
}

#Preview {
    ContentView()
}
