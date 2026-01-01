import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import SwiftTimecodeCore

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
                            projectDocument.audioMuteStates[trackIndex] = isMuted
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
        .navigationTitle(projectDocument.displayName)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(projectDocument.displayName)
                    .font(.headline)
                    .italic(projectDocument.hasUnsavedChanges)
            }
        }
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
