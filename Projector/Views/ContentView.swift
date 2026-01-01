import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import SwiftTimecodeCore
import AppKit

/// Configures the window title with a logo
struct WindowTitleConfigurator: NSViewRepresentable {
    let title: String
    let isEdited: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configureWindowTitle(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configureWindowTitle(nsView.window)
        }
    }

    private func configureWindowTitle(_ window: NSWindow?) {
        guard let window = window else { return }

        // Hide the system title - we'll show our own
        window.titleVisibility = .hidden

        // Update the window title (for Window menu, etc.)
        let displayTitle = title + (isEdited ? " *" : "")
        window.title = displayTitle

        // Find the titlebar container and add our custom title with logo
        guard let titlebarContainer = window.standardWindowButton(.closeButton)?.superview?.superview else { return }

        // Look for an existing custom title view or create one
        configureTitleWithLogo(in: titlebarContainer, window: window)
    }

    private func configureTitleWithLogo(in container: NSView, window: NSWindow) {
        // Check if we already added our custom view (identified by accessibilityIdentifier)
        let customViewID = "ProjectorTitleView"
        if let existingView = findViewWithIdentifier(customViewID, in: container) as? NSStackView {
            // Update existing view
            if let textField = existingView.arrangedSubviews.last as? NSTextField {
                let displayTitle = title + (isEdited ? " *" : "")
                textField.stringValue = displayTitle
                if isEdited {
                    textField.font = NSFont.systemFont(ofSize: 13, weight: .semibold).italic()
                } else {
                    textField.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
                }
            }
            return
        }

        // Find the original title text field
        guard let originalTitle = findTitleTextField(in: container, title: title) else { return }

        // Hide the original title
        originalTitle.isHidden = true

        // Create our custom title view with logo
        let stackView = NSStackView()
        stackView.setAccessibilityIdentifier(customViewID)
        stackView.orientation = .horizontal
        stackView.spacing = 6
        stackView.alignment = .centerY
        stackView.translatesAutoresizingMaskIntoConstraints = false

        // Add logo
        let logoView = NSImageView()
        logoView.image = NSImage(named: "TitlebarLogo")
        logoView.imageScaling = .scaleProportionallyUpOrDown
        logoView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            logoView.widthAnchor.constraint(equalToConstant: 16),
            logoView.heightAnchor.constraint(equalToConstant: 16)
        ])
        stackView.addArrangedSubview(logoView)

        // Add title text
        let titleField = NSTextField(labelWithString: title + (isEdited ? " *" : ""))
        titleField.font = isEdited ? NSFont.systemFont(ofSize: 13, weight: .semibold).italic() : NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleField.textColor = .labelColor
        titleField.alignment = .center
        stackView.addArrangedSubview(titleField)

        // Add to the same superview as the original title
        if let superview = originalTitle.superview {
            superview.addSubview(stackView)

            // Center the stack view where the original title was
            NSLayoutConstraint.activate([
                stackView.centerXAnchor.constraint(equalTo: superview.centerXAnchor),
                stackView.centerYAnchor.constraint(equalTo: originalTitle.centerYAnchor)
            ])
        }
    }

    private func findViewWithIdentifier(_ identifier: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == identifier {
            return view
        }
        for subview in view.subviews {
            if let found = findViewWithIdentifier(identifier, in: subview) {
                return found
            }
        }
        return nil
    }

    private func findTitleTextField(in view: NSView, title: String) -> NSTextField? {
        for subview in view.subviews {
            if let textField = subview as? NSTextField,
               textField.stringValue.contains(title) || textField.stringValue == "Untitled Projector Project" {
                return textField
            }
            if let found = findTitleTextField(in: subview, title: title) {
                return found
            }
        }
        return nil
    }
}

extension NSFont {
    func italic() -> NSFont {
        let descriptor = fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: 0) ?? self
    }
}

/// Main application content view
struct ContentView: View {
    @StateObject private var playerManager = VideoPlayerManager()
    @StateObject private var midiManager = MIDIManager()
    @StateObject private var audioManager = AudioOutputManager()
    @StateObject private var waveformGenerator = WaveformGenerator()
    @StateObject private var projectDocument = ProjectDocument()
    @ObservedObject private var settings = AppSettings.shared

    @State private var showSettings = false
    @State private var isDropTargeted = false
    @State private var isLoadingVideo = false
    @State private var loadError: String?
    @State private var showErrorAlert = false
    @State private var audioTracks: [AudioTrackInfo] = []

    var body: some View {
        VStack(spacing: 0) {
            // Video content area - takes all available space
            VideoContentView(
                playerManager: playerManager,
                showTimecode: settings.showTimecodeOverlay,
                overlayPosition: settings.timecodeOverlayPosition,
                overlayOpacity: settings.timecodeOverlayOpacity
            )
            .frame(minWidth: 480, minHeight: 200)
            .transaction { $0.animation = nil } // Disable animations for smooth resize
                .overlay {
                    // Drop target overlay
                    if isDropTargeted {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.accentColor, lineWidth: 3)
                            .background(Color.accentColor.opacity(0.1))
                            .padding(8)
                    }

                    // Loading overlay
                    if isLoadingVideo {
                        ZStack {
                            Color.black.opacity(0.5)

                            VStack(spacing: 16) {
                                ProgressView()
                                    .scaleEffect(1.5)
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))

                                Text("Loading video...")
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

                // Timeline with scrubber and waveforms
                if playerManager.hasVideo {
                    Divider()

                    TimelineView(
                        playerManager: playerManager,
                        waveformGenerator: waveformGenerator,
                        audioTracks: $audioTracks,
                        onTrackMuteChanged: { trackIndex, isMuted in
                            playerManager.setTrackMuted(trackIndex, muted: isMuted)
                        }
                    )
                    .fixedSize(horizontal: false, vertical: true)

                    Divider()
                } else {
                    Divider()
                }

                // Transport bar with margin from window edges
                HStack {
                    TransportBarView(
                        playerManager: playerManager,
                        onSettingsPressed: { showSettings = true }
                    )
                }
                .padding(16)
            }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(
                midiManager: midiManager,
                audioManager: audioManager,
                isPresented: $showSettings
            )
        }
        .alert("Error Loading Video", isPresented: $showErrorAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(loadError ?? "Unknown error")
        }
        .frame(minWidth: 640, minHeight: 400)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("")
        .background(WindowTitleConfigurator(
            title: projectDocument.displayName,
            isEdited: projectDocument.hasUnsavedChanges
        ))
        .onReceive(NotificationCenter.default.publisher(for: .videoFileSelected)) { notification in
            if let url = notification.object as? URL {
                Task {
                    await loadVideo(from: url)
                }
            }
        }
        .onAppear {
            setupMIDICallbacks()
            setupAudioCallback()
            restoreSettings()
        }
        // Track timecode offset changes
        .onReceive(playerManager.$timecodeOffset) { newOffset in
            if projectDocument.timecodeOffset != newOffset {
                projectDocument.timecodeOffset = newOffset
            }
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
            // Store the offset before loading (loadVideo resets it)
            let savedTimecodeOffset = projectDocument.timecodeOffset

            try projectDocument.load(from: url)
            let restoredOffset = projectDocument.timecodeOffset
            NSLog(">>> openProject: loaded timecodeOffset = %@", restoredOffset.stringValue())

            // If project has a video URL, load it
            if let videoURL = projectDocument.videoURL {
                Task {
                    await loadVideo(from: videoURL)

                    // Restore timecode offset AFTER video loads (loadVideo resets it)
                    // Use setTimecodeOffset to also update currentTimecode display
                    playerManager.setTimecodeOffset(restoredOffset)
                    projectDocument.timecodeOffset = restoredOffset  // Reset since loadVideo changed it
                    NSLog(">>> openProject: restored timecodeOffset = %@", restoredOffset.stringValue())
                }
            } else {
                // No video, just restore the offset
                playerManager.setTimecodeOffset(restoredOffset)
                NSLog(">>> openProject: restored timecodeOffset (no video) = %@", restoredOffset.stringValue())
            }
        } catch {
            loadError = error.localizedDescription
            showErrorAlert = true
        }
    }

    // MARK: - Setup

    private func setupMIDICallbacks() {
        // Handle MTC timecode changes for video sync
        midiManager.onTimecodeChanged = { [weak playerManager] timecode in
            guard let playerManager = playerManager else { return }
            Task { @MainActor in
                // Calculate drift from current position
                let currentSeconds = playerManager.currentTime
                let mtcSeconds = playerManager.timecodeToSeconds(timecode)
                let driftFrames = abs(currentSeconds - mtcSeconds) * playerManager.frameRate.fps

                // Re-sync if drift exceeds threshold (handles both playback drift and scrubbing)
                if driftFrames > Double(AppSettings.shared.syncDriftThreshold) {
                    print("MTC sync: drift=\(Int(driftFrames)) frames, seeking to \(timecode.stringValue())")
                    playerManager.seekToMTC(timecode)
                }
            }
        }

        // Handle MMC transport commands
        midiManager.onMMCCommand = { [weak playerManager] command in
            guard AppSettings.shared.respondToMMC, let playerManager = playerManager else { return }
            Task { @MainActor in
                switch command {
                case .stop:
                    playerManager.stop()
                case .play, .deferredPlay:
                    playerManager.play()
                case .pause:
                    playerManager.pause()
                case .locate(let timecode):
                    playerManager.seek(to: timecode)
                case .fastForward, .rewind:
                    // Not implemented for v1
                    break
                }
            }
        }

        // Restore MIDI input selection
        if !settings.selectedMIDIInput.isEmpty {
            midiManager.selectedInputName = settings.selectedMIDIInput
        }
    }

    private func setupAudioCallback() {
        audioManager.onDeviceChanged = { [weak playerManager] deviceUID in
            playerManager?.setAudioOutputDevice(deviceUID)
        }

        // Restore audio device selection
        if !settings.selectedAudioOutput.isEmpty {
            audioManager.selectedDeviceUID = settings.selectedAudioOutput
        }
    }

    private func restoreSettings() {
        // Apply audio device
        if !settings.selectedAudioOutput.isEmpty {
            playerManager.setAudioOutputDevice(settings.selectedAudioOutput)
        }
    }

    // MARK: - File Handling

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else {
                return
            }

            Task { @MainActor in
                await loadVideo(from: url)
            }
        }

        return true
    }

    func loadVideo(from url: URL) async {
        isLoadingVideo = true

        do {
            try await playerManager.loadVideo(from: url)

            // Update project document
            projectDocument.videoURL = url
            projectDocument.frameRate = playerManager.frameRate

            // Update MIDI manager with video's frame rate
            midiManager.setLocalFrameRate(playerManager.frameRate)

            // Load audio tracks for timeline
            await loadAudioTracks(from: url)

            isLoadingVideo = false

            // Generate waveforms in background (after loading indicator dismissed)
            Task {
                try? await waveformGenerator.generateWaveforms(from: url)
            }

        } catch {
            isLoadingVideo = false
            loadError = error.localizedDescription
            showErrorAlert = true
        }
    }

    private func loadAudioTracks(from url: URL) async {
        do {
            let asset = AVAsset(url: url)
            let tracks = try await asset.load(.tracks)
            let duration = try await asset.load(.duration)
            let durationSeconds = CMTimeGetSeconds(duration)

            var newAudioTracks: [AudioTrackInfo] = []

            let audioAssetTracks = tracks.filter { $0.mediaType == .audio }
            for (index, track) in audioAssetTracks.enumerated() {
                var channelCount = 2
                var sampleRate = 48000.0

                let formatDescriptions = try await track.load(.formatDescriptions)
                if let formatDesc = formatDescriptions.first {
                    if let basicDesc = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) {
                        channelCount = Int(basicDesc.pointee.mChannelsPerFrame)
                        sampleRate = basicDesc.pointee.mSampleRate
                    }
                }

                let trackInfo = AudioTrackInfo(
                    trackIndex: index,
                    name: "Audio \(index + 1)",
                    channelCount: channelCount,
                    sampleRate: sampleRate,
                    duration: durationSeconds,
                    outputChannelOffset: index * 2 // Default: each track to next stereo pair
                )
                newAudioTracks.append(trackInfo)
            }

            audioTracks = newAudioTracks
        } catch {
            print("Failed to load audio tracks: \(error)")
            audioTracks = []
        }
    }

    /// Called from menu File > Open
    func openFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            .movie,
            .mpeg4Movie,
            .quickTimeMovie,
            UTType(filenameExtension: "mov")!,
            UTType(filenameExtension: "mp4")!,
            UTType(filenameExtension: "m4v")!
        ]

        panel.begin { response in
            if response == .OK, let url = panel.url {
                Task { @MainActor in
                    await loadVideo(from: url)
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
