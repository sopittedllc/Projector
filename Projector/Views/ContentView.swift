import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import SwiftTimecodeCore
import AppKit
import Iconoir
import Combine

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
    @State private var showSettings = false
    @State private var isDropTargeted = false
    @State private var isLoadingMedia = false
    @State private var loadError: String?
    @State private var showErrorAlert = false
    @State private var midiCancellables = Set<AnyCancellable>()
    @State private var videoThumbnails: [UUID: ThumbnailStrip] = [:]
    @State private var showFileManager = true
    @State private var isFullScreen = false
    @State private var didHandleUITestImport = false
    @State private var uiTestImportState: String? = "boot"

    // Resizable accordion heights (media panel only - timeline handled by TimelineViewModel)
    @State private var mediaHeight: CGFloat = 200

    // Missing files state
    @State private var showMissingFilesAlert = false
    @State private var missingFiles: [MissingFileInfo] = []
    @State private var currentMissingFileIndex = 0

    // FPS conflict state
    @State private var showFPSConflictAlert = false
    @State private var pendingVideoURL: URL?
    @State private var pendingVideoFPS: TimecodeFrameRate?

    var body: some View {
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
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(
                midiSync: midiSyncViewModel,
                audioManager: audioManager,
                timelineManager: timelineManager,
                isPresented: $showSettings
            )
        }
        .alert("Error Loading Video", isPresented: $showErrorAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(loadError ?? "Unknown error")
        }
        .alert("Missing File", isPresented: $showMissingFilesAlert) {
            Button("Locate...") {
                locateMissingFile()
            }
            Button("Skip", role: .destructive) {
                skipMissingFile()
            }
            Button("Skip All", role: .destructive) {
                skipAllMissingFiles()
            }
        } message: {
            if currentMissingFileIndex < missingFiles.count {
                let file = missingFiles[currentMissingFileIndex]
                Text("Cannot find file:\n\(file.originalPath)\n\nWould you like to locate it?")
            }
        }
        .alert("Frame Rate Mismatch", isPresented: $showFPSConflictAlert) {
            Button("Change Project FPS", role: .destructive) {
                handleFPSConflictChangeProject()
            }
            Button("Cancel", role: .cancel) {
                pendingVideoURL = nil
                pendingVideoFPS = nil
            }
        } message: {
            if let fps = pendingVideoFPS {
                Text("This video is \(fps.displayName) but the project is \(timelineManager.timeline.config.frameRate.displayName).\n\nChanging the project FPS will remove all existing video reels.")
            }
        }
        .frame(minWidth: 640, minHeight: 400)
        .background(
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow, alphaValue: 0.95)
        )
        .navigationTitle("")
        .background(WindowTitleConfigurator(
            title: projectDocument.displayName,
            isEdited: projectDocument.hasUnsavedChanges
        ))
        .onReceive(NotificationCenter.default.publisher(for: .videoFileSelected)) { notification in
            // Add dropped video to timeline
            if let url = notification.object as? URL {
                Task {
                    await addVideoToTimeline(url: url)
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
            NSLog(">>> ContentView: received openProjectFile notification")
            if let url = notification.object as? URL {
                NSLog(">>> ContentView: opening project from %@", url.path)
                openProject(from: url)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openProjectFromMenu)) { _ in
            showOpenProjectPanel()
        }
        .onOpenURL { url in
            NSLog(">>> ContentView.onOpenURL: %@", url.path)
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

    // MARK: - View Modes

    private var normalView: some View {
        VStack(spacing: 0) {
            // Video content area
            VideoContentViewForEngine(
                playbackEngine: playbackEngine,
                showTimecode: settings.showTimecodeOverlay,
                overlayPosition: settings.timecodeOverlayPosition,
                overlayOpacity: settings.timecodeOverlayOpacity
            )
            .frame(minWidth: 480, minHeight: 200)
            .transaction { $0.animation = nil }
            .overlay {
                // Drop target overlay
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.accentColor, lineWidth: 3)
                        .background(Color.accentColor.opacity(0.1))
                        .padding(8)
                }

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

            // Vital Controls bar (always visible)
            VitalControlsBar(
                timelineManager: timelineManager,
                playbackEngine: playbackEngine,
                timelineViewModel: timelineViewModel,
                onSettingsPressed: { showSettings = true },
                onFullScreenPressed: { enterFullScreen() }
            )
            .padding(.horizontal, 16)
            .padding(.top, 8)

            // Timeline accordion
            TimelineAccordionView(
                timelineManager: timelineManager,
                playbackEngine: playbackEngine,
                waveformCache: waveformCache,
                audioOutputManager: audioManager,
                timelineViewModel: timelineViewModel,
                thumbnails: videoThumbnails,
                onDropVideoMedia: handleVideoDropOnTimeline,
                onDropAudioMedia: handleAudioDropOnTimeline,
                onSeek: { frame in playbackEngine.seekToFrame(frame) },
                onSettingsPressed: { showSettings = true }
            )
            .padding(.horizontal, 16)
            .padding(.top, 4)
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
                    onAddToVideoTrack: handleAddToVideoTrack,
                    onAddToAudioLane: handleAddToAudioLane
                )
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
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
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.projectorProject]
        panel.nameFieldStringValue = "Untitled.projector"
        panel.title = "Save Project"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try projectDocument.save(to: url)
            } catch {
                loadError = error.localizedDescription
                showErrorAlert = true
            }
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

            NSLog(">>> openProject: loaded timeline with \(projectDocument.timeline.videoReels.count) reels")
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

                    // Generate thumbnails for all reels
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
            // Update the reference
            switch info.type {
            case .mediaItem:
                mediaLibrary.updateItemURL(id: info.id, newURL: newURL)
            case .videoReel:
                timelineManager.updateVideoReelURL(id: info.id, newURL: newURL)
            case .audioClip(let laneId):
                timelineManager.updateAudioClipURL(clipId: info.id, inLane: laneId, newURL: newURL)
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
                NSLog(">>> UI test import failed: \(error)")
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

            // Process each URL sequentially
            for url in urls {
                guard ProjectMediaLibrary.isSupported(url: url),
                      let mediaType = ProjectMediaLibrary.mediaType(for: url) else {
                    continue
                }

                switch mediaType {
                case .video:
                    await self.addVideoToTimeline(url: url)
                case .audio:
                    // Create a new audio lane for each audio file
                    let laneNumber = self.timelineManager.timeline.audioLanes.count + 1
                    let newLane = self.timelineManager.addAudioLane(name: "Audio \(laneNumber)")
                    await self.addAudioToTimeline(url: url, laneId: newLane.id)
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
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - Timeline Media Handling

    /// Handle video files dropped on the timeline video track
    private func handleVideoDropOnTimeline(_ urls: [URL]) {
        Task {
            for url in urls {
                await addVideoToTimeline(url: url)
            }
        }
    }

    /// Handle audio files dropped on a specific audio lane
    private func handleAudioDropOnTimeline(_ laneIndex: Int, _ urls: [URL]) {
        Task {
            // Ensure the lane exists
            while timelineManager.timeline.audioLanes.count <= laneIndex {
                _ = timelineManager.addAudioLane()
            }

            let lane = timelineManager.timeline.audioLanes[laneIndex]

            for url in urls {
                await addAudioToTimeline(url: url, laneId: lane.id)
            }
        }
    }

    /// Handle media item double-clicked to add to video track
    private func handleAddToVideoTrack(_ item: MediaItem) {
        Task {
            await addVideoToTimeline(url: item.url)
        }
    }

    /// Handle media item double-clicked to add to audio lane
    /// Creates a new audio lane and adds the audio there
    private func handleAddToAudioLane(_ item: MediaItem, _ laneIndex: Int) {
        Task {
            // Create a new audio lane for this audio file
            let laneNumber = timelineManager.timeline.audioLanes.count + 1
            let newLane = timelineManager.addAudioLane(name: "Audio \(laneNumber)")

            await addAudioToTimeline(url: item.url, laneId: newLane.id)

            // Auto-expand timeline so user can see the new lane
            timelineViewModel.expandIfNeeded()
        }
    }

    /// Add a video file to the timeline
    private func addVideoToTimeline(url: URL) async {
        isLoadingMedia = true

        do {
            // Detect video frame rate first
            let asset = AVAsset(url: url)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let videoTrack = videoTracks.first else {
                throw NSError(domain: "Projector", code: 1, userInfo: [NSLocalizedDescriptionKey: "No video track found"])
            }

            let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
            let videoFPS = closestTimecodeFrameRate(to: Double(nominalFrameRate))

            // Check for FPS conflict
            let hasExistingReels = !timelineManager.timeline.videoReels.isEmpty
            let projectFPS = timelineManager.timeline.config.frameRate

            if hasExistingReels && videoFPS != projectFPS {
                // FPS conflict - show dialog
                isLoadingMedia = false
                pendingVideoURL = url
                pendingVideoFPS = videoFPS
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

            // Actually add the video
            await addVideoToTimelineUnchecked(url: url)

        } catch {
            isLoadingMedia = false
            loadError = error.localizedDescription
            showErrorAlert = true
        }
    }

    /// Add video without FPS checking (internal use after conflict resolution)
    private func addVideoToTimelineUnchecked(url: URL) async {
        do {
            // Import to media library first (if not already there)
            _ = try await mediaLibrary.importFile(from: url)

            // Calculate where to place the new reel (at end of existing content)
            let placementFrame = timelineManager.timeline.videoReels.map { $0.timelineEndFrame }.max() ?? 0

            // Add the video reel
            let reel = try await timelineManager.addVideoReel(from: url, at: placementFrame)

            // Generate thumbnail
            await generateThumbnail(for: reel)

            // Auto-extract audio track from video and add to audio lane
            await extractAudioFromVideo(reel: reel)

            // Sync timeline to playback engine
            syncTimelineToPlaybackEngine()

            // If this is the first reel, load it
            if timelineManager.timeline.videoReels.count == 1 {
                try await playbackEngine.loadReel(reel)
            }

            isLoadingMedia = false
        } catch {
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
            videoThumbnails.removeValue(forKey: reel.id)
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

        // Now add the video
        Task {
            await addVideoToTimelineUnchecked(url: url)
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

    /// Extract audio track from video reel and add to audio lane
    private func extractAudioFromVideo(reel: VideoReel) async {
        // Check if video has audio tracks
        let asset = AVAsset(url: reel.sourceURL)
        do {
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard !audioTracks.isEmpty else { return }

            // Ensure we have at least one audio lane
            let lane: AudioLane
            if timelineManager.timeline.audioLanes.isEmpty {
                lane = timelineManager.addAudioLane(name: "Audio")
            } else {
                lane = timelineManager.timeline.audioLanes[0]
            }

            // Extract the first audio track
            _ = try await timelineManager.extractAudioFromReel(reel.id, trackIndex: 0, toLane: lane.id)
        } catch {
            NSLog(">>> Failed to extract audio from video: \(error)")
        }
    }

    /// Add an audio file to the timeline
    private func addAudioToTimeline(url: URL, laneId: UUID) async {
        do {
            // Import to media library first (if not already there)
            _ = try await mediaLibrary.importFile(from: url)

            // Calculate where to place the new clip (at end of existing clips in lane)
            let lane = timelineManager.timeline.audioLanes.first { $0.id == laneId }
            let placementFrame = lane?.clips.map { $0.timelineEndFrame }.max() ?? 0

            // Add the audio clip
            _ = try await timelineManager.addAudioClip(from: url, toLane: laneId, at: placementFrame)

            // Sync timeline to playback engine
            syncTimelineToPlaybackEngine()
        } catch {
            loadError = error.localizedDescription
            showErrorAlert = true
        }
    }

    /// Generate and cache thumbnail strip for a video reel
    /// Uses batch generation for speed - approximately 1 thumbnail per second
    private func generateThumbnail(for reel: VideoReel) async {
        let asset = AVAsset(url: reel.sourceURL)

        // Get video duration
        let duration: CMTime
        do {
            duration = try await asset.load(.duration)
        } catch {
            NSLog(">>> ContentView: Failed to load asset duration: \(error)")
            return
        }

        let durationSeconds = duration.seconds
        guard durationSeconds > 0 else { return }

        // Generate approximately 1 thumbnail per second for smooth coverage
        // Cap at 1000 thumbnails max to prevent memory issues
        let maxThumbnails = 1000
        let targetInterval = 1.0
        let actualInterval = max(targetInterval, durationSeconds / Double(maxThumbnails))

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 80, height: 45)  // Small for filmstrip
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        // Build times array
        var times: [NSValue] = []
        var currentTime: Double = 0.0
        while currentTime < durationSeconds {
            times.append(NSValue(time: CMTime(seconds: currentTime, preferredTimescale: 600)))
            currentTime += actualInterval
        }

        let startTime = Date()
        let totalCount = times.count
        NSLog(">>> generateThumbnail: generating \(totalCount) thumbnails for \(durationSeconds)s video")

        // Use actor to safely collect thumbnails from async callbacks
        let collector = ThumbnailCollector(sourceDuration: durationSeconds, interval: actualInterval)

        // Use batch generation - much faster than sequential
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var completedCount = 0
            let lock = NSLock()

            generator.generateCGImagesAsynchronously(forTimes: times) { requestedTime, cgImage, actualTime, result, error in
                if let cgImage = cgImage {
                    // Convert to JPEG (much smaller/faster than TIFF)
                    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                    if let tiffData = nsImage.tiffRepresentation,
                       let bitmap = NSBitmapImageRep(data: tiffData),
                       let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) {
                        collector.add(time: requestedTime.seconds, data: jpegData)
                    }
                }

                // Track completion
                lock.lock()
                completedCount += 1
                let done = completedCount >= totalCount
                lock.unlock()

                if done {
                    Task { @MainActor in
                        let elapsed = Date().timeIntervalSince(startTime)
                        let strip = collector.buildStrip()
                        NSLog(">>> generateThumbnail: completed \(strip.count) thumbnails in \(String(format: "%.2f", elapsed))s")

                        if strip.count > 0 {
                            self.videoThumbnails[reel.id] = strip
                        }
                        continuation.resume()
                    }
                }
            }
        }
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
                    for url in panel.urls {
                        if let mediaType = ProjectMediaLibrary.mediaType(for: url) {
                            switch mediaType {
                            case .video:
                                await self.addVideoToTimeline(url: url)
                            case .audio:
                                // Create a new lane for each audio file
                                let laneNumber = self.timelineManager.timeline.audioLanes.count + 1
                                let newLane = self.timelineManager.addAudioLane(name: "Audio \(laneNumber)")
                                await self.addAudioToTimeline(url: url, laneId: newLane.id)
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
