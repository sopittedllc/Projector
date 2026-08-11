import SwiftUI
import AVFoundation

// MARK: - Setup & Initialization
extension ContentView {
    // MARK: - Setup

    func setupMIDICallbacks() {
        let initialFrameRate = timelineManager.timeline.config.frameRate

        // Start the MIDI sync actor
        Task {
            do {
                // Configure the decoder before constructing MIDIKit's MTC receiver.
                // The actor defaults to 30 fps, while new projects default to 24 fps.
                await midiSyncActor.setLocalFrameRate(initialFrameRate)
                try await midiSyncActor.start()

                // Restore MIDI input selection
                if !settings.selectedMIDIInput.isEmpty {
                    await midiSyncViewModel.selectInput(settings.selectedMIDIInput)
                }
            } catch {
                debugLog("Failed to start MIDI sync: \(error)")
            }
        }

        // Observe MTC state changes - simple: play when synced, pause when idle
        midiSyncViewModel.$mtcState
            .removeDuplicates()
            .sink { [weak playbackEngine] state in
                guard let engine = playbackEngine else { return }

                switch state {
                case .sync:
                    engine.setMTCSynced(
                        true,
                        // Always. Following the DAW is what the app is for -
                        // this was a toggle, and a slave that ignores its master
                        // is not a mode worth offering.
                        controlPlayback: true
                    )
                case .preSync, .freewheeling:
                    // Track incoming timecode while acquiring/freewheeling, but
                    // do not generate an additional transport transition.
                    engine.setMTCSynced(true, controlPlayback: false)
                case .idle, .incompatibleFrameRate:
                    engine.setMTCSynced(
                        false,
                        controlPlayback: true
                    )
                }
            }
            .store(in: &midiCancellables)

        // Observe MTC timecode changes for position tracking
        // This handles both:
        // 1. Continuous MTC sync (quarter frames during playback) - when isMTCSynced is true
        // 2. MTC Full Frame messages (locate commands) - seek even when not in sync mode
        // Note: Low throttle (50ms) for responsive locates; syncToMTC uses jump detection
        // to prevent over-seeking during continuous playback
        //
        // `removeDuplicates` is load-bearing, not tidiness. The view model
        // reassigns `mtcTimecode` on every `MIDISyncState` emission, and the
        // actor keeps emitting long after the DAW stops - signal decay, sync
        // metrics - so the last timecode is republished indefinitely. Without
        // this, each republish read as a fresh locate and seeked the player back
        // to the frame MTC stopped on, roughly twice a second: local playback
        // could not advance, and the audio was restarted before it could produce
        // a render time. A locate is a *new* position; a repeat of one is not.
        midiSyncViewModel.$mtcTimecode
            .compactMap { $0 }
            .removeDuplicates()
            .throttle(for: .milliseconds(50), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak playbackEngine] timecode in
                guard let engine = playbackEngine else { return }

                if engine.isMTCSynced {
                    // Continuous sync mode - let video play, just track position
                    engine.syncToMTC(timecode)
                } else {
                    // Not in sync mode - this is likely an MTC Full Frame (locate)
                    // Seek to the position like an MMC Locate command
                    engine.seekToTimecode(timecode)
                }
            }
            .store(in: &midiCancellables)

        // Observe MMC transport commands
        midiSyncViewModel.$lastMMCCommand
            .compactMap { $0 }
            .sink { [weak playbackEngine] command in
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

    /// Lets go of the audio interface while the machine sleeps.
    ///
    /// The notifications live on `NSWorkspace`, which belongs to this layer -
    /// the engine is told what happened and decides what to do about it.
    ///
    /// Without this, Projector held an IO proc on the user's interface straight
    /// through sleep. The device left and returned underneath a client that
    /// never let go, and the wake - re-established IO against hardware still
    /// re-locking its clock - arrived as a click through the monitors.
    func setupSystemSleepCallbacks() {
        let engine = playbackEngine
        let notifications = NSWorkspace.shared.notificationCenter

        notifications.publisher(for: NSWorkspace.willSleepNotification)
            .sink { [weak engine] _ in
                engine?.prepareForSystemSleep()
            }
            .store(in: &midiCancellables)

        // Device IDs are not stable across re-enumeration, so the cached one is
        // re-resolved here rather than waiting for the next thing that plays to
        // discover it naming a device that no longer exists.
        notifications.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak engine] _ in
                engine?.resumeAfterSystemWake()
            }
            .store(in: &midiCancellables)
    }

    func setupTimelineCallbacks() {
        // Sync timeline changes to playback engine and document
        let engine = playbackEngine
        let document = projectDocument
        let manager = timelineManager
        let library = mediaLibrary
        let midiSync = midiSyncActor

        timelineManager.onTimelineChanged = {
            engine.timeline = manager.timeline
            document.timeline = manager.timeline

            let frameRate = manager.timeline.config.frameRate
            Task {
                await midiSync.setLocalFrameRate(frameRate)
            }
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

    /// Whether the app was launched by the UI test runner.
    ///
    /// Outside DEBUG this only suppresses first-run onboarding; the test
    /// harness itself is not compiled into release builds.
    var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("-ui-testing")
    }

    #if DEBUG
    /// Import files through the same handler a drop uses, from the command line.
    ///
    /// `handleUITestImportIfNeeded` places a clip directly, which is what makes it
    /// reliable for waveform tests but also means it never opens the import
    /// dialogs. This enters through `handleMixedBatchDrop`, so the timecode and
    /// output-routing sheets appear exactly as they would for a user.
    ///
    /// It exists because a drag cannot be synthesised into a SwiftUI drop target,
    /// and drop is the only way those sheets are reached - without this they can
    /// only ever be tested by hand.
    ///
    /// Usage: `-ui-testing -test-drop-urls <path> [<path>...]`
    func handleUITestDropIfNeeded() {
        guard !didHandleUITestDrop else { return }

        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-ui-testing"),
              let flagIndex = arguments.firstIndex(of: "-test-drop-urls") else { return }

        // Every path until the next flag, so one argument can carry a whole drop.
        let paths = arguments[arguments.index(after: flagIndex)...].prefix { !$0.hasPrefix("-") }
        let urls = paths.map { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty else { return }

        didHandleUITestDrop = true

        var videoURLs: [URL] = []
        var audioURLs: [URL] = []
        for url in urls {
            switch ProjectMediaLibrary.mediaType(for: url) {
            case .video: videoURLs.append(url)
            case .audio: audioURLs.append(url)
            case nil: debugPrint("handleUITestDropIfNeeded: unsupported file \(url.lastPathComponent)")
            }
        }

        debugPrint("handleUITestDropIfNeeded: dropping \(videoURLs.count) video, \(audioURLs.count) audio")
        handleMixedBatchDrop(videoURLs: videoURLs, audioURLs: audioURLs, atFrame: 0)
    }

    func handleUITestImportIfNeeded() {
        guard !didHandleUITestImport else { return }

        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-ui-testing") else { return }
        // A scripted drop is doing the importing; the synthetic clip would only
        // add a lane the drop then has to work around.
        guard !arguments.contains("-test-drop-urls") else { return }
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
    #endif

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
            alerts.show(.error(errorMessage))
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

// MARK: - Clearing Modals for an Update

extension ContentView {

    /// How many run-loop turns to wait for sheets to finish closing.
    private static var sheetCloseAttempts: Int { 20 }

    /// Close anything still modal, then let the update continue.
    ///
    /// **AppKit will not terminate an app with a modal sheet on screen** - it
    /// checks, refuses, and says so in its own log:
    ///
    /// ```
    /// Checking whether app should terminate
    /// App termination blocked by modal sheet
    /// ```
    ///
    /// That is why "Install and Relaunch" once appeared to do nothing: the
    /// download had finished and the install was ready, but the quit request was
    /// refused before `applicationShouldTerminate` was even consulted, with
    /// nothing shown to say so.
    ///
    /// Dismissing SwiftUI's own state happens first, at the call site, so the app
    /// does not go on believing a sheet is up. This sweep catches whatever SwiftUI
    /// does not own, then waits for the sheets to actually be gone - closing one is
    /// animated, and asking to quit mid-animation lands back where we started.
    ///
    /// - Parameter handoff: Sparkle's permission to continue, or `nil` when the
    ///   notification came from somewhere else.
    func closeRemainingSheets(then handoff: UpdateRelaunchHandoff?, attempt: Int = 0) {
        if let modal = NSApp.modalWindow {
            NSApp.abortModal()
            modal.close()
        }

        for window in NSApp.windows {
            for sheet in window.sheets {
                window.endSheet(sheet)
            }
        }

        let remaining = NSApp.windows.reduce(0) { $0 + $1.sheets.count }
        guard remaining == 0 || attempt >= Self.sheetCloseAttempts else {
            DispatchQueue.main.async {
                closeRemainingSheets(then: handoff, attempt: attempt + 1)
            }
            return
        }

        if remaining > 0 {
            diagnosticLog(
                .warning, .app,
                "\(remaining) sheet(s) would not close; termination may be refused."
            )
        }

        handoff?.proceed()
    }
}
