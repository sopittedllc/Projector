import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import SwiftTimecodeCore
import AppKit
import Iconoir
import Combine

private struct ProviderBox: @unchecked Sendable {
    let provider: NSItemProvider
}

/// Info about a missing file that needs to be located
struct MissingFileInfo: Identifiable {
    let id: UUID
    let originalPath: String
    let type: MissingFileType
    var newURL: URL?

    enum MissingFileType {
        case mediaItem
        case videoReel
        case audioClip(laneId: UUID)
    }
}

/// Helper for comparing lane output states in onChange observer
private struct LaneOutputState: Equatable {
    let id: UUID
    let mappingId: UUID?
    let offset: Int
    let count: Int
}

// MARK: - View Modifiers for Breaking Up Body Complexity

/// View modifier for applying all sheets
private struct SheetsModifier: ViewModifier {
    @Binding var showSettings: Bool
    @Binding var showVideoInsertSheet: Bool
    @Binding var showSaveProjectSheet: Bool
    let settingsView: AnyView
    let videoInsertSheet: AnyView
    let saveProjectSheet: AnyView

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showSettings) { settingsView }
            .sheet(isPresented: $showVideoInsertSheet) { videoInsertSheet }
            .sheet(isPresented: $showSaveProjectSheet) { saveProjectSheet }
    }
}

/// View modifier for applying all alerts
private struct AlertsModifier: ViewModifier {
    @Binding var showErrorAlert: Bool
    @Binding var showVideoAlreadyInTimelineAlert: Bool
    @Binding var showAudioAlreadyInTimelineAlert: Bool
    @Binding var showDuplicateMediaAlert: Bool
    @Binding var showMissingFilesAlert: Bool
    @Binding var showFPSConflictAlert: Bool

    let loadError: String?
    let videoAlreadyInTimelineName: String
    let audioAlreadyInTimelineName: String
    let duplicateMediaAlertMessage: String
    let missingFileMessage: String
    let fpsConflictMessage: String

    let onLocateMissingFile: () -> Void
    let onSkipMissingFile: () -> Void
    let onSkipAllMissingFiles: () -> Void
    let onChangeProjectFPS: () -> Void
    let onCancelFPSConflict: () -> Void

    func body(content: Content) -> some View {
        content
            .alert("Error Loading Video", isPresented: $showErrorAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(loadError ?? "Unknown error")
            }
            .alert("Already in Timeline", isPresented: $showVideoAlreadyInTimelineAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("\"\(videoAlreadyInTimelineName)\" is already on the timeline.")
            }
            .alert("Already in Timeline", isPresented: $showAudioAlreadyInTimelineAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("\"\(audioAlreadyInTimelineName)\" is already on the timeline.")
            }
            .alert("Already in Project", isPresented: $showDuplicateMediaAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(duplicateMediaAlertMessage)
            }
            .alert("Missing File", isPresented: $showMissingFilesAlert) {
                Button("Locate...") { onLocateMissingFile() }
                Button("Skip", role: .destructive) { onSkipMissingFile() }
                Button("Skip All", role: .destructive) { onSkipAllMissingFiles() }
            } message: {
                Text(missingFileMessage)
            }
            .alert("Frame Rate Mismatch", isPresented: $showFPSConflictAlert) {
                Button("Change Project FPS", role: .destructive) { onChangeProjectFPS() }
                Button("Cancel", role: .cancel) { onCancelFPSConflict() }
            } message: {
                Text(fpsConflictMessage)
            }
    }
}

/// Main application content view
struct ContentView: View {
    // MARK: - Managers
    @StateObject private var playbackEngine = PlaybackEngine()
    @StateObject private var timelineManager = TimelineManager()
    @StateObject private var mediaLibrary = ProjectMediaLibrary()
    @StateObject private var waveformCache = WaveformCache()
    @StateObject private var audioManager = AudioOutputManager()
    @StateObject private var projectDocument = ProjectDocument()
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var dragContext = DragContext()
    @Environment(\.undoManager) private var undoManager

    // MARK: - MIDI Sync (Actor-based for thread safety)
    /// The MIDI sync actor (logic layer) - handles MTC/MMC on dedicated context
    private let midiSyncActor: MIDISyncActor
    /// ViewModel bridging actor state to UI
    @StateObject private var midiSyncViewModel: MIDISyncViewModel

    // MARK: - Timeline ViewModel
    /// ViewModel for timeline UI state and interactions
    @StateObject private var timelineViewModel: TimelineViewModel

    // MARK: - Initialization

    init() {
        // Initialize MIDI sync actor and view model
        let actor = MIDISyncActor()
        self.midiSyncActor = actor
        self._midiSyncViewModel = StateObject(wrappedValue: MIDISyncViewModel(service: actor))

        // Initialize timeline manager and view model
        let manager = TimelineManager()
        self._timelineManager = StateObject(wrappedValue: manager)
        self._timelineViewModel = StateObject(wrappedValue: TimelineViewModel(manager: manager))
    }

    // MARK: - UI State
    @State private var showWelcomeOverlay = !AppSettings.shared.hasCompletedWelcome
    @State private var showSettings = false
    @State private var isLoadingMedia = false
    @State private var loadError: String?
    @State private var showErrorAlert = false
    @State private var midiCancellables = Set<AnyCancellable>()
    @StateObject private var thumbnailCache = ThumbnailCache()
    @State private var showFileManager = true
    @State private var isFullScreen = false
    @State private var didHandleUITestImport = false
    @State private var uiTestImportState: String? = "boot"

    // Resizable accordion heights (media panel only - timeline handled by TimelineViewModel)
    @State private var mediaHeight: CGFloat = 200

    // Playback window resizing
    @State private var playbackHeight: CGFloat?
    @State private var playbackMeasuredHeight: CGFloat = 0
    @State private var playbackDragStartHeight: CGFloat = 0
    @State private var playbackDragStartLocationY: CGFloat = 0
    @State private var isResizingPlayback = false
    @State private var isHoveringPlaybackResize = false
    @State private var didPushResizeCursorForDrag = false
    @State private var normalViewHeight: CGFloat = 0
    @State private var vitalControlsHeight: CGFloat = 0

    // Missing files state
    @State private var showMissingFilesAlert = false
    @State private var missingFiles: [MissingFileInfo] = []
    @State private var currentMissingFileIndex = 0

    // FPS conflict state
    @State private var showFPSConflictAlert = false
    @State private var pendingVideoURL: URL?
    @State private var pendingVideoFPS: TimecodeFrameRate?
    @State private var pendingVideoInsertFrame: Int?
    @State private var showVideoInsertSheet = false
    @State private var videoInsertURL: URL?
    @State private var videoInsertTimecodeText: String = ""
    @State private var videoInsertError: String?
    @State private var showVideoAlreadyInTimelineAlert = false
    @State private var videoAlreadyInTimelineName: String = ""
    @State private var showAudioAlreadyInTimelineAlert = false
    @State private var showSaveProjectSheet = false
    @State private var audioAlreadyInTimelineName: String = ""
    @State private var showDuplicateMediaAlert = false
    @State private var duplicateMediaNames: [String] = []
    @State private var isPlaybackDropTargeted = false

    var body: some View {
        mainContent
            .modifier(SheetsModifier(
                showSettings: $showSettings,
                showVideoInsertSheet: $showVideoInsertSheet,
                showSaveProjectSheet: $showSaveProjectSheet,
                settingsView: AnyView(SettingsView(
                    audioManager: audioManager,
                    isPresented: $showSettings
                )),
                videoInsertSheet: AnyView(videoInsertSheet),
                saveProjectSheet: AnyView(SaveProjectSheet(onSave: handleProjectSave))
            ))
            .modifier(AlertsModifier(
                showErrorAlert: $showErrorAlert,
                showVideoAlreadyInTimelineAlert: $showVideoAlreadyInTimelineAlert,
                showAudioAlreadyInTimelineAlert: $showAudioAlreadyInTimelineAlert,
                showDuplicateMediaAlert: $showDuplicateMediaAlert,
                showMissingFilesAlert: $showMissingFilesAlert,
                showFPSConflictAlert: $showFPSConflictAlert,
                loadError: loadError,
                videoAlreadyInTimelineName: videoAlreadyInTimelineName,
                audioAlreadyInTimelineName: audioAlreadyInTimelineName,
                duplicateMediaAlertMessage: duplicateMediaAlertMessage,
                missingFileMessage: missingFileMessage,
                fpsConflictMessage: fpsConflictMessage,
                onLocateMissingFile: locateMissingFile,
                onSkipMissingFile: skipMissingFile,
                onSkipAllMissingFiles: skipAllMissingFiles,
                onChangeProjectFPS: handleFPSConflictChangeProject,
                onCancelFPSConflict: {
                    pendingVideoURL = nil
                    pendingVideoFPS = nil
                    pendingVideoInsertFrame = nil
                }
            ))
            .frame(minWidth: 640, minHeight: 400)
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
            restoreSettings()
            handleUITestImportIfNeeded()
        }
        // Sync unsaved changes state with AppDelegate for quit confirmation
        .onReceive(projectDocument.$hasUnsavedChanges) { hasChanges in
            AppDelegate.hasUnsavedChanges = hasChanges
        }
        // Save handlers - selector-backed commands bypass AppKit's Save validation
        .onReceive(NotificationCenter.default.publisher(for: .saveProject)) { _ in
            saveProject()
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveProjectAs)) { _ in
            saveProjectAs()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openProjectFile)) { notification in
            debugPrint("ContentView: received openProjectFile notification")
            if let url = notification.object as? URL {
                debugPrint("ContentView: opening project from %@", url.path)
                openProject(from: url)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openProjectFromMenu)) { _ in
            showOpenProjectPanel()
        }
        // Note: .consolidateMedia notification is handled by FileManagerView
        .onOpenURL { url in
            debugPrint("ContentView.onOpenURL: %@", url.path)
            if url.pathExtension.lowercased() == "projector" {
                openProject(from: url)
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
                handleDrop(providers: providers)
            }
            .overlay {
                // Drop target overlay
                if isPlaybackDropTargeted {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.accentColor.opacity(0.15))
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 4]))
                        VStack(spacing: 12) {
                            Image(systemName: "arrow.down.doc.fill")
                                .font(.system(size: 48))
                                .foregroundColor(.accentColor)
                            Text("Drop media to import")
                                .font(.headline)
                                .foregroundColor(.accentColor)
                        }
                    }
                    .padding(8)
                }
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
                // Loading overlay
                if isLoadingMedia {
                    ZStack {
                        Color.black.opacity(0.5)

                        VStack(spacing: 16) {
                            ProgressView()
                                .scaleEffect(1.5)
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))

                            Text("Loading media...")
                                .font(.headline)
                                .foregroundColor(.white)
                        }
                        .padding(32)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color.black.opacity(0.7))
                        )
                    }
                }
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.clear)
                    .frame(height: 10)
                    .contentShape(Rectangle())
                    .overlay {
                        Rectangle()
                            .fill(isResizingPlayback ? Color.accentColor : Color.white.opacity(0.25))
                            .frame(height: 1)
                    }
                    .onHover { hovering in
                        guard !isResizingPlayback else { return }
                        if hovering, !isHoveringPlaybackResize {
                            NSCursor.resizeUpDown.push()
                            isHoveringPlaybackResize = true
                        } else if !hovering, isHoveringPlaybackResize {
                            NSCursor.pop()
                            isHoveringPlaybackResize = false
                        }
                    }
                    .gesture(
                        DragGesture(coordinateSpace: .global)
                            .onChanged { value in
                                if !isResizingPlayback {
                                    playbackDragStartHeight = playbackHeight ?? playbackMeasuredHeight
                                    playbackDragStartLocationY = value.startLocation.y
                                    isResizingPlayback = true
                                    if !isHoveringPlaybackResize {
                                        NSCursor.resizeUpDown.push()
                                        didPushResizeCursorForDrag = true
                                    } else {
                                        didPushResizeCursorForDrag = false
                                    }
                                }
                                let delta = value.location.y - playbackDragStartLocationY
                                let proposedHeight = playbackDragStartHeight + delta
                                playbackHeight = min(playbackMaxHeight, max(playbackMinHeight, proposedHeight))
                            }
                            .onEnded { _ in
                                isResizingPlayback = false
                                if didPushResizeCursorForDrag {
                                    NSCursor.pop()
                                }
                                didPushResizeCursorForDrag = false
                            }
                    )
            }
            .overlay(alignment: .bottomTrailing) {
                Button(action: { enterFullScreen() }) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .padding(10)
                        .background(
                            Circle()
                                .fill(Color.black.opacity(0.6))
                        )
                }
                .buttonStyle(.plain)
                .padding(20)
                .opacity(0.7)
                .help("Enter Full Screen")
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
                            onSaveProject: { saveProjectAs() }
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
        ZStack {
            // Black background
            Color.black.ignoresSafeArea()

            // Video player fills the screen
            // Add extra trailing padding when timecode is in bottom-right to avoid overlapping minimize button
            VideoContentViewForEngine(
                playbackEngine: playbackEngine,
                showTimecode: settings.showTimecodeOverlay,
                overlayPosition: settings.timecodeOverlayPosition,
                overlayOpacity: settings.timecodeOverlayOpacity,
                extraTrailingPadding: settings.timecodeOverlayPosition == .bottomRight ? 50 : 0
            )
            .onDrop(of: [UTType.fileURL, UTType.url], isTargeted: nil) { providers in
                handleDrop(providers: providers)
            }
            .ignoresSafeArea()

            // Minimize button in bottom right corner
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button(action: { exitFullScreen() }) {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white)
                            .padding(10)
                            .background(
                                Circle()
                                    .fill(Color.black.opacity(0.6))
                            )
                    }
                    .buttonStyle(.plain)
                    .padding(20)
                    .opacity(0.7)
                }
            }
        }
    }

    private var playbackMinHeight: CGFloat {
        200
    }

    private var lowerPanelsMinHeight: CGFloat {
        showFileManager ? 180 : 100
    }

    private func dismissTimecodeEditing() {
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    private var duplicateMediaAlertMessage: String {
        if duplicateMediaNames.count == 1, let name = duplicateMediaNames.first {
            return "\"\(name)\" is already in the project."
        }
        return "\(duplicateMediaNames.count) files are already in the project."
    }

    private var missingFileMessage: String {
        guard currentMissingFileIndex < missingFiles.count else { return "" }
        let file = missingFiles[currentMissingFileIndex]
        return "Cannot find file:\n\(file.originalPath)\n\nWould you like to locate it?"
    }

    private var fpsConflictMessage: String {
        guard let fps = pendingVideoFPS else { return "" }
        return "This video is \(fps.displayName) but the project is \(timelineManager.timeline.config.frameRate.displayName).\n\nChanging the project FPS will remove all existing video reels."
    }

    private var playbackMaxHeight: CGFloat {
        let reservedHeight = vitalControlsHeight + lowerPanelsMinHeight
        if normalViewHeight > 0 {
            return max(playbackMinHeight, normalViewHeight - reservedHeight)
        }
        if playbackMeasuredHeight > 0 {
            return max(playbackMinHeight, playbackMeasuredHeight)
        }
        return CGFloat.greatestFiniteMagnitude
    }

    private func clampPlaybackHeightIfNeeded() {
        guard let height = playbackHeight else { return }
        let clamped = min(playbackMaxHeight, max(playbackMinHeight, height))
        if clamped != height {
            playbackHeight = clamped
        }
    }

    private func enterFullScreen() {
        guard let window = NSApp.keyWindow else { return }
        isFullScreen = true
        window.toggleFullScreen(nil)
    }

    private func exitFullScreen() {
        guard let window = NSApp.keyWindow else { return }
        isFullScreen = false
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
    }

    // MARK: - Save Operations

    private func saveProject() {
        if projectDocument.fileURL != nil {
            do {
                try projectDocument.save()
            } catch {
                loadError = error.localizedDescription
                showErrorAlert = true
            }
        } else {
            saveProjectAs()
        }
    }

    private func saveProjectAs() {
        showSaveProjectSheet = true
    }

    /// Handle the save callback from SaveProjectSheet
    private func handleProjectSave(to url: URL) {
        do {
            try projectDocument.save(to: url)
        } catch {
            loadError = error.localizedDescription
            showErrorAlert = true
        }
    }

    private func showOpenProjectPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.projectorProject]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Open Project"

        if panel.runModal() == .OK, let url = panel.url {
            openProject(from: url)
        }
    }

    private func consolidateMedia() {
        guard let projectURL = projectDocument.fileURL else {
            // Project must be saved first
            let alert = NSAlert()
            alert.messageText = "Save Project First"
            alert.informativeText = "Please save your project before consolidating media. This allows media files to be copied into the project folder."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        // Check if there are external files to consolidate
        let externalItems = mediaLibrary.externalMediaItems(projectURL: projectURL)
        if externalItems.isEmpty {
            let alert = NSAlert()
            alert.messageText = "No External Media"
            alert.informativeText = "All media files are already stored within the project folder."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        // Confirm consolidation
        let alert = NSAlert()
        alert.messageText = "Consolidate Media"
        alert.informativeText = "This will copy \(externalItems.count) external media file(s) into the project folder. The original files will not be modified."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Consolidate")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Perform consolidation
        Task {
            let result = await mediaLibrary.consolidateMedia(projectURL: projectURL)

            // Show result
            let resultAlert = NSAlert()
            if result.failedCount == 0 {
                resultAlert.messageText = "Consolidation Complete"
                resultAlert.informativeText = "Copied \(result.copiedCount) file(s) to project folder.\n\(result.skippedCount) file(s) were already local."
                resultAlert.alertStyle = .informational
            } else {
                resultAlert.messageText = "Consolidation Completed with Errors"
                resultAlert.informativeText = "Copied \(result.copiedCount) file(s).\nFailed: \(result.failedCount)\n\nErrors:\n\(result.errors.joined(separator: "\n"))"
                resultAlert.alertStyle = .warning
            }
            resultAlert.addButton(withTitle: "OK")
            resultAlert.runModal()

            // Save project to persist the updated paths
            if result.copiedCount > 0 {
                syncMediaLibraryToDocument()
                saveProject()
            }
        }
    }

    private func openProject(from url: URL) {
        do {
            try projectDocument.load(from: url)

            // Restore timeline and media library
            timelineManager.timeline = projectDocument.timeline
            mediaLibrary.load(items: projectDocument.mediaLibrary)

            // Sync to playback engine
            syncTimelineToPlaybackEngine()

            // Check for missing files - if any are found, don't load reels yet
            // (the alert handlers will call loadProjectReels when done)
            if !checkForMissingFiles() {
                // No missing files, load reels immediately
                loadProjectReels()
            }

            debugPrint("openProject: loaded timeline with \(projectDocument.timeline.videoReels.count) reels")
        } catch {
            loadError = error.localizedDescription
            showErrorAlert = true
        }
    }

    /// Load the video reels after project is opened (and missing files resolved)
    private func loadProjectReels() {
        if let firstReel = timelineManager.timeline.sortedVideoReels.first {
            Task {
                do {
                    try await playbackEngine.loadReel(firstReel)

                    // Prime thumbnail cache for all reels
                    for reel in timelineManager.timeline.videoReels {
                        await generateThumbnail(for: reel)
                    }
                } catch {
                    loadError = error.localizedDescription
                    showErrorAlert = true
                }
            }
        }
    }

    // MARK: - Missing File Handling

    /// Check for missing files and show alert if any are found
    /// Returns true if missing files were found (and alert will be shown)
    @discardableResult
    private func checkForMissingFiles() -> Bool {
        var missing: [MissingFileInfo] = []

        // Check media library items
        for item in mediaLibrary.items {
            if !FileManager.default.fileExists(atPath: item.url.path) {
                missing.append(MissingFileInfo(
                    id: item.id,
                    originalPath: item.url.path,
                    type: .mediaItem
                ))
            }
        }

        // Check video reels
        for reel in timelineManager.timeline.videoReels {
            if !FileManager.default.fileExists(atPath: reel.sourceURL.path) {
                missing.append(MissingFileInfo(
                    id: reel.id,
                    originalPath: reel.sourceURL.path,
                    type: .videoReel
                ))
            }
        }

        // Check audio clips
        for lane in timelineManager.timeline.audioLanes {
            for clip in lane.clips {
                if !FileManager.default.fileExists(atPath: clip.sourceURL.path) {
                    missing.append(MissingFileInfo(
                        id: clip.id,
                        originalPath: clip.sourceURL.path,
                        type: .audioClip(laneId: lane.id)
                    ))
                }
            }
        }

        if !missing.isEmpty {
            missingFiles = missing
            currentMissingFileIndex = 0
            showMissingFilesAlert = true
            return true
        }
        return false
    }

    private func locateMissingFile() {
        guard currentMissingFileIndex < missingFiles.count else { return }
        let info = missingFiles[currentMissingFileIndex]

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Locate Missing File"
        panel.message = "Please locate: \(URL(fileURLWithPath: info.originalPath).lastPathComponent)"

        if panel.runModal() == .OK, let newURL = panel.url {
            // Check if we should offer to copy to project folder
            var finalURL = newURL
            if let projectURL = projectDocument.fileURL,
               !newURL.path.hasPrefix(projectURL.path) {
                // File is external - offer to consolidate
                let consolidateAlert = NSAlert()
                consolidateAlert.messageText = "Copy to Project Folder?"
                consolidateAlert.informativeText = "Would you like to copy this file into the project folder? This ensures the project remains portable."
                consolidateAlert.addButton(withTitle: "Copy to Project")
                consolidateAlert.addButton(withTitle: "Keep External Reference")

                if consolidateAlert.runModal() == .alertFirstButtonReturn {
                    // Copy the file to project Media folder
                    if let copiedURL = copyFileToProject(sourceURL: newURL, projectURL: projectURL) {
                        finalURL = copiedURL
                    }
                }
            }

            // Update the reference
            switch info.type {
            case .mediaItem:
                mediaLibrary.updateItemURL(id: info.id, newURL: finalURL)
            case .videoReel:
                timelineManager.updateVideoReelURL(id: info.id, newURL: finalURL)
            case .audioClip(let laneId):
                timelineManager.updateAudioClipURL(clipId: info.id, inLane: laneId, newURL: finalURL)
            }
            projectDocument.markDirty()
        }

        // Move to next missing file
        currentMissingFileIndex += 1
        if currentMissingFileIndex < missingFiles.count {
            showMissingFilesAlert = true
        } else {
            // All missing files handled, now load reels
            missingFiles = []
            loadProjectReels()
        }
    }

    /// Copy a file to the project's Media folder
    private func copyFileToProject(sourceURL: URL, projectURL: URL) -> URL? {
        let mediaFolder = projectURL.appendingPathComponent("Media")
        let fileManager = FileManager.default

        // Create Media folder if needed
        if !fileManager.fileExists(atPath: mediaFolder.path) {
            do {
                try fileManager.createDirectory(at: mediaFolder, withIntermediateDirectories: true)
            } catch {
                debugPrint("Failed to create Media folder: \(error)")
                return nil
            }
        }

        // Determine destination (handle duplicates)
        let originalName = sourceURL.lastPathComponent
        var destinationURL = mediaFolder.appendingPathComponent(originalName)
        var counter = 1

        while fileManager.fileExists(atPath: destinationURL.path) {
            let nameWithoutExt = sourceURL.deletingPathExtension().lastPathComponent
            let ext = sourceURL.pathExtension
            destinationURL = mediaFolder.appendingPathComponent("\(nameWithoutExt)_\(counter).\(ext)")
            counter += 1
        }

        do {
            // Start security-scoped access
            let didStartAccess = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if didStartAccess {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            debugPrint("Copied missing file to project: \(destinationURL.lastPathComponent)")
            return destinationURL
        } catch {
            debugPrint("Failed to copy file to project: \(error)")
            return nil
        }
    }

    private func skipMissingFile() {
        guard currentMissingFileIndex < missingFiles.count else { return }
        let info = missingFiles[currentMissingFileIndex]

        // Remove the missing item
        switch info.type {
        case .mediaItem:
            mediaLibrary.removeItem(id: info.id)
        case .videoReel:
            timelineManager.removeVideoReel(id: info.id)
        case .audioClip(let laneId):
            timelineManager.removeAudioClip(clipId: info.id, fromLane: laneId)
        }
        projectDocument.markDirty()

        // Move to next missing file
        currentMissingFileIndex += 1
        if currentMissingFileIndex < missingFiles.count {
            showMissingFilesAlert = true
        } else {
            // All missing files handled, now load reels
            missingFiles = []
            loadProjectReels()
        }
    }

    private func skipAllMissingFiles() {
        // Remove all remaining missing items
        for i in currentMissingFileIndex..<missingFiles.count {
            let info = missingFiles[i]
            switch info.type {
            case .mediaItem:
                mediaLibrary.removeItem(id: info.id)
            case .videoReel:
                timelineManager.removeVideoReel(id: info.id)
            case .audioClip(let laneId):
                timelineManager.removeAudioClip(clipId: info.id, fromLane: laneId)
            }
        }
        projectDocument.markDirty()
        missingFiles = []
        // All missing files handled, now load reels
        loadProjectReels()
    }

    // MARK: - Setup

    private func setupMIDICallbacks() {
        // Start the MIDI sync actor
        Task {
            do {
                try await midiSyncActor.start()

                // Restore MIDI input selection
                if !settings.selectedMIDIInput.isEmpty {
                    await midiSyncViewModel.selectInput(settings.selectedMIDIInput)
                }
            } catch {
                print("Failed to start MIDI sync: \(error)")
            }
        }

        // Observe MTC timecode changes for video sync
        // Uses Combine to react to ViewModel's published properties
        midiSyncViewModel.$mtcTimecode
            .compactMap { $0 }
            .sink { [weak playbackEngine] timecode in
                guard let engine = playbackEngine else { return }

                // Calculate drift from current position
                let currentSeconds = engine.currentTime
                let mtcSeconds = Double(timecode.frameCount.wholeFrames) / engine.frameRate.fps
                let driftFrames = abs(currentSeconds - mtcSeconds) * engine.frameRate.fps

                // Re-sync if drift exceeds threshold (handles both playback drift and scrubbing)
                if driftFrames > Double(AppSettings.shared.syncDriftThreshold) {
                    print("MTC sync: drift=\(Int(driftFrames)) frames, seeking to \(timecode.stringValue())")
                    engine.seekToMTC(timecode)
                }
            }
            .store(in: &midiCancellables)

        // Observe MMC transport commands
        midiSyncViewModel.$lastMMCCommand
            .compactMap { $0 }
            .sink { [weak playbackEngine] command in
                guard AppSettings.shared.respondToMMC else { return }
                guard let engine = playbackEngine else { return }

                switch command {
                case .stop:
                    engine.stop()
                case .play, .deferredPlay:
                    engine.play()
                case .pause:
                    engine.pause()
                case .locate(let timecode):
                    engine.seekToTimecode(timecode)
                case .fastForward, .rewind:
                    break
                }
            }
            .store(in: &midiCancellables)
    }

    private func setupAudioCallback() {
        let engine = playbackEngine

        audioManager.onDeviceChanged = { deviceUID in
            Task { @MainActor in
                engine.setAudioOutputDevice(deviceUID)
            }
        }

        // Restore audio device selection
        if !settings.selectedAudioOutput.isEmpty {
            audioManager.selectedDeviceUID = settings.selectedAudioOutput
        }
    }

    private func setupTimelineCallbacks() {
        // Sync timeline changes to playback engine and document
        let engine = playbackEngine
        let document = projectDocument
        let manager = timelineManager
        let library = mediaLibrary

        timelineManager.onTimelineChanged = {
            engine.timeline = manager.timeline
            document.timeline = manager.timeline
        }

        // Sync media library changes to document
        mediaLibrary.onLibraryChanged = {
            document.mediaLibrary = library.exportItems()
        }
    }

    private func restoreSettings() {
        // Apply audio device
        if !settings.selectedAudioOutput.isEmpty {
            playbackEngine.setAudioOutputDevice(settings.selectedAudioOutput)
        }
    }

    private func handleUITestImportIfNeeded() {
        guard !didHandleUITestImport else { return }

        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-ui-testing") else { return }
        guard let url = uiTestAudioURL(from: arguments) else { return }

        didHandleUITestImport = true
        uiTestImportState = "starting"
        timelineViewModel.isExpanded = true

        Task { @MainActor in
            // Ensure at least one audio lane exists.
            let lane: AudioLane
            if let existingLane = timelineManager.timeline.audioLanes.first {
                lane = existingLane
            } else {
                lane = timelineManager.addAudioLane(name: "Audio 1")
            }

            do {
                let placementFrame = lane.clips.map { $0.timelineEndFrame }.max() ?? 0
                _ = try await timelineManager.addAudioClipForTesting(from: url, toLane: lane.id, at: placementFrame)
                syncTimelineToPlaybackEngine()
                uiTestImportState = "clip-added:\(uiTestClipCount)"
            } catch {
                debugPrint("UI test import failed: \(error)")
                uiTestImportState = "clip-error:\(String(describing: error))"
            }
            timelineViewModel.expandIfNeeded()
        }
    }

    private var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("-ui-testing")
    }

    private var uiTestClipCount: Int {
        timelineManager.timeline.audioLanes.reduce(0) { $0 + $1.clips.count }
    }

    private func uiTestAudioURL(from arguments: [String]) -> URL? {
        guard let index = arguments.firstIndex(of: "-test-audio-url"),
              arguments.indices.contains(index + 1) else {
            return createUITestAudioFile()
        }
        let url = URL(fileURLWithPath: arguments[index + 1])
        if FileManager.default.isReadableFile(atPath: url.path) {
            if (try? AVAudioFile(forReading: url)) != nil {
                return url
            }
        }
        return createUITestAudioFile()
    }

    private func createUITestAudioFile() -> URL? {
        let sampleRate: Double = 44_100
        let duration: Double = 1.0
        let frequency: Double = 440

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            return nil
        }

        let frameCount = AVAudioFrameCount(duration * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount

        let theta = 2.0 * Double.pi * frequency / sampleRate
        if let channel = buffer.floatChannelData?[0] {
            for frame in 0..<Int(frameCount) {
                channel[frame] = Float(sin(theta * Double(frame)))
            }
        }

        guard let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let url = cachesURL.appendingPathComponent("ProjectorUITest-\(UUID().uuidString).wav")

        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            return url
        } catch {
            return nil
        }
    }

    /// Sync timeline manager's timeline to project document
    private func syncTimelineToDocument() {
        projectDocument.timeline = timelineManager.timeline
    }

    /// Sync media library to project document
    private func syncMediaLibraryToDocument() {
        projectDocument.mediaLibrary = mediaLibrary.exportItems()
    }

    // MARK: - File Handling

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }

        // Collect all URLs first, then process sequentially to avoid race conditions
        Task { @MainActor in
            var urls: [URL] = []

            // Load all URLs from providers
            for provider in providers {
                if let url = await loadURL(from: provider) {
                    urls.append(url)
                }
            }

            let supportedURLs = urls.filter { ProjectMediaLibrary.isSupported(url: $0) }
            let (newURLs, duplicateNames) = partitionDuplicateMediaURLs(supportedURLs)
            if !duplicateNames.isEmpty {
                duplicateMediaNames = duplicateNames
                showDuplicateMediaAlert = true
            }

            // Process each URL sequentially
            for url in newURLs {
                guard let mediaType = ProjectMediaLibrary.mediaType(for: url) else {
                    continue
                }

                switch mediaType {
                case .video:
                    await self.addVideoToTimeline(url: url, atFrame: nil)
                case .audio:
                    // Create a new audio lane for each audio file
                    let laneNumber = self.timelineManager.timeline.audioLanes.count + 1
                    let newLane = self.timelineManager.addAudioLane(name: "Audio \(laneNumber)")
                    _ = await self.addAudioToTimeline(url: url, laneId: newLane.id, atFrame: nil)
                }
            }

            // Auto-expand timeline after all files are processed
            if !urls.isEmpty {
                self.timelineViewModel.expandIfNeeded()
            }
        }

        return true
    }

    /// Helper to load URL from NSItemProvider
    private func loadURL(from provider: NSItemProvider) async -> URL? {
        let boxedProvider = ProviderBox(provider: provider)
        return await withCheckedContinuation { continuation in
            boxedProvider.provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                if let url = extractURL(from: item) {
                    continuation.resume(returning: url)
                    return
                }
                boxedProvider.provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                    continuation.resume(returning: extractURL(from: item))
                }
            }
        }
    }

    private func extractURL(from item: Any?) -> URL? {
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        if let url = item as? URL {
            return url
        }
        if let url = item as? NSURL {
            return url as URL
        }
        if let string = item as? String {
            return URL(string: string)
        }
        return nil
    }

    private func partitionDuplicateMediaURLs(_ urls: [URL]) -> ([URL], [String]) {
        let uniqueURLs = Array(Set(urls.map { $0.standardizedFileURL.resolvingSymlinksInPath() }))
        var duplicateNames: [String] = []
        var newURLs: [URL] = []

        for url in uniqueURLs {
            if let existing = mediaLibrary.existingItem(for: url) {
                duplicateNames.append(existing.displayName)
            } else {
                newURLs.append(url)
            }
        }

        return (newURLs, duplicateNames)
    }

    // MARK: - Timeline Media Handling

    /// Handle video files dropped on the timeline video track
    private func handleVideoDropOnTimeline(_ urls: [URL], _ atFrame: Int, _ isInternalDrag: Bool) {
        Task {
            for url in urls {
                await addVideoToTimeline(url: url, atFrame: atFrame)
            }
        }
    }

    /// Handle audio files dropped on a specific audio lane
    private func handleAudioDropOnTimeline(_ laneIndex: Int, _ urls: [URL], _ atFrame: Int, _ isInternalDrag: Bool) {
        Task {
            // Ensure the lane exists
            while timelineManager.timeline.audioLanes.count <= laneIndex {
                _ = timelineManager.addAudioLane()
            }

            let lane = timelineManager.timeline.audioLanes[laneIndex]
            var insertFrame = max(0, atFrame)

            for url in urls {
                let clip = await addAudioToTimeline(url: url, laneId: lane.id, atFrame: insertFrame)
                if let clip = clip {
                    insertFrame = clip.timelineEndFrame
                }
            }
        }
    }

    /// Handle media item double-clicked to add to video track
    private func handleAddToVideoTrack(_ item: MediaItem) {
        if timelineManager.timeline.videoReels.contains(where: { $0.sourceURL == item.url }) {
            videoAlreadyInTimelineName = item.displayName
            showVideoAlreadyInTimelineAlert = true
            return
        }

        videoInsertURL = item.url
        videoInsertTimecodeText = timelineManager.timeline.config.startTimecode.stringValue()
        videoInsertError = nil
        showVideoInsertSheet = true
    }

    /// Handle media item double-clicked to add to audio lane
    /// Creates a new audio lane and adds the audio there
    private func handleAddToAudioLane(_ item: MediaItem, _ laneIndex: Int) {
        if timelineManager.timeline.audioLanes.contains(where: { lane in
            lane.clips.contains(where: { $0.sourceURL == item.url })
        }) {
            audioAlreadyInTimelineName = item.displayName
            showAudioAlreadyInTimelineAlert = true
            return
        }

        Task {
            // Create a new audio lane for this audio file
            let laneNumber = timelineManager.timeline.audioLanes.count + 1
            let newLane = timelineManager.addAudioLane(name: "Audio \(laneNumber)")

            _ = await addAudioToTimeline(url: item.url, laneId: newLane.id, atFrame: 0)

            // Auto-expand timeline so user can see the new lane
            timelineViewModel.expandIfNeeded()
        }
    }

    private var videoInsertSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Place Video")
                .font(.system(size: 14, weight: .semibold))

            Text("Enter the timecode where the video should start.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            TextField("00:00:00:00", text: $videoInsertTimecodeText)
                .font(.system(size: 13, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .onChange(of: videoInsertTimecodeText) { _, newValue in
                    videoInsertTimecodeText = formatTimecodeInput(newValue)
                }

            if let error = videoInsertError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    clearVideoInsertPrompt()
                }
                Button("Place") {
                    confirmVideoInsert()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private func confirmVideoInsert() {
        guard let url = videoInsertURL else {
            clearVideoInsertPrompt()
            return
        }

        guard let timecode = parseTimecode(videoInsertTimecodeText, at: timelineManager.timeline.config.frameRate) else {
            videoInsertError = "Invalid timecode."
            return
        }

        let startFrames = timelineManager.timeline.config.startTimecode.frameCount.wholeFrames
        let targetFrame = max(0, timecode.frameCount.wholeFrames - startFrames)
        clearVideoInsertPrompt()

        Task {
            await addVideoToTimeline(url: url, atFrame: targetFrame)
        }
    }

    private func clearVideoInsertPrompt() {
        showVideoInsertSheet = false
        videoInsertURL = nil
        videoInsertError = nil
    }

    private func formatTimecodeInput(_ input: String) -> String {
        let digits = input.filter { $0.isNumber }
        let padded = String(repeating: "0", count: max(0, 8 - digits.count)) + digits
        let trimmed = String(padded.suffix(8))
        guard trimmed.count == 8 else { return "00:00:00:00" }

        let h = trimmed.prefix(2)
        let m = trimmed.dropFirst(2).prefix(2)
        let s = trimmed.dropFirst(4).prefix(2)
        let f = trimmed.dropFirst(6).prefix(2)
        return "\(h):\(m):\(s):\(f)"
    }

    private func parseTimecode(_ string: String, at frameRate: TimecodeFrameRate) -> Timecode? {
        let digits = string.filter { $0.isNumber }
        let padded = String(repeating: "0", count: max(0, 8 - digits.count)) + digits
        let trimmed = String(padded.suffix(8))
        guard trimmed.count == 8 else { return nil }

        let h = Int(trimmed.prefix(2)) ?? 0
        let m = Int(trimmed.dropFirst(2).prefix(2)) ?? 0
        let s = Int(trimmed.dropFirst(4).prefix(2)) ?? 0
        let f = Int(trimmed.dropFirst(6).prefix(2)) ?? 0

        return Timecode(.components(h: h, m: m, s: s, f: f), at: frameRate, by: .clamping)
    }

    /// Remove media items from the project and register undo.
    private func handleDeleteMediaItems(_ items: [MediaItem]) {
        guard !items.isEmpty else { return }

        let previousTimeline = timelineManager.timeline
        let previousItems = mediaLibrary.exportItems()
        let reelsToPrewarm = previousTimeline.videoReels

        undoManager?.registerUndo(withTarget: timelineManager) { _ in
            timelineManager.timeline = previousTimeline
            mediaLibrary.load(items: previousItems)
            syncTimelineToPlaybackEngine()
            for reel in reelsToPrewarm {
                thumbnailCache.prewarm(for: reel)
            }
        }
        undoManager?.setActionName(items.count == 1 ? "Remove Media Item" : "Remove Media Items")

        for item in items {
            removeMediaItem(item)
        }
    }

    /// Remove a media item from the project and clean up timeline references.
    private func removeMediaItem(_ item: MediaItem) {
        // Remove any video reels that reference this item.
        let reelsToRemove = timelineManager.timeline.videoReels.filter { $0.sourceURL == item.url }
        for reel in reelsToRemove {
            timelineManager.removeVideoReel(id: reel.id)
            thumbnailCache.remove(reelId: reel.id)
        }

        // Remove any audio clips that reference this item.
        for lane in timelineManager.timeline.audioLanes {
            let clipsToRemove = lane.clips.filter { $0.sourceURL == item.url }
            for clip in clipsToRemove {
                waveformCache.cancelGeneration(for: clip.id)
                waveformCache.removeCachedWaveform(for: clip.id)
                timelineManager.removeAudioClip(clipId: clip.id, fromLane: lane.id)
            }
        }

        mediaLibrary.removeItem(id: item.id)
    }

    /// Add a video file to the timeline
    private func addVideoToTimeline(url: URL, atFrame: Int?) async {
        isLoadingMedia = true

        do {
            // Detect video frame rate and duration first
            let asset = AVAsset(url: url)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let videoTrack = videoTracks.first else {
                throw NSError(domain: "Projector", code: 1, userInfo: [NSLocalizedDescriptionKey: "No video track found"])
            }

            let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
            let videoFPS = closestTimecodeFrameRate(to: Double(nominalFrameRate))
            let duration = try await asset.load(.duration)
            let videoDurationFrames = Int(duration.seconds * videoFPS.fps)

            // Check for FPS conflict
            let hasExistingReels = !timelineManager.timeline.videoReels.isEmpty
            let projectFPS = timelineManager.timeline.config.frameRate

            if hasExistingReels && videoFPS != projectFPS {
                // FPS conflict - show dialog
                isLoadingMedia = false
                pendingVideoURL = url
                pendingVideoFPS = videoFPS
                pendingVideoInsertFrame = atFrame
                showFPSConflictAlert = true
                return
            }

            // If first video, set project FPS to match
            if !hasExistingReels {
                var config = timelineManager.timeline.config
                config.frameRate = videoFPS
                config.startTimecode = Timecode(.frames(config.startTimecode.frameCount.wholeFrames), at: videoFPS, by: .clamping)
                config.endTimecode = Timecode(.frames(config.endTimecode.frameCount.wholeFrames), at: videoFPS, by: .clamping)
                timelineManager.updateConfig(config)
            }

            // Calculate placement frame, avoiding overlaps with existing reels
            var placementFrame = atFrame ?? (timelineManager.timeline.videoReels.map { $0.timelineEndFrame }.max() ?? 0)
            placementFrame = findNonOverlappingPosition(
                startFrame: placementFrame,
                durationFrames: videoDurationFrames,
                existingReels: timelineManager.timeline.videoReels
            )

            await addVideoToTimelineUnchecked(url: url, at: placementFrame)

        } catch {
            isLoadingMedia = false
            loadError = error.localizedDescription
            showErrorAlert = true
        }
    }

    /// Find a position for a new video that doesn't overlap with existing reels
    /// If the proposed position overlaps, places it immediately after the overlapping reel
    private func findNonOverlappingPosition(startFrame: Int, durationFrames: Int, existingReels: [VideoReel]) -> Int {
        var proposedStart = startFrame
        let proposedEnd = proposedStart + durationFrames

        // Sort reels by start frame
        let sortedReels = existingReels.sorted { $0.timelineStartFrame < $1.timelineStartFrame }

        // Check for overlaps and adjust position
        for reel in sortedReels {
            let reelStart = reel.timelineStartFrame
            let reelEnd = reel.timelineEndFrame

            // Check if proposed position overlaps with this reel
            if proposedStart < reelEnd && proposedEnd > reelStart {
                // Overlap detected - move to immediately after this reel
                proposedStart = reelEnd
                debugPrint("findNonOverlappingPosition: Overlap with '\(reel.displayName)', moving to frame \(proposedStart)")
            }
        }

        return proposedStart
    }

    /// Add video without FPS checking (internal use after conflict resolution)
    private func addVideoToTimelineUnchecked(url: URL, at timelineFrame: Int) async {
        let t0 = CFAbsoluteTimeGetCurrent()
        func elapsed() -> String { String(format: "%.3fs", CFAbsoluteTimeGetCurrent() - t0) }

        debugPrint("addVideoToTimeline: ENTRY [T+\(elapsed())] - \(url.lastPathComponent)")

        do {
            // Import to media library first (if not already there)
            let mediaItem = try await mediaLibrary.importFile(from: url)
            debugPrint("addVideoToTimeline: Media library import done [T+\(elapsed())]")

            // Add the video reel with reference to the media item
            let reel = try await timelineManager.addVideoReel(from: url, at: timelineFrame, mediaItemId: mediaItem.id)
            debugPrint("addVideoToTimeline: Reel added [T+\(elapsed())]")

            // CRITICAL: Sync timeline and load reel IMMEDIATELY for instant playback
            // Don't block on thumbnail generation or audio extraction
            syncTimelineToPlaybackEngine()
            debugPrint("addVideoToTimeline: Timeline synced [T+\(elapsed())]")

            // If this is the first reel, load it right away
            if timelineManager.timeline.videoReels.count == 1 {
                try await playbackEngine.loadReel(reel)
                debugPrint("addVideoToTimeline: Reel loaded in playback engine [T+\(elapsed())]")
            }

            // Check for audio tracks and create lane + placeholder clip IMMEDIATELY
            // This ensures the audio region appears in UI right away, before extraction completes
            let audioResult = await prepareAudioLaneIfNeeded(for: reel)
            debugPrint("addVideoToTimeline: Audio lane + clip prepared [T+\(elapsed())]")

            isLoadingMedia = false
            debugPrint("addVideoToTimeline: READY FOR PLAYBACK [T+\(elapsed())]")

            // Generate thumbnail in background (non-blocking)
            let thumbnailCacheRef = thumbnailCache
            Task(priority: .utility) {
                thumbnailCacheRef.prewarm(for: reel)
            }

            // Extract audio in background and update the placeholder clip with extractedAudioURL
            if let (lane, clipId) = audioResult {
                Task(priority: .utility) {
                    await self.extractAudioInBackground(reel: reel, laneId: lane.id, clipId: clipId)
                }
            }
        } catch {
            debugPrint("addVideoToTimeline: FAILED [T+\(elapsed())] - \(error)")
            isLoadingMedia = false
            loadError = error.localizedDescription
            showErrorAlert = true
        }
    }

    /// Handle user choosing to change project FPS (removes existing reels)
    private func handleFPSConflictChangeProject() {
        guard let url = pendingVideoURL, let fps = pendingVideoFPS else { return }

        // Remove all existing video reels
        for reel in timelineManager.timeline.videoReels {
            timelineManager.removeVideoReel(id: reel.id)
            thumbnailCache.remove(reelId: reel.id)
        }

        // Update project FPS
        var config = timelineManager.timeline.config
        config.frameRate = fps
        config.startTimecode = Timecode(.frames(config.startTimecode.frameCount.wholeFrames), at: fps, by: .clamping)
        config.endTimecode = Timecode(.frames(config.endTimecode.frameCount.wholeFrames), at: fps, by: .clamping)
        timelineManager.updateConfig(config)

        // Clear pending state
        pendingVideoURL = nil
        pendingVideoFPS = nil
        let insertFrame = pendingVideoInsertFrame
        pendingVideoInsertFrame = nil

        // Now add the video
        Task {
            let placementFrame = insertFrame ?? 0
            await addVideoToTimelineUnchecked(url: url, at: placementFrame)
        }
    }

    /// Convert video frame rate to closest TimecodeFrameRate
    private func closestTimecodeFrameRate(to fps: Double) -> TimecodeFrameRate {
        // Common frame rates and their nominal values
        let rates: [(TimecodeFrameRate, Double)] = [
            (.fps23_976, 23.976),
            (.fps24, 24.0),
            (.fps25, 25.0),
            (.fps29_97, 29.97),
            (.fps30, 30.0),
        ]

        var closest = TimecodeFrameRate.fps24
        var minDiff = Double.infinity

        for (rate, nominal) in rates {
            let diff = abs(fps - nominal)
            if diff < minDiff {
                minDiff = diff
                closest = rate
            }
        }

        return closest
    }

    /// Check if video has audio tracks and create lane + placeholder clip immediately
    /// Returns (lane, clipId) if audio tracks exist, nil otherwise
    /// Reuses existing lanes if the new clip fits without overlap
    private func prepareAudioLaneIfNeeded(for reel: VideoReel) async -> (lane: AudioLane, clipId: UUID)? {
        let asset = AVAsset(url: reel.sourceURL)
        do {
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard !audioTracks.isEmpty else {
                debugPrint("prepareAudioLaneIfNeeded: No audio tracks found")
                return nil
            }

            // Get channel count and sample rate from audio format
            let audioTrack = audioTracks[0]
            let formatDescriptions = try await audioTrack.load(.formatDescriptions)
            var channelCount = 2
            var sampleRate: Double = 48000

            if let formatDesc = formatDescriptions.first {
                let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
                if let format = asbd?.pointee {
                    channelCount = Int(format.mChannelsPerFrame)
                    sampleRate = format.mSampleRate
                }
            }

            // Create a placeholder clip IMMEDIATELY (without extractedAudioURL)
            // This ensures the audio region appears in UI right away, before extraction completes
            let clip = AudioClip(
                mediaItemId: reel.mediaItemId,
                sourceURL: reel.sourceURL,
                sourceBookmark: reel.sourceBookmark,
                timelineStartFrame: reel.timelineStartFrame,
                durationFrames: reel.durationFrames,
                sourceStartFrame: reel.sourceStartFrame,
                sourceType: .videoTrack,
                sourceTrackIndex: 0,
                channelCount: channelCount,
                sampleRate: sampleRate,
                extractedAudioURL: nil,  // Will be set after extraction
                sourceFrameRate: reel.sourceFrameRate
            )

            // Try to find an existing lane where the clip fits without overlap
            var targetLane: AudioLane?
            for lane in timelineManager.timeline.audioLanes {
                if !lane.hasOverlap(with: clip) {
                    targetLane = lane
                    debugPrint("prepareAudioLaneIfNeeded: Found existing lane '\(lane.name)' with no overlap")
                    break
                }
            }

            // If no existing lane can fit the clip, create a new one
            if targetLane == nil {
                let laneNumber = timelineManager.timeline.audioLanes.count + 1
                targetLane = timelineManager.addAudioLaneAtTop(name: "Audio \(laneNumber)")
                debugPrint("prepareAudioLaneIfNeeded: Created new lane '\(targetLane!.name)'")
            }

            guard let lane = targetLane else {
                debugPrint("prepareAudioLaneIfNeeded: Failed to get target lane")
                return nil
            }

            timelineManager.timeline.addClip(clip, toLane: lane.id)

            debugPrint("prepareAudioLaneIfNeeded: Added clip to lane '\(lane.name)' with \(audioTracks.count) audio track(s)")
            return (lane, clip.id)
        } catch {
            debugPrint("prepareAudioLaneIfNeeded: Failed to check audio tracks - \(error)")
            return nil
        }
    }

    /// Extract audio from video reel in background and update existing clip
    private func extractAudioInBackground(reel: VideoReel, laneId: UUID, clipId: UUID) async {
        let t0 = CFAbsoluteTimeGetCurrent()
        func elapsed() -> String { String(format: "%.3fs", CFAbsoluteTimeGetCurrent() - t0) }

        debugPrint("extractAudioInBackground: ENTRY [T+\(elapsed())] - \(reel.displayName)")

        let asset = AVAsset(url: reel.sourceURL)
        do {
            // Do the slow extraction
            let extractedURL = try await extractAudioTrackToTemp(from: asset, trackIndex: 0, sourceURL: reel.sourceURL)
            debugPrint("extractAudioInBackground: Export complete [T+\(elapsed())] -> \(extractedURL.lastPathComponent)")

            // Update the existing clip with the extracted audio URL
            await MainActor.run {
                timelineManager.updateExtractedAudioURL(clipId: clipId, inLane: laneId, extractedURL: extractedURL)
            }
            debugPrint("extractAudioInBackground: COMPLETE [T+\(elapsed())]")
        } catch {
            debugPrint("extractAudioInBackground: FAILED [T+\(elapsed())] - \(error)")
        }
    }

    /// Extract an audio track from an asset to a temporary file
    /// Uses passthrough (no re-encoding) for speed
    /// Must be called while security-scoped access is active
    private func extractAudioTrackToTemp(from asset: AVAsset, trackIndex: Int, sourceURL: URL) async throws -> URL {
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard trackIndex < audioTracks.count else {
            throw NSError(domain: "ContentView", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid audio track index"])
        }

        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw NSError(domain: "ContentView", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to create composition track"])
        }

        let track = audioTracks[trackIndex]
        let duration = try await asset.load(.duration)
        try compositionTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: duration),
            of: track,
            at: .zero
        )

        // Use passthrough preset - copies audio stream without re-encoding (MUCH faster)
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw NSError(domain: "ContentView", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to create export session"])
        }

        // Deterministic filename based on source URL and track
        // Use .mov container for passthrough compatibility
        let keyHash = "\(sourceURL.absoluteString)-track\(trackIndex)".hashValue
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("projector-audio-\(abs(keyHash)).mov")

        if FileManager.default.fileExists(atPath: tempURL.path) {
            try FileManager.default.removeItem(at: tempURL)
        }

        if #available(macOS 15.0, *) {
            try await export.export(to: tempURL, as: .mov)
        } else {
            export.outputURL = tempURL
            export.outputFileType = .mov

            // Wrapper to make AVAssetExportSession usable in Sendable closure
            final class ExportBox: @unchecked Sendable {
                let session: AVAssetExportSession
                init(_ session: AVAssetExportSession) { self.session = session }
            }
            let exportBox = ExportBox(export)

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                exportBox.session.exportAsynchronously {
                    switch exportBox.session.status {
                    case .completed:
                        continuation.resume(returning: ())
                    case .failed:
                        continuation.resume(throwing: exportBox.session.error ?? NSError(domain: "ContentView", code: -4, userInfo: nil))
                    default:
                        continuation.resume(throwing: NSError(domain: "ContentView", code: -5, userInfo: nil))
                    }
                }
            }
        }

        return tempURL
    }

    /// Add an audio file to the timeline
    private func addAudioToTimeline(url: URL, laneId: UUID, atFrame: Int?) async -> AudioClip? {
        do {
            // Import to media library first (if not already there)
            _ = try await mediaLibrary.importFile(from: url)

            // Calculate where to place the new clip (at end of existing clips in lane)
            let lane = timelineManager.timeline.audioLanes.first { $0.id == laneId }
            let placementFrame = atFrame ?? (lane?.clips.map { $0.timelineEndFrame }.max() ?? 0)

            // Add the audio clip
            let clip = try await timelineManager.addAudioClip(from: url, toLane: laneId, at: placementFrame)

            // Sync timeline to playback engine
            syncTimelineToPlaybackEngine()
            return clip
        } catch {
            loadError = error.localizedDescription
            showErrorAlert = true
            return nil
        }
    }

    /// Prime thumbnail cache for a video reel.
    private func generateThumbnail(for reel: VideoReel) async {
        thumbnailCache.prewarm(for: reel)
    }

    /// Sync the timeline manager's timeline to the playback engine
    private func syncTimelineToPlaybackEngine() {
        playbackEngine.timeline = timelineManager.timeline
    }

    /// Called from menu File > Open Media
    func openMediaFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            .movie,
            .mpeg4Movie,
            .quickTimeMovie,
            .audio,
            .mp3,
            .wav,
            UTType(filenameExtension: "mov")!,
            UTType(filenameExtension: "mp4")!,
            UTType(filenameExtension: "m4v")!,
            UTType(filenameExtension: "aif")!,
            UTType(filenameExtension: "aiff")!
        ]

        panel.begin { response in
            if response == .OK {
                Task { @MainActor in
                    let urls = panel.urls.filter { ProjectMediaLibrary.isSupported(url: $0) }
                    let (newURLs, duplicateNames) = self.partitionDuplicateMediaURLs(urls)
                    if !duplicateNames.isEmpty {
                        self.duplicateMediaNames = duplicateNames
                        self.showDuplicateMediaAlert = true
                    }
                    for url in newURLs {
                        if let mediaType = ProjectMediaLibrary.mediaType(for: url) {
                            switch mediaType {
                            case .video:
                                await self.addVideoToTimeline(url: url, atFrame: nil)
                            case .audio:
                                // Create a new lane for each audio file
                                let laneNumber = self.timelineManager.timeline.audioLanes.count + 1
                                let newLane = self.timelineManager.addAudioLane(name: "Audio \(laneNumber)")
                                _ = await self.addAudioToTimeline(url: url, laneId: newLane.id, atFrame: nil)
                            }
                        }
                    }
                    // Auto-expand timeline
                    self.timelineViewModel.expandIfNeeded()
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
