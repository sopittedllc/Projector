import SwiftUI
import AVFoundation

// MARK: - Setup & Initialization
extension ContentView {
    // MARK: - Setup

    func setupMIDICallbacks() {
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

    func setupAudioCallback() {
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

    func setupTimelineCallbacks() {
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

    func restoreSettings() {
        // Apply audio device
        if !settings.selectedAudioOutput.isEmpty {
            playbackEngine.setAudioOutputDevice(settings.selectedAudioOutput)
        }
    }

    func handleUITestImportIfNeeded() {
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

    var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("-ui-testing")
    }

    var uiTestClipCount: Int {
        timelineManager.timeline.audioLanes.reduce(0) { $0 + $1.clips.count }
    }

    func uiTestAudioURL(from arguments: [String]) -> URL? {
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

    func createUITestAudioFile() -> URL? {
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
    func syncTimelineToDocument() {
        projectDocument.timeline = timelineManager.timeline
    }

    /// Sync media library to project document
    func syncMediaLibraryToDocument() {
        projectDocument.mediaLibrary = mediaLibrary.exportItems()
    }

    // MARK: - Persistence Service Setup

    /// Wire up callbacks for the persistence service
    func setupPersistenceServiceCallbacks() {
        // Error callback - show alert when errors occur
        persistenceService.onError = { [self] errorMessage in
            loadError = errorMessage
            showErrorAlert = true
        }

        // Missing file check callback - delegates to missing file service
        persistenceService.onNeedsMissingFileCheck = { [self] in
            // Wire up resolution complete callback
            missingFileService.onResolutionComplete = { [self] in
                loadProjectReels()
            }
            // Check for missing files
            return missingFileService.checkForMissingFiles()
        }

        // Load project reels callback
        persistenceService.onLoadProjectReels = { [self] in
            loadProjectReels()
        }
    }
}
