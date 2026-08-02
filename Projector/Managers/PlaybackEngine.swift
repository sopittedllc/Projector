import Foundation
import AVFoundation
import Combine
import SwiftTimecodeCore
import AudioToolbox

// MARK: - PlaybackEngine

/// Multi-reel playback engine with timeline support.
///
/// `PlaybackEngine` manages seamless video reel switching and multiple audio clip playback
/// across a unified timeline. It handles the complexity of multi-asset playback including
/// gap handling, preloading, and audio routing through a matrix mixer.
///
/// ## Architecture
///
/// ```
/// ┌─────────────────────────────────────────────────────────────────┐
/// │                    TransportActor                               │
/// │  (bridges PlaybackEngine to TransportServiceProtocol)           │
/// └─────────────────────────────────────────────────────────────────┘
///                               │
///                               ▼
/// ┌─────────────────────────────────────────────────────────────────┐
/// │              PlaybackEngine (this file)                         │
/// │  - Multi-reel video playback with seamless transitions          │
/// │  - Gap handling (timer-based frame advancement)                 │
/// │  - Audio routing via AVAudioEngine + MatrixMixer                │
/// │  - Preloading for smooth reel transitions                       │
/// └─────────────────────────────────────────────────────────────────┘
///                               │
///                 ┌─────────────┼─────────────┐
///                 ▼             ▼             ▼
/// ┌───────────────────┐ ┌────────────┐ ┌──────────────┐
/// │     AVPlayer      │ │ AVAudioEngine│ │   Timeline  │
/// │ (video playback)  │ │ (audio routing) │ │  (data model)│
/// └───────────────────┘ └────────────┘ └──────────────┘
/// ```
///
/// ## Thread Safety
///
/// This class is `@MainActor`-isolated for safe SwiftUI observation. Heavy operations
/// like audio extraction run on background queues. The audio engine uses its own
/// internal dispatch queues for buffer processing.
///
/// ## Video Playback
///
/// Video reels are loaded from the timeline and played via AVPlayer. When approaching
/// a reel boundary (within 5 seconds), the next reel is preloaded for seamless transition.
/// Gaps between reels are handled by a timer that advances the frame counter.
///
/// ## Audio Routing
///
/// Audio clips are played through an AVAudioEngine graph:
/// ```
/// PlayerNode -> RateConverter -> MatrixMixer -> MainMixer -> OutputNode
/// ```
///
/// The MatrixMixer allows flexible channel routing (e.g., mono to specific outputs,
/// stereo to channels 3-4, etc.) for multi-channel audio interfaces.
///
/// ## Usage
///
/// ```swift
/// let engine = PlaybackEngine(timeline: project.timeline)
///
/// // Load and play
/// try await engine.loadReel(videoReel)
/// engine.play()
///
/// // Seek to timecode
/// engine.seekToFrame(1000)
///
/// // Configure audio output
/// engine.setAudioOutputDevice(deviceUID)
/// ```
@MainActor
final class PlaybackEngine: ObservableObject {
    // MARK: - Published Properties

    /// Primary video player (current reel)
    @Published private(set) var currentPlayer: AVPlayer?

    /// Whether playback is active
    @Published private(set) var isPlaying = false

    /// Current position on the master timeline (in frames)
    @Published private(set) var currentFrame: Int = 0

    /// Current timecode based on timeline position
    @Published private(set) var currentTimecode: Timecode

    /// Duration of the timeline in frames
    @Published private(set) var durationFrames: Int = 0

    /// Whether video is currently in a gap (no reel at current position)
    @Published private(set) var isInGap = false

    /// Active video reel at current position (nil if in gap)
    @Published private(set) var activeReel: VideoReel?

    /// Has any content loaded
    @Published private(set) var hasContent = false

    /// User has manually stopped - overrides MTC auto-play until user plays or MTC restarts
    @Published private(set) var transportOverride = false

    /// Whether we're in MTC sync mode (following external timecode)
    @Published private(set) var isMTCSynced = false

    // MARK: - Audio Metering

    /// Left channel meter level (0.0-1.0, RMS normalized)
    @Published private(set) var meterLevelLeft: Float = 0

    /// Right channel meter level (0.0-1.0, RMS normalized)
    @Published private(set) var meterLevelRight: Float = 0

    /// Whether audio metering is enabled
    @Published private(set) var isMeteringEnabled = false

    /// Target frame from MTC (for drift calculation)
    private var mtcTargetFrame: Int = 0

    /// Last time playback was corrected to the incoming MTC position.
    private var lastMTCResyncTime: Date = .distantPast

    /// Minimum interval between corrective seeks to prevent seek storms.
    private let minimumMTCResyncInterval: TimeInterval = 0.25

    /// Meter decay coefficient for smooth falloff
    private let meterDecay: Float = 0.9

    /// Whether meter tap is installed
    private var meterTapInstalled = false

    // MARK: - Timeline Reference

    /// The timeline being played back
    var timeline: Timeline {
        didSet {
            updateTimelineProperties()
        }
    }

    /// Convenience: frame rate from timeline config
    var frameRate: TimecodeFrameRate {
        timeline.config.frameRate
    }

    /// Convenience: current time in seconds
    var currentTime: Double {
        Double(currentFrame) / frameRate.fps
    }

    /// Convenience: duration in seconds
    var duration: Double {
        Double(durationFrames) / frameRate.fps
    }

    // MARK: - Private Properties

    /// Secondary video player for preloading next reel
    private var preloadPlayer: AVPlayer?

    /// Asset cache for loaded video files
    private var assetCache: [UUID: AVAsset] = [:]

    /// Audio engine for routed playback
    private let audioEngine = AVAudioEngine()

    /// Audio players for active clips
    private var audioPlayers: [UUID: AudioClipPlayback] = [:]

    /// Time observer for periodic updates
    private var timeObserver: Any?

    /// Display link for frame-accurate updates
    private var displayLink: CVDisplayLink?

    /// Current reel ID being played
    private var currentReelId: UUID?

    /// ID of reel being preloaded
    private var preloadingReelId: UUID?

    /// Playback rate (1.0 = normal)
    private var playbackRate: Float = 1.0

    /// Whether we're currently seeking
    private var isSeeking = false

    /// Selected audio output device UID
    private var audioOutputDeviceUID: String?

    /// Selected audio output device ID
    private var audioOutputDeviceID: AudioDeviceID?

    /// Output channel count for selected device
    private var audioOutputChannelCount: Int = 2

    /// Output sample rate for selected device
    private var audioOutputSampleRate: Double = 48000

    /// Cached output format
    private var audioOutputFormat: AVAudioFormat?

    /// Clips currently being loaded (to prevent duplicate load attempts)
    private var loadingClipIds: Set<UUID> = []

    /// Clips that failed to load with timestamp (for retry cooldown)
    private var failedClipCooldowns: [UUID: Date] = [:]

    /// Cooldown duration before retrying a failed clip load (seconds)
    private let failedClipRetryCooldown: TimeInterval = 2.0

    /// Pending seek request (coalesced)
    private var pendingSeekFrame: Int?

    /// Sample rate change listener block (held for cleanup)
    private nonisolated(unsafe) var sampleRateListenerBlock: AudioObjectPropertyListenerBlock?

    /// Dispatch queue for sample rate change notifications
    private let sampleRateListenerQueue = DispatchQueue(
        label: "com.projector.samplerate-listener"
    )

    /// Callback for frame position updates (used by TransportActor)
    var onFrameUpdate: ((Int) async -> Void)?

    // MARK: - Constants

    /// Seconds before reel boundary to start preloading
    private let preloadThreshold: Double = 5.0


    /// Sendable wrapper for AVAssetExportSession used in legacy export.
    private struct ExportSessionBox: @unchecked Sendable {
        let session: AVAssetExportSession
    }

    /// State container for an actively playing audio clip.
    ///
    /// Keeps sandbox access to a file open for as long as it is needed.
    ///
    /// Audio used to be copied into the app's container before playback, so
    /// access to the user's media only had to last the length of that copy.
    /// Playing straight from the source means the file is read again on every
    /// seek, so access has to live as long as the open file - which is what this
    /// ties it to.
    final class SecurityScopedAccess {
        /// The URL access was granted for, which a bookmark may have relocated.
        let url: URL
        private let didStart: Bool

        /// Resolve a clip's media, preferring its bookmark.
        ///
        /// - Parameter clip: Clip whose source is being opened.
        init(for clip: AudioClip) {
            var resolved = clip.sourceURL
            if let bookmarkData = clip.sourceBookmark {
                var isStale = false
                if let bookmarked = try? URL(
                    resolvingBookmarkData: bookmarkData,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                ) {
                    resolved = bookmarked
                }
            }
            url = resolved
            didStart = resolved.startAccessingSecurityScopedResource()
        }

        /// Initialize with a plain URL (no security-scoped access needed).
        ///
        /// Used for extracted audio files in the app's temporary directory,
        /// which are already inside the sandbox.
        init(localURL: URL) {
            url = localURL
            didStart = false
        }

        deinit {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }
    }

    /// Holds references to the audio graph nodes and scheduling state for a single clip.
    private final class AudioClipPlayback {
        let clipId: UUID
        let player: AVAudioPlayerNode
        let rateConverter: AVAudioMixerNode
        let matrixMixer: AVAudioUnit
        let audioFile: AVAudioFile
        let inputChannelCount: Int

        /// One side of a hard-panned source, if this lane carries only that.
        ///
        /// The file read is the ordinary stereo one; the side is selected in the
        /// matrix mixer, so splitting costs no extra file on disk.
        let isolatedChannel: Int?

        /// Sandbox access to the media, held for as long as the file is open.
        ///
        /// Audio is read straight from the user's video now, so access cannot be
        /// released after opening the way a one-shot extraction could - the file
        /// is read again on every seek.
        let mediaAccess: SecurityScopedAccess?

        var outputMappingId: UUID?
        var outputChannelOffset: Int
        var outputChannelCount: Int
        var scheduledSourceTime: Double?

        init(
            clipId: UUID,
            player: AVAudioPlayerNode,
            rateConverter: AVAudioMixerNode,
            matrixMixer: AVAudioUnit,
            audioFile: AVAudioFile,
            inputChannelCount: Int,
            isolatedChannel: Int?,
            mediaAccess: SecurityScopedAccess?,
            outputMappingId: UUID?,
            outputChannelOffset: Int,
            outputChannelCount: Int
        ) {
            self.clipId = clipId
            self.player = player
            self.rateConverter = rateConverter
            self.matrixMixer = matrixMixer
            self.audioFile = audioFile
            self.inputChannelCount = inputChannelCount
            self.isolatedChannel = isolatedChannel
            self.mediaAccess = mediaAccess
            self.outputMappingId = outputMappingId
            self.outputChannelOffset = outputChannelOffset
            self.outputChannelCount = outputChannelCount
            self.scheduledSourceTime = nil
        }
    }

    // MARK: - Initialization

    /// Creates a new playback engine for the given timeline.
    ///
    /// Initializes the audio engine and configures output settings immediately
    /// for responsive playback when play is first pressed.
    ///
    /// - Parameter timeline: The timeline to play back (default is empty).
    init(timeline: Timeline = .empty) {
        self.timeline = timeline
        self.currentTimecode = timeline.config.startTimecode
        updateTimelineProperties()
        updateAudioOutputDeviceSettings()
        // Pre-configure audio engine at launch for immediate playback readiness
        configureAudioEngineIfNeeded()
        ensureAudioEngineRunning()
    }

    // MARK: - Public Methods

    /// Loads a video reel and prepares it for playback.
    ///
    /// Creates an AVPlayer for the reel, caches the asset, and sets up time observation.
    /// The previous player (if any) is paused and its observer removed.
    ///
    /// - Parameter reel: The video reel to load.
    /// - Throws: ``PlaybackEngineError.notPlayable`` if the asset cannot be played.
    func loadReel(_ reel: VideoReel) async throws {
        // Get or create asset
        let asset = try await getAsset(for: reel)

        // Check playability
        let isPlayable = try await asset.load(.isPlayable)
        guard isPlayable else {
            throw PlaybackEngineError.notPlayable
        }

        // Create player
        let playerItem = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: playerItem)
        player.automaticallyWaitsToMinimizeStalling = false
        player.isMuted = true

        // Cache asset
        assetCache[reel.id] = asset

        // Update current player
        removeTimeObserver()
        currentPlayer?.pause()
        currentPlayer = player
        currentReelId = reel.id
        activeReel = reel
        isInGap = false
        hasContent = true

        setupTimeObserver()
    }

    /// Starts playback from the current position.
    ///
    /// If the playhead is on a video reel, that reel is loaded (if needed) and playback begins.
    /// If the playhead is in a gap, a timer advances the frame counter at the timeline's frame rate.
    /// Active audio clips are also started and synchronized.
    func play() {
        // Transport transitions only. Seeks are deliberately not logged: they
        // fire continuously while the playhead is dragged and would flush the
        // ring buffer of everything that led up to the problem.
        diagnosticLog(.info, .playback, "Play from frame \(currentFrame)")
        transportOverride = false  // Clear override when user plays
        resetSeekState()

        if let reel = timeline.videoReel(at: currentFrame) {
            isInGap = false
            activeReel = reel
            isPlaying = true

            if currentPlayer == nil || currentReelId != reel.id {
                Task {
                    do {
                        try await loadReel(reel)
                    } catch {
                        debugPrint("PlaybackEngine.play: Failed to load reel '\(reel.sourceURL.lastPathComponent)': \(error)")
                        diagnosticLog(.error, .playback, "Failed to load reel '\(reel.sourceURL.lastPathComponent)': \(error.localizedDescription)")
                    }
                    seekWithinReel(reel, timelineFrame: currentFrame, resumeAfterSeek: true) {}
                }
            } else {
                currentPlayer?.play()
            }
        } else {
            // No video reel at this frame - advance time in a gap
            // This also handles the "no content" case - timeline still tracks position
            isInGap = true
            activeReel = nil
            isPlaying = true
            currentPlayer?.pause()
            startGapPlayback()
        }

        // Start audio clips (if any)
        startActiveAudioClips()
    }

    /// Pauses playback at the current position.
    ///
    /// Pauses video playback, stops gap timer, and stops all audio clips.
    func pause() {
        diagnosticLog(.info, .playback, "Pause at frame \(currentFrame)")
        currentPlayer?.pause()
        isPlaying = false
        resetSeekState()
        stopGapPlayback()
        stopAllAudioClips()
    }

    /// Toggles between play and pause states.
    func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    /// Stops playback and returns to the start of the timeline.
    ///
    /// Sets `transportOverride` to prevent MTC auto-play until user manually plays
    /// or MTC sync restarts (goes idle then syncs again).
    func stop() {
        transportOverride = true  // User stopped - override MTC auto-play
        pause()
        seekToFrame(0)
    }

    /// Clears the transport override flag.
    ///
    /// Called when MTC goes idle (stop received) so that a new MTC sync session
    /// can trigger auto-play again.
    func clearTransportOverride() {
        transportOverride = false
    }

    // MARK: - Audio Metering

    /// Enables audio metering by installing a tap on the main mixer.
    ///
    /// When enabled, `meterLevelLeft` and `meterLevelRight` are updated
    /// in real-time with RMS audio levels (0.0-1.0).
    func enableMetering() {
        guard !isMeteringEnabled else { return }
        isMeteringEnabled = true
        installMeterTap()
    }

    /// Disables audio metering and removes the tap.
    func disableMetering() {
        guard isMeteringEnabled else { return }
        isMeteringEnabled = false
        removeMeterTap()
        meterLevelLeft = 0
        meterLevelRight = 0
    }

    /// Installs the audio meter tap on the main mixer node.
    private func installMeterTap() {
        guard !meterTapInstalled else { return }

        let mainMixer = audioEngine.mainMixerNode
        let format = mainMixer.outputFormat(forBus: 0)

        // Only install if we have a valid format
        guard format.channelCount > 0, format.sampleRate > 0 else {
            debugPrint("PlaybackEngine: Cannot install meter tap - invalid format")
            return
        }

        // Buffer size: ~20ms at the current sample rate for responsive metering
        let bufferSize = AVAudioFrameCount(format.sampleRate * 0.02)

        mainMixer.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, _ in
            self?.processMeterBuffer(buffer)
        }

        meterTapInstalled = true
        debugPrint("PlaybackEngine: Meter tap installed (\(format.channelCount) channels, \(format.sampleRate)Hz)")
    }

    /// Removes the audio meter tap from the main mixer node.
    private func removeMeterTap() {
        guard meterTapInstalled else { return }

        audioEngine.mainMixerNode.removeTap(onBus: 0)
        meterTapInstalled = false
        debugPrint("PlaybackEngine: Meter tap removed")
    }

    /// Processes an audio buffer to calculate RMS meter levels.
    ///
    /// - Parameter buffer: The audio buffer from the meter tap
    private nonisolated func processMeterBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let floatData = buffer.floatChannelData else { return }

        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0, channelCount > 0 else { return }

        // Calculate RMS for left channel (or mono)
        var leftRMS: Float = 0
        let leftChannel = floatData[0]
        for i in 0..<frameLength {
            let sample = leftChannel[i]
            leftRMS += sample * sample
        }
        leftRMS = sqrt(leftRMS / Float(frameLength))

        // Calculate RMS for right channel (if stereo+)
        var rightRMS: Float = 0
        if channelCount >= 2 {
            let rightChannel = floatData[1]
            for i in 0..<frameLength {
                let sample = rightChannel[i]
                rightRMS += sample * sample
            }
            rightRMS = sqrt(rightRMS / Float(frameLength))
        } else {
            rightRMS = leftRMS // Mono: use same level for both
        }

        // Convert to normalized 0-1 scale with soft compression
        // RMS of full-scale sine is ~0.707, so we normalize accordingly
        let normalizedLeft = min(1.0, leftRMS * 1.414)
        let normalizedRight = min(1.0, rightRMS * 1.414)

        // Update on main thread with decay for smooth falloff
        // Only publish changes above threshold to reduce SwiftUI re-renders
        Task { @MainActor [weak self] in
            guard let self, self.isMeteringEnabled else { return }

            let meterThreshold: Float = 0.01  // Only publish if change > 1%
            let oldLeft = self.meterLevelLeft
            let oldRight = self.meterLevelRight

            // Apply decay: only update if new value is higher, otherwise decay
            let newLeft: Float = normalizedLeft > oldLeft ? normalizedLeft : max(0, oldLeft * self.meterDecay)
            let newRight: Float = normalizedRight > oldRight ? normalizedRight : max(0, oldRight * self.meterDecay)

            // Only publish if change is significant (reduces SwiftUI re-renders)
            if abs(newLeft - oldLeft) > meterThreshold {
                self.meterLevelLeft = newLeft
            }
            if abs(newRight - oldRight) > meterThreshold {
                self.meterLevelRight = newRight
            }
        }
    }

    /// Sets MTC sync mode.
    ///
    /// When synced, the playback engine follows external MTC position.
    /// Timeline position is updated via `syncToMTC()` calls from MTC timecode observer.
    func setMTCSynced(_ synced: Bool, controlPlayback: Bool = true) {
        isMTCSynced = synced

        if synced {
            // MTC is active. Position is now driven by incoming timecode even
            // when the user has disabled automatic transport control.
            stopGapPlayback()  // Don't run our own timer - MTC drives position
            mtcTargetFrame = currentFrame  // Initialize target to current position

            guard controlPlayback else { return }

            transportOverride = false
            isPlaying = true

            // Start the picture at the current position.
            //
            // This is deliberately not guarded on "did we just become synced".
            // MTC always arrives as freewheeling -> pre-sync -> sync, and the
            // first two call this with `controlPlayback: false`, which sets
            // `isMTCSynced` and returns early. By the time the locked `.sync`
            // arrives the transition has already happened, so a
            // was-not-synced-before check never fired: the audio started (it has
            // no such guard) and the picture never did.
            //
            // It also has to run for `activeReel`, which `handleTimeUpdate`
            // requires before it will advance the timeline at all. `syncToMTC`
            // only assigns it when the reel *changes*, so a reel already loaded
            // from import left it nil and the clock never moved.
            //
            // Written to be idempotent, so repeating it on a later sync event
            // costs nothing.
            if let reel = timeline.videoReel(at: currentFrame) {
                isInGap = false
                activeReel = reel

                if currentPlayer == nil || currentReelId != reel.id {
                    Task {
                        do {
                            try await loadReel(reel)
                        } catch {
                            debugPrint("PlaybackEngine.setMTCSynced: Failed to load reel '\(reel.sourceURL.lastPathComponent)': \(error)")
                        }
                        seekWithinReel(reel, timelineFrame: currentFrame, resumeAfterSeek: true) {}
                    }
                } else if currentPlayer?.rate == 0 {
                    currentPlayer?.play()
                }
            }

            // Start audio clips
            startActiveAudioClips()
        } else {
            if controlPlayback {
                // MTC stopped and automatic pause is enabled.
                isPlaying = false
                stopGapPlayback()
                stopAllAudioClips()
                currentPlayer?.pause()
            } else if isPlaying && isInGap {
                // Continue manual playback on the internal clock after MTC ends.
                startGapPlayback()
            }
        }
    }

    private func resetSeekState() {
        isSeeking = false
        pendingSeekFrame = nil
    }

    /// Seeks to a specific timeline frame.
    ///
    /// The frame is clamped to valid range. If playing, playback resumes after the seek completes.
    /// Rapid seek requests are coalesced to avoid overwhelming the player.
    ///
    /// - Parameter frame: Target frame number (0-based).
    func seekToFrame(_ frame: Int) {
        // Use timeline.config.durationFrames directly (not cached durationFrames)
        // so we always have the current duration, even after timeline extension
        let clampedFrame = max(0, min(frame, timeline.config.durationFrames - 1))
        currentFrame = clampedFrame
        updateCurrentTimecode()

        // Notify TransportActor of frame update
        if let onFrameUpdate = onFrameUpdate {
            Task { await onFrameUpdate(currentFrame) }
        }

        pendingSeekFrame = clampedFrame
        performPendingSeekIfNeeded()
    }

    /// Seeks to a specific timecode.
    ///
    /// Converts the timecode to a frame number using the timeline configuration.
    ///
    /// - Parameter timecode: Target timecode.
    func seekToTimecode(_ timecode: Timecode) {
        let frame = timeline.config.frame(for: timecode)
        seekToFrame(frame)
    }

    /// Syncs to an MTC timecode received from external sync.
    ///
    /// MINIMAL approach: Just update timeline position for display purposes.
    /// Let video play naturally - only seek for MAJOR drift (transport jump, reel change).
    /// This prevents the constant seeking that causes stuttering.
    ///
    /// - Parameter timecode: MTC timecode from external source.
    func syncToMTC(_ timecode: Timecode) {
        let mtcFrame = timeline.config.frame(for: timecode)

        // Clamp to valid range
        let targetFrame: Int
        if mtcFrame < 0 {
            targetFrame = 0
        } else if mtcFrame >= timeline.config.durationFrames {
            targetFrame = max(0, timeline.config.durationFrames - 1)
        } else {
            targetFrame = mtcFrame
        }

        // Detect MTC jump (user clicked timeline) vs normal playback
        // During normal playback, MTC increments smoothly (1-2 frames per update)
        // When user clicks timeline, MTC jumps discontinuously
        let previousMtcTarget = mtcTargetFrame
        let mtcJump = abs(targetFrame - previousMtcTarget)
        let isDiscontinuousJump = mtcJump > 10 && previousMtcTarget > 0  // >10 frames = user action

        // Update MTC target (used by time observer for drift detection)
        mtcTargetFrame = targetFrame

        // Handle gap transitions
        let targetReel = timeline.videoReel(at: targetFrame)
        if targetReel == nil {
            // MTC is in a gap
            if !isInGap {
                isInGap = true
                activeReel = nil
                currentPlayer?.pause()
                stopAllAudioClips()
            }
            currentFrame = targetFrame
            updateCurrentTimecode()

            // Notify TransportActor of frame update
            if let onFrameUpdate = onFrameUpdate {
                Task { await onFrameUpdate(currentFrame) }
            }

            // Sync audio even in gaps (will stop clips that shouldn't play, start ones that should)
            if isDiscontinuousJump {
                syncAudioClips()
            }
            return
        }

        // Check for reel transitions - this REQUIRES a seek
        if let reel = targetReel, reel.id != currentReelId {
            isInGap = false
            activeReel = reel
            currentFrame = targetFrame
            updateCurrentTimecode()

            // Notify TransportActor of frame update
            if let onFrameUpdate = onFrameUpdate {
                Task { await onFrameUpdate(currentFrame) }
            }

            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.loadReel(reel)
                } catch {
                    debugPrint("PlaybackEngine.handleExternalSeek: Failed to load reel '\(reel.sourceURL.lastPathComponent)': \(error)")
                }
                self.seekWithinReel(reel, timelineFrame: targetFrame, resumeAfterSeek: true) { [weak self] in
                    self?.syncAudioClips()
                }
            }
            return
        }

        // Same reel - only seek if MTC jumped discontinuously (user clicked timeline)
        //
        // `activeReel` is refreshed here as well as on a reel change: timecode
        // arrives while the receiver is still freewheeling, before the locked
        // sync that would otherwise set it, and `handleTimeUpdate` will not
        // advance the timeline without it.
        isInGap = false
        activeReel = targetReel
        currentFrame = targetFrame
        updateCurrentTimecode()

        if isDiscontinuousJump {
            // MTC jumped discontinuously - user clicked timeline, seek to new position
            if let reel = activeReel {
                seekWithinReel(reel, timelineFrame: targetFrame, resumeAfterSeek: true) { [weak self] in
                    self?.syncAudioClips()
                }
            }
        }
        // For continuous MTC (normal playback): video plays naturally, no seeking
    }

    /// Legacy method - redirects to syncToMTC
    func seekToMTC(_ timecode: Timecode) {
        syncToMTC(timecode)
    }

    /// Steps forward by one frame.
    func stepForward() {
        seekToFrame(currentFrame + 1)
    }

    /// Steps backward by one frame.
    func stepBackward() {
        seekToFrame(currentFrame - 1)
    }

    /// Sets the audio output device for both video and audio playback.
    ///
    /// Updates the AVPlayer audio device and reconfigures the audio engine
    /// to use the specified device's channel count and sample rate.
    ///
    /// - Parameter deviceUID: CoreAudio device UID, or `nil` for system default.
    func setAudioOutputDevice(_ deviceUID: String?) {
        audioOutputDeviceUID = deviceUID
        currentPlayer?.audioOutputDeviceUniqueID = deviceUID
        preloadPlayer?.audioOutputDeviceUniqueID = deviceUID
        updateAudioOutputDeviceSettings()

        debugPrint("setAudioOutputDevice: UID=\(deviceUID ?? "nil"), DeviceID=\(audioOutputDeviceID ?? 0), Channels=\(audioOutputChannelCount)")
        diagnosticLog(.info, .audio, "Output device set: UID=\(deviceUID ?? "none"), channels=\(audioOutputChannelCount)")

        reconfigureAudioEngineForOutputChange()
    }

    // MARK: - Private Methods - Video

    /// Get or load asset for a reel
    /// Security-scoped access is managed by TimelineManager.addVideoReel and stays active
    /// until the reel is removed from the timeline
    private func getAsset(for reel: VideoReel) async throws -> AVAsset {
        if let cached = assetCache[reel.id] {
            return cached
        }

        // Use source URL directly - security access is managed by TimelineManager
        debugPrint("getAsset: using source URL for \(reel.displayName)")
        let asset = AVAsset(url: reel.sourceURL)
        assetCache[reel.id] = asset
        return asset
    }

    /// Whether a seek is currently in progress (prevents overlapping seeks)
    private var isSeekingVideo = false

    /// Target frame for pending seek (coalesces rapid seeks)
    private var pendingVideoSeekFrame: Int?

    private func seekWithinReel(
        _ reel: VideoReel,
        timelineFrame: Int,
        resumeAfterSeek: Bool,
        completion: @escaping () -> Void
    ) {
        guard let sourceTime = reel.sourceTime(at: timelineFrame),
              let player = currentPlayer else {
            completion()
            return
        }

        // Coalesce rapid seeks - if seek in progress, queue this one
        if isSeekingVideo {
            pendingVideoSeekFrame = timelineFrame
            completion()
            return
        }

        isSeekingVideo = true
        pendingVideoSeekFrame = nil

        let time = CMTime(seconds: sourceTime, preferredTimescale: 600)

        // Use frame-duration tolerance for smoother seeking during playback
        // Zero tolerance is too aggressive and can cause stalls
        let frameDuration = CMTime(seconds: 1.0 / reel.sourceFrameRate.fps, preferredTimescale: 600)
        let tolerance = isMTCSynced ? frameDuration : .zero

        player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] completed in
            Task { @MainActor in
                guard let self else { return }

                self.isSeekingVideo = false

                // Check for pending seek
                if let pending = self.pendingVideoSeekFrame {
                    self.pendingVideoSeekFrame = nil
                    self.seekWithinReel(reel, timelineFrame: pending, resumeAfterSeek: resumeAfterSeek) {}
                } else if completed && resumeAfterSeek && self.isPlaying {
                    self.currentPlayer?.play()
                }
                completion()
            }
        }
    }

    /// Check if we need to preload the next reel
    private func checkPreload() {
        guard let currentReel = activeReel else { return }

        // Calculate time until end of current reel
        let framesUntilEnd = currentReel.timelineEndFrame - currentFrame
        let secondsUntilEnd = Double(framesUntilEnd) / frameRate.fps

        if secondsUntilEnd <= preloadThreshold {
            // Find next reel
            if let nextReel = timeline.sortedVideoReels.first(where: {
                $0.timelineStartFrame >= currentReel.timelineEndFrame
            }), nextReel.id != preloadingReelId {
                preloadReel(nextReel)
            }
        }
    }

    /// Preload a reel for seamless transition
    private func preloadReel(_ reel: VideoReel) {
        preloadingReelId = reel.id

        Task {
            do {
                let asset = try await getAsset(for: reel)
                let isPlayable = try await asset.load(.isPlayable)

                guard isPlayable else { return }

                let playerItem = AVPlayerItem(asset: asset)
                let player = AVPlayer(playerItem: playerItem)
                player.automaticallyWaitsToMinimizeStalling = false
                player.isMuted = true

                await MainActor.run {
                    self.preloadPlayer = player
                }
            } catch {
                debugPrint("PlaybackEngine: Failed to preload reel: \(error)")
            }
        }
    }

    /// Switch to the preloaded player
    private func switchToPreloadedPlayer(_ reel: VideoReel) {
        guard let preload = preloadPlayer, preloadingReelId == reel.id else { return }

        // Pause current
        currentPlayer?.pause()
        removeTimeObserver()

        // Swap players
        currentPlayer = preload
        currentReelId = reel.id
        activeReel = reel
        preloadPlayer = nil
        preloadingReelId = nil

        setupTimeObserver()

        // Start playback if we were playing
        if isPlaying {
            currentPlayer?.play()
        }
    }

    // MARK: - Private Methods - Gap Handling

    /// Timer for advancing time during gaps
    private var gapTimer: Timer?

    /// Start advancing time during a gap
    private func startGapPlayback() {
        stopGapPlayback()

        // Create timer that fires at frame rate on main run loop
        let interval = 1.0 / frameRate.fps
        gapTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.advanceFrameInGap()
            }
        }
        // Ensure timer fires during tracking (scrolling, dragging)
        RunLoop.main.add(gapTimer!, forMode: .common)
    }

    /// Stop gap playback timer
    private func stopGapPlayback() {
        gapTimer?.invalidate()
        gapTimer = nil
    }

    /// Advance one frame during gap playback
    private func advanceFrameInGap() {
        guard isPlaying, isInGap else {
            stopGapPlayback()
            return
        }

        currentFrame += 1
        updateCurrentTimecode()

        // Check if we've exited the gap
        if let reel = timeline.videoReel(at: currentFrame) {
            isInGap = false
            stopGapPlayback()

            // Load and play the reel
            Task {
                do {
                    try await loadReel(reel)
                } catch {
                    debugPrint("PlaybackEngine.advanceGapTime: Failed to load reel '\(reel.sourceURL.lastPathComponent)': \(error)")
                }
                seekWithinReel(reel, timelineFrame: currentFrame, resumeAfterSeek: isPlaying) {}
            }
        }

        // Sync audio clips while advancing without video
        syncAudioClips()

        // Check if we've reached the end
        if currentFrame >= durationFrames {
            pause()
        }
    }

    // MARK: - Private Methods - Audio

    /// Start playing active audio clips at current position
    private func startActiveAudioClips() {
        let activeClips = timeline.activeAudioClips(at: currentFrame)
        let totalClips = timeline.audioLanes.flatMap { $0.clips }.count

        debugPrint("startActiveAudioClips: frame=\(currentFrame), activeClips=\(activeClips.count), totalClips=\(totalClips), lanes=\(timeline.audioLanes.count)")

        guard !activeClips.isEmpty else {
            debugPrint("startActiveAudioClips: no active clips at current frame")
            return
        }

        for (lane, clip) in activeClips {
            debugPrint("startActiveAudioClips: loading clip \(clip.id) from lane \(lane.name)")
            if let playback = audioPlayers[clip.id] {
                syncAudioPlayer(playback, for: clip, lane: lane, shouldPlay: isPlaying)
            } else {
                loadAudioClip(clip, lane: lane)
            }
        }
    }

    /// Load an audio clip for playback
    private func loadAudioClip(_ clip: AudioClip, lane: AudioLane) {
        // Prevent duplicate load attempts while async loading is in progress
        guard !loadingClipIds.contains(clip.id) else {
            return
        }

        // Check cooldown for previously failed clips
        if let failedAt = failedClipCooldowns[clip.id] {
            let elapsed = Date().timeIntervalSince(failedAt)
            if elapsed < failedClipRetryCooldown {
                return // Still in cooldown, skip this attempt
            }
            // Cooldown expired, clear it and retry
            failedClipCooldowns.removeValue(forKey: clip.id)
        }

        // For video tracks 1+, we need an extracted audio file.
        // AVAudioFile can only read track 0 from a video container.
        // If extraction hasn't completed yet, skip loading - we'll retry when invalidated.
        let trackIndex = clip.sourceTrackIndex ?? 0
        if clip.sourceType == .videoTrack && trackIndex > 0 {
            if let extractedURL = clip.extractedAudioURL,
               FileManager.default.fileExists(atPath: extractedURL.path) {
                debugPrint("loadAudioClip: using extracted file for track \(trackIndex)")
            } else {
                // Extraction not complete - skip for now, will be invalidated when ready
                debugPrint("loadAudioClip: track \(trackIndex) not yet extracted, skipping")
                return
            }
        }

        loadingClipIds.insert(clip.id)

        debugPrint("loadAudioClip: starting for clip \(clip.id), sourceType=\(clip.sourceType), trackIndex=\(trackIndex)")
        let clipSnapshot = clip
        let laneSnapshot = lane
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                // Determine which URL to read from:
                // - For video track 0: read directly from video container
                // - For video tracks 1+: read from extracted CAF file
                // - For audio files: read from source URL
                let access: SecurityScopedAccess
                let trackIdx = clipSnapshot.sourceTrackIndex ?? 0
                if clipSnapshot.sourceType == .videoTrack && trackIdx > 0,
                   let extractedURL = clipSnapshot.extractedAudioURL {
                    // Extracted files are in the app's temp directory - no security scope needed
                    access = SecurityScopedAccess(localURL: extractedURL)
                } else {
                    // Read straight from the media, video container included -
                    // `AVAudioFile` opens those directly, and a seek into one costs
                    // about two milliseconds. Copying the audio out first bought
                    // nothing except a second copy of every reel on disk.
                    access = SecurityScopedAccess(for: clipSnapshot)
                }

                let audioFile = try AVAudioFile(forReading: access.url)
                let playback = try await self.buildAudioPlayback(
                    for: clipSnapshot,
                    lane: laneSnapshot,
                    audioFile: audioFile,
                    mediaAccess: access
                )
                await MainActor.run {
                    self.audioPlayers[clipSnapshot.id] = playback
                    self.loadingClipIds.remove(clipSnapshot.id)
                    self.failedClipCooldowns.removeValue(forKey: clipSnapshot.id) // Clear any previous failure
                    self.scheduleAudioPlayback(
                        playback,
                        clip: clipSnapshot,
                        lane: laneSnapshot,
                        shouldPlay: self.isPlaying
                    )
                }
            } catch {
                debugPrint("PlaybackEngine: Failed to load audio clip: \(error)")
                diagnosticLog(.error, .audio, "Failed to load audio clip: \(error.localizedDescription)")
                await MainActor.run {
                    self.loadingClipIds.remove(clipSnapshot.id)
                    self.failedClipCooldowns[clipSnapshot.id] = Date() // Start cooldown
                }
            }
        }
    }






    /// Stop all audio clips
    private func stopAllAudioClips() {
        for playback in audioPlayers.values {
            playback.player.stop()
        }
    }

    /// Sync audio clips to current position
    private func syncAudioClips() {
        // Get currently active clips
        let activeClips = timeline.activeAudioClips(at: currentFrame)
        let activeIds = Set(activeClips.map { $0.clip.id })

        // Remove clips that are no longer active
        for id in Array(audioPlayers.keys) {
            if !activeIds.contains(id) {
                removeAudioPlayback(id: id)
            }
        }

        // Seek active clips
        for (lane, clip) in activeClips {
            if let playback = audioPlayers[clip.id] {
                syncAudioPlayer(playback, for: clip, lane: lane, shouldPlay: isPlaying)
            } else {
                loadAudioClip(clip, lane: lane)
            }
        }
    }

    private func syncAudioPlayer(_ playback: AudioClipPlayback, for clip: AudioClip, lane: AudioLane, shouldPlay: Bool) {
        applyOutputMappingIfNeeded(playback, lane: lane)
        playback.player.volume = clip.volume * lane.volume
        guard let sourceTime = clip.sourceTime(at: currentFrame, masterFrameRate: frameRate) else { return }

        let currentSeconds: Double? = {
            guard let nodeTime = playback.player.lastRenderTime,
                  let playerTime = playback.player.playerTime(forNodeTime: nodeTime) else {
                return nil
            }
            let scheduledBase = playback.scheduledSourceTime ?? sourceTime
            return scheduledBase + (Double(playerTime.sampleTime) / playerTime.sampleRate)
        }()

        guard let currentSeconds else {
            scheduleAudioPlayback(playback, clip: clip, lane: lane, shouldPlay: shouldPlay)
            return
        }

        let drift = abs(currentSeconds - sourceTime)
        let driftThreshold = shouldPlay ? 0.2 : 0.01

        if isSeeking || drift > driftThreshold {
            scheduleAudioPlayback(playback, clip: clip, lane: lane, shouldPlay: shouldPlay)
        }

        if shouldPlay, !playback.player.isPlaying {
            ensureAudioEngineRunning()
            playback.player.play()
        } else if !shouldPlay, playback.player.isPlaying {
            playback.player.pause()
        }
    }

    /// Calculates sample position with NTSC-accurate rounding.
    ///
    /// Standard truncation of `Double(frame) / fps * sampleRate` loses fractional
    /// samples at NTSC rates (29.97, 59.94). This method rounds to nearest sample
    /// for more accurate positioning.
    ///
    /// - Parameters:
    ///   - sourceTime: Time in seconds from clip start
    ///   - sampleRate: Audio file sample rate (e.g., 48000 Hz)
    /// - Returns: Sample position rounded to nearest sample
    ///
    /// ## NTSC Frame Rate Math
    ///
    /// At 29.97 fps with 48kHz audio:
    /// - Samples per frame = 48000 / 29.97 = 1601.6016...
    /// - Frame 1000: truncate(33.3667s * 48000) = 1,601,600
    /// - Frame 1000: round(33.3667s * 48000) = 1,601,602
    ///
    /// Rounding distributes the error symmetrically rather than always losing samples.
    private func samplePosition(sourceTime: Double, sampleRate: Double) -> AVAudioFramePosition {
        let exactSamples = sourceTime * sampleRate
        return AVAudioFramePosition(exactSamples.rounded())
    }

    /// Calculates sample count with NTSC-accurate rounding.
    ///
    /// - Parameters:
    ///   - seconds: Duration in seconds
    ///   - sampleRate: Audio file sample rate
    /// - Returns: Sample count rounded to nearest sample
    private func sampleCount(seconds: Double, sampleRate: Double) -> AVAudioFramePosition {
        let exactSamples = seconds * sampleRate
        return AVAudioFramePosition(exactSamples.rounded())
    }

    private func scheduleAudioPlayback(
        _ playback: AudioClipPlayback,
        clip: AudioClip,
        lane: AudioLane,
        shouldPlay: Bool
    ) {
        guard let sourceTime = clip.sourceTime(at: currentFrame, masterFrameRate: frameRate) else {
            debugPrint("SCHEDULE: clip \(clip.id) not active at frame \(currentFrame) - nothing scheduled")
            return
        }

        let file = playback.audioFile
        let sampleRate = file.processingFormat.sampleRate

        // Use rounded sample positions for NTSC frame rate accuracy
        // Truncation at 29.97 fps loses ~0.6 samples/frame, causing drift over time
        let startFrame = samplePosition(sourceTime: sourceTime, sampleRate: sampleRate)
        let remainingSeconds = Double(max(0, clip.timelineEndFrame - currentFrame)) / frameRate.fps
        let maxFrames = sampleCount(seconds: remainingSeconds, sampleRate: sampleRate)
        let availableFrames = max(0, file.length - startFrame)
        let frameCount = AVAudioFrameCount(min(Double(availableFrames), Double(maxFrames)))

        debugPrint("SCHEDULE: lane=\(lane.name) sourceTime=\(String(format: "%.3f", sourceTime))s "
                   + "startFrame=\(startFrame) fileLength=\(file.length) available=\(availableFrames) "
                   + "maxFrames=\(maxFrames) frameCount=\(frameCount) shouldPlay=\(shouldPlay) "
                   + "vol=\(clip.volume * lane.volume)")

        guard frameCount > 0 else {
            debugPrint("SCHEDULE: NOTHING SCHEDULED for lane \(lane.name) - frameCount is 0")
            return
        }

        playback.player.stop()
        playback.player.volume = clip.volume * lane.volume
        playback.player.scheduleSegment(file, startingFrame: startFrame, frameCount: frameCount, at: nil)
        playback.scheduledSourceTime = sourceTime
        if shouldPlay {
            ensureAudioEngineRunning()
            // CRITICAL: Configure MatrixMixer routing AFTER engine is running
            // Parameters set before engine.start() cause silent output
            configureMatrixMixerRouting(
                playback.matrixMixer,
                inputChannelCount: playback.inputChannelCount,
                outputOffset: playback.outputChannelOffset,
                outputCount: playback.outputChannelCount,
                isolatedChannel: playback.isolatedChannel
            )
            playback.player.play()
        }
    }

    private func buildAudioPlayback(
        for clip: AudioClip,
        lane: AudioLane,
        audioFile: AVAudioFile,
        mediaAccess: SecurityScopedAccess?
    ) async throws -> AudioClipPlayback {
        configureAudioEngineIfNeeded()

        let player = AVAudioPlayerNode()
        let rateConverter = AVAudioMixerNode()
        let matrixMixer = try await makeMatrixMixer()
        let inputFormat = audioFile.processingFormat

        // Use SOURCE sample rate for internal audio chain to maintain sync
        // The final mixer->output connection handles device rate conversion
        // Using device rate internally causes timing drift with video
        let sourceSampleRate = max(8000, inputFormat.sampleRate)
        let intermediateFormat = AVAudioFormat(
            standardFormatWithSampleRate: sourceSampleRate,
            channels: inputFormat.channelCount
        ) ?? inputFormat

        // Create multi-channel output format for MatrixMixer -> MainMixer connection
        // This must use the device's channel count to enable routing to outputs 3-6
        let desiredOutputChannels = AVAudioChannelCount(max(2, audioOutputChannelCount))
        debugPrint("buildAudioPlayback: audioOutputChannelCount=\(audioOutputChannelCount), desiredOutputChannels=\(desiredOutputChannels), sourceSampleRate=\(sourceSampleRate)")

        // For >2 channels, AVAudioFormat requires a channel layout
        // Use Unknown layout tag for multi-output audio interfaces (DiscreteInOrder causes silent output)
        let multiChannelOutputFormat: AVAudioFormat
        if desiredOutputChannels > 2 {
            // Create channel layout with Unknown tag - works best for multi-output interfaces
            let layoutTag = kAudioChannelLayoutTag_Unknown | UInt32(desiredOutputChannels)
            if let channelLayout = AVAudioChannelLayout(layoutTag: layoutTag) {
                let format = AVAudioFormat(standardFormatWithSampleRate: sourceSampleRate, channelLayout: channelLayout)
                multiChannelOutputFormat = format
                debugPrint("Created \(desiredOutputChannels)-channel format with Unknown layout at \(sourceSampleRate)Hz")
            } else {
                // Fallback: try using the main mixer's output format
                let mixerFormat = audioEngine.mainMixerNode.outputFormat(forBus: 0)
                if mixerFormat.channelCount >= desiredOutputChannels {
                    multiChannelOutputFormat = mixerFormat
                    debugPrint("Using mainMixerNode format: \(mixerFormat.channelCount) channels")
                } else {
                    multiChannelOutputFormat = intermediateFormat
                    debugPrint("WARNING: Falling back to intermediate format (\(intermediateFormat.channelCount) channels)")
                }
            }
        } else {
            multiChannelOutputFormat = AVAudioFormat(
                standardFormatWithSampleRate: sourceSampleRate,
                channels: desiredOutputChannels
            ) ?? intermediateFormat
        }

        audioEngine.attach(player)
        audioEngine.attach(rateConverter)
        audioEngine.attach(matrixMixer)

        // Debug: log format information
        debugPrint("Audio formats - Source: \(inputFormat.sampleRate)Hz/\(inputFormat.channelCount)ch, " +
              "Chain: \(intermediateFormat.sampleRate)Hz/\(intermediateFormat.channelCount)ch, " +
              "MultiCh: \(multiChannelOutputFormat.sampleRate)Hz/\(multiChannelOutputFormat.channelCount)ch")

        // Player -> RateConverter: mixer handles sample rate conversion automatically
        audioEngine.connect(player, to: rateConverter, format: inputFormat)

        // RateConverter -> MatrixMixer: intermediate format with correct sample rate
        audioEngine.connect(rateConverter, to: matrixMixer, format: intermediateFormat)

        // MatrixMixer -> MainMixer: use full device channel count for multi-channel routing
        audioEngine.connect(matrixMixer, to: audioEngine.mainMixerNode, format: multiChannelOutputFormat)

        let inputChannelCount = Int(inputFormat.channelCount)

        // NOTE: MatrixMixer routing is configured in scheduleAudioPlayback() AFTER engine starts
        // Setting parameters before engine.start() causes silent output

        let playback = AudioClipPlayback(
            clipId: clip.id,
            player: player,
            rateConverter: rateConverter,
            matrixMixer: matrixMixer,
            audioFile: audioFile,
            inputChannelCount: inputChannelCount,
            isolatedChannel: clip.sourceChannel?.channelIndex,
            mediaAccess: mediaAccess,
            outputMappingId: lane.outputMappingId,
            outputChannelOffset: lane.outputChannelOffset,
            outputChannelCount: lane.outputChannelCount
        )
        return playback
    }

    /// Drop a clip's loaded audio so it is read again from its current file.
    ///
    /// Players are cached by clip id, and a clip whose `extractedAudioURL`
    /// changes keeps the same id - so without this it plays whatever file it was
    /// first loaded from, forever. That bites when a hard-panned video is split:
    /// the new lanes exist before their per-channel files are written, load the
    /// whole stereo track in the meantime, and would then keep playing both
    /// sides on both lanes even after the mono files arrive.
    ///
    /// Also clears the failure cooldown, since a clip that could not be loaded
    /// from the old file deserves an immediate try at the new one.
    ///
    /// - Parameter id: The clip whose audio source changed.
    func invalidateAudioClip(id: UUID) {
        removeAudioPlayback(id: id)
        failedClipCooldowns.removeValue(forKey: id)
        loadingClipIds.remove(id)
    }

    private func removeAudioPlayback(id: UUID) {
        guard let playback = audioPlayers[id] else { return }
        playback.player.stop()
        audioEngine.detach(playback.player)
        audioEngine.detach(playback.rateConverter)
        audioEngine.detach(playback.matrixMixer)
        audioPlayers.removeValue(forKey: id)
    }

    private func applyOutputMappingIfNeeded(_ playback: AudioClipPlayback, lane: AudioLane) {
        let mappingChanged = playback.outputMappingId != lane.outputMappingId
            || playback.outputChannelOffset != lane.outputChannelOffset
            || playback.outputChannelCount != lane.outputChannelCount

        guard mappingChanged else { return }

        playback.outputMappingId = lane.outputMappingId
        playback.outputChannelOffset = lane.outputChannelOffset
        playback.outputChannelCount = lane.outputChannelCount

        configureMatrixMixerRouting(
            playback.matrixMixer,
            inputChannelCount: playback.inputChannelCount,
            outputOffset: lane.outputChannelOffset,
            outputCount: lane.outputChannelCount,
            isolatedChannel: playback.isolatedChannel
        )
    }

    private func makeMatrixMixer() async throws -> AVAudioUnit {
        let description = AudioComponentDescription(
            componentType: kAudioUnitType_Mixer,
            componentSubType: kAudioUnitSubType_MatrixMixer,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        return try await AVAudioUnit.instantiate(with: description, options: [])
    }

    /// Configures the matrix mixer crosspoints for channel routing
    ///
    /// - Parameters:
    ///   - matrixMixer: The AUMatrixMixer audio unit to configure
    ///   - inputChannelCount: Number of input channels from the audio source
    ///   - outputOffset: The starting output channel index (e.g., 2 for outputs 3-4)
    ///   - outputCount: Number of output channels to route to
    ///   - isolatedChannel: A single input channel to take, ignoring the rest.
    ///     Set for a lane holding one side of a hard-panned source, which reads
    ///     the ordinary stereo file and selects its half here rather than
    ///     playing a mono copy written to disk for the purpose.
    private func configureMatrixMixerRouting(
        _ matrixMixer: AVAudioUnit,
        inputChannelCount: Int,
        outputOffset: Int,
        outputCount: Int,
        isolatedChannel: Int? = nil
    ) {
        let audioUnit = matrixMixer.audioUnit
        let totalOutputChannels = max(2, audioOutputChannelCount)
        var status: OSStatus

        debugPrint("configureMatrixMixerRouting: engine.isRunning=\(audioEngine.isRunning), inputs=\(inputChannelCount), outputs=\(totalOutputChannels)")

        // Set global volume
        status = AudioUnitSetParameter(audioUnit, kMatrixMixerParam_Volume,
                              kAudioUnitScope_Global, 0xFFFF_FFFF, 1.0, 0)
        if status != noErr { debugPrint("MatrixMixer global volume error: \(status)") }

        // Set input channel volumes
        for i in 0..<inputChannelCount {
            status = AudioUnitSetParameter(audioUnit, kMatrixMixerParam_Volume,
                                  kAudioUnitScope_Input, UInt32(i), 1.0, 0)
            if status != noErr { debugPrint("MatrixMixer input[\(i)] volume error: \(status)") }
        }

        // Set output channel volumes
        for i in 0..<totalOutputChannels {
            status = AudioUnitSetParameter(audioUnit, kMatrixMixerParam_Volume,
                                  kAudioUnitScope_Output, UInt32(i), 1.0, 0)
            if status != noErr { debugPrint("MatrixMixer output[\(i)] volume error: \(status)") }
        }

        // Clear all crosspoints first (silence)
        for inputCh in 0..<inputChannelCount {
            for outputCh in 0..<totalOutputChannels {
                let crossPoint = UInt32((inputCh << 16) | outputCh)
                status = AudioUnitSetParameter(audioUnit, kMatrixMixerParam_Volume,
                                      kAudioUnitScope_Global, crossPoint, 0.0, 0)
                if status != noErr { debugPrint("MatrixMixer crosspoint[\(inputCh)->\(outputCh)] clear error: \(status)") }
            }
        }

        // Set desired routing crosspoints
        let availableOutputs = totalOutputChannels - outputOffset
        let outputsToFill = min(outputCount, availableOutputs)

        func setCrosspoint(input inputCh: Int, output outputCh: Int) {
            let crossPoint = UInt32((inputCh << 16) | outputCh)
            let result = AudioUnitSetParameter(audioUnit, kMatrixMixerParam_Volume,
                                               kAudioUnitScope_Global, crossPoint, 1.0, 0)
            if result != noErr { debugPrint("MatrixMixer crosspoint[\(inputCh)->\(outputCh)] set error: \(result)") }
        }

        if let isolatedChannel, isolatedChannel < inputChannelCount {
            // One side of a hard-panned source, taken straight from the stereo
            // file. Only this input is given a crosspoint, so the other side is
            // simply never mixed in - the same result an extracted mono file
            // gave, without writing one.
            //
            // It feeds every output channel, which is what un-pans it: a side
            // that was hard left comes back centred.
            for offset in 0..<outputsToFill {
                setCrosspoint(input: isolatedChannel, output: outputOffset + offset)
            }
            debugPrint("MatrixMixer configured: input \(isolatedChannel) only -> outputs "
                       + "\(outputOffset)-\(outputOffset + outputsToFill - 1) (isolated, duplicated)")
        } else if inputChannelCount == 1 && outputsToFill > 1 {
            // A mono source feeds every channel of its output rather than only
            // the first. Mapping straight down the diagonal would send it to the
            // left of a stereo pair and leave the right silent, so the lane would
            // play hard left through no choice of the user's.
            for offset in 0..<outputsToFill {
                setCrosspoint(input: 0, output: outputOffset + offset)
            }
            debugPrint("MatrixMixer configured: mono input -> outputs \(outputOffset)-\(outputOffset + outputsToFill - 1) (duplicated)")
        } else {
            let channelsToMap = min(inputChannelCount, outputsToFill)
            for i in 0..<channelsToMap {
                setCrosspoint(input: i, output: outputOffset + i)
            }
            debugPrint("MatrixMixer configured: \(inputChannelCount) inputs -> outputs \(outputOffset)-\(outputOffset + channelsToMap - 1)")
        }
    }

    private func configureAudioEngineIfNeeded() {
        guard audioOutputFormat == nil else { return }
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        let outputNode = audioEngine.outputNode
        applyAudioOutputDevice()

        // Query node format for sample rate only - don't trust its channel count
        // The node format reflects current state, not device capability
        let outputNodeFormat = outputNode.inputFormat(forBus: 0)
        if outputNodeFormat.channelCount > 0, outputNodeFormat.sampleRate > 0 {
            audioOutputSampleRate = outputNodeFormat.sampleRate
        }

        // Always use device-queried channel count from audioOutputChannelCount
        // Don't overwrite with node format - it may report 2ch even for 6ch devices
        audioOutputFormat = makeOutputFormat()

        debugPrint("configureAudioEngineIfNeeded: Using \(audioOutputChannelCount) channels at \(audioOutputSampleRate)Hz")

        audioEngine.disconnectNodeOutput(audioEngine.mainMixerNode)
        audioEngine.connect(audioEngine.mainMixerNode, to: outputNode, format: audioOutputFormat)
    }

    private func ensureAudioEngineRunning() {
        configureAudioEngineIfNeeded()
        guard !audioEngine.isRunning else { return }

        do {
            try audioEngine.start()
            applyAudioOutputDevice()
            synchronizeOutputFormatIfNeeded()
            #if DEBUG
            installOutputMeterTap()
            #endif
        } catch {
            debugPrint("PlaybackEngine: Failed to start audio engine: \(error)")
        }
    }

    #if DEBUG
    private static var meterTapInstalled = false
    private static var meterWasLive = false

    /// Report which output channels actually carry signal.
    ///
    /// Diagnostic only. Routing can be configured perfectly and still be
    /// inaudible if it lands on channels nobody is monitoring, and the logs
    /// above cannot tell those two cases apart - they say where audio was
    /// *sent*, not whether anything came out. This measures the engine's real
    /// output.
    private func installOutputMeterTap() {
        guard !Self.meterTapInstalled else { return }
        Self.meterTapInstalled = true

        let node = audioEngine.mainMixerNode
        let format = node.outputFormat(forBus: 0)
        guard format.channelCount > 0 else { return }

        node.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return }
            var live: [String] = []
            for channel in 0..<Int(buffer.format.channelCount) {
                var energy: Float = 0
                for frame in 0..<Int(buffer.frameLength) {
                    let sample = data[channel][frame]
                    energy += sample * sample
                }
                let rms = (energy / Float(buffer.frameLength)).squareRoot()
                if rms > 0.0001 {
                    live.append(String(format: "ch%d=%.4f", channel + 1, rms))
                }
            }
            if live.isEmpty {
                // Silent buffers are the normal resting state; logging every one
                // buries everything else. Only the transitions matter.
                if Self.meterWasLive {
                    Self.meterWasLive = false
                    debugPrint("METER: went silent")
                }
            } else {
                Self.meterWasLive = true
                debugPrint("METER: signal on \(live.joined(separator: " "))")
            }
        }
        debugPrint("METER: tap installed on mainMixer (\(format.channelCount)ch)")
    }
    #endif

    private func synchronizeOutputFormatIfNeeded() {
        guard audioPlayers.isEmpty else { return }
        let nodeFormat = audioEngine.outputNode.inputFormat(forBus: 0)
        guard nodeFormat.channelCount > 0 else { return }

        let needsUpdate = audioOutputFormat?.channelCount != nodeFormat.channelCount
            || audioOutputFormat?.sampleRate != nodeFormat.sampleRate
        guard needsUpdate else { return }

        audioEngine.stop()
        audioEngine.disconnectNodeOutput(audioEngine.mainMixerNode)
        audioOutputChannelCount = Int(nodeFormat.channelCount)
        audioOutputSampleRate = nodeFormat.sampleRate
        audioOutputFormat = nodeFormat
        audioEngine.connect(audioEngine.mainMixerNode, to: audioEngine.outputNode, format: nodeFormat)

        do {
            try audioEngine.start()
            applyAudioOutputDevice()
        } catch {
            debugPrint("PlaybackEngine: Failed to restart audio engine: \(error)")
        }
    }

    private func applyAudioOutputDevice() {
        guard let deviceID = audioOutputDeviceID else { return }
        guard let audioUnit = audioEngine.outputNode.audioUnit else { return }
        var outputDeviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &outputDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            debugPrint("PlaybackEngine: Failed to set output device: \(status)")
        }
    }

    private func makeOutputFormat() -> AVAudioFormat {
        let channels = max(1, audioOutputChannelCount)
        let sampleRate = max(8000, audioOutputSampleRate)

        // For > 2 channels, we must use a channel layout
        // kAudioChannelLayoutTag_Unknown works best for multi-output interfaces
        if channels > 2 {
            let layoutTag = kAudioChannelLayoutTag_Unknown | UInt32(channels)
            if let channelLayout = AVAudioChannelLayout(layoutTag: layoutTag) {
                let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channelLayout: channelLayout)
                debugPrint("makeOutputFormat: Created \(channels)-channel format with Unknown layout")
                return format
            }
            debugPrint("WARNING: makeOutputFormat failed to create \(channels)-channel layout")
        }

        // Try to create format with requested parameters, fall back to safe defaults
        if let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels)) {
            debugPrint("makeOutputFormat: Created \(format.channelCount)-channel standard format")
            return format
        }

        // Fallback: try 48kHz stereo (most universally supported)
        if let fallbackFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2) {
            debugPrint("WARNING: makeOutputFormat failed for \(channels)ch/\(sampleRate)Hz, using 48kHz stereo fallback")
            return fallbackFormat
        }

        // Last resort: try 44.1kHz stereo
        if let lastResort = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2) {
            debugPrint("WARNING: makeOutputFormat using 44.1kHz stereo as last resort")
            return lastResort
        }

        // Final fallback: try 44.1kHz mono (should always work)
        if let monoFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1) {
            debugPrint("CRITICAL: makeOutputFormat using 44.1kHz mono as emergency fallback")
            return monoFormat
        }

        // This should truly never happen - log and return a manually constructed format
        debugPrint("CRITICAL: All standard AVAudioFormat initializers failed - CoreAudio may be corrupted")
        // Construct format directly from AudioStreamBasicDescription as absolute last resort
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 44100,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        // Force unwrap is safe here - we're using known-valid ASBD parameters
        return AVAudioFormat(streamDescription: &asbd)!
    }

    private func updateAudioOutputDeviceSettings() {
        // Remove any existing sample rate listener before changing devices
        removeSampleRateListener()

        if let uid = audioOutputDeviceUID, let deviceID = deviceID(for: uid) {
            audioOutputDeviceID = deviceID
        } else {
            audioOutputDeviceID = defaultOutputDeviceID()
            if audioOutputDeviceUID != nil {
                debugPrint("WARNING: Device '\(audioOutputDeviceUID!)' not found, using system default")
            }
        }

        if let deviceID = audioOutputDeviceID {
            let queriedChannels = outputChannelCount(for: deviceID)
            audioOutputChannelCount = max(1, queriedChannels)
            audioOutputSampleRate = outputSampleRate(for: deviceID) ?? audioOutputSampleRate
            debugPrint("updateAudioOutputDeviceSettings: DeviceID=\(deviceID), QueriedChannels=\(queriedChannels), FinalChannels=\(audioOutputChannelCount)")

            // Set up listener for sample rate changes on this device
            setupSampleRateListener(for: deviceID)
        } else {
            audioOutputChannelCount = 2
            audioOutputSampleRate = 48000
            debugPrint("updateAudioOutputDeviceSettings: No device, defaulting to 2 channels")
        }
    }

    /// Sets up a CoreAudio property listener for sample rate changes on the specified device.
    ///
    /// When the device's sample rate changes (e.g., user changes it in Audio MIDI Setup,
    /// or the device switches to match an incoming digital signal), this listener triggers
    /// a reconfiguration of the audio engine to maintain correct playback.
    ///
    /// - Parameter deviceID: The CoreAudio device ID to monitor
    ///
    /// ## Sample Rate Handling
    ///
    /// Sample rate changes must be
    /// detected and handled to prevent:
    /// - Audio playback at wrong speed
    /// - Buffer underruns from mismatched rates
    /// - Timing drift with video
    private func setupSampleRateListener(for deviceID: AudioDeviceID) {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        sampleRateListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                self.handleSampleRateChange()
            }
        }

        let status = AudioObjectAddPropertyListenerBlock(
            deviceID,
            &propertyAddress,
            sampleRateListenerQueue,
            sampleRateListenerBlock!
        )

        if status != noErr {
            debugPrint("PlaybackEngine: Failed to add sample rate listener: \(status)")
        } else {
            debugPrint("PlaybackEngine: Sample rate listener installed for device \(deviceID)")
        }
    }

    /// Removes the sample rate change listener from the current device.
    ///
    /// Must be called before changing devices or during cleanup to prevent
    /// dangling callbacks to deallocated objects.
    private func removeSampleRateListener() {
        guard let deviceID = audioOutputDeviceID,
              let listenerBlock = sampleRateListenerBlock else { return }

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectRemovePropertyListenerBlock(
            deviceID,
            &propertyAddress,
            sampleRateListenerQueue,
            listenerBlock
        )

        if status != noErr {
            debugPrint("PlaybackEngine: Failed to remove sample rate listener: \(status)")
        }

        sampleRateListenerBlock = nil
    }

    /// Handles a sample rate change notification from CoreAudio.
    ///
    /// Queries the new sample rate and reconfigures the audio engine if it differs
    /// from the cached rate. This ensures playback continues at the correct speed
    /// when the device's sample rate changes.
    private func handleSampleRateChange() {
        guard let deviceID = audioOutputDeviceID else { return }

        let newSampleRate = outputSampleRate(for: deviceID) ?? audioOutputSampleRate
        guard newSampleRate != audioOutputSampleRate else { return }

        debugPrint("PlaybackEngine: Sample rate changed from \(audioOutputSampleRate) to \(newSampleRate)")
        audioOutputSampleRate = newSampleRate

        // Reconfigure the audio engine with the new sample rate
        reconfigureAudioEngineForOutputChange()
    }

    private func reconfigureAudioEngineForOutputChange() {
        let wasPlaying = isPlaying
        stopAllAudioClips()
        audioEngine.stop()
        audioEngine.reset()
        audioOutputFormat = nil

        for id in Array(audioPlayers.keys) {
            removeAudioPlayback(id: id)
        }

        if wasPlaying {
            startActiveAudioClips()
        }
    }


    private static func exportAudioLegacy(_ export: AVAssetExportSession) async throws {
        let box = ExportSessionBox(session: export)
        try await withCheckedThrowingContinuation { continuation in
            box.session.exportAsynchronously {
                switch box.session.status {
                case .completed:
                    continuation.resume(returning: ())
                case .failed:
                    continuation.resume(throwing: box.session.error ?? PlaybackEngineError.audioExtractionFailed)
                case .cancelled:
                    continuation.resume(throwing: PlaybackEngineError.audioExtractionFailed)
                case .unknown, .waiting, .exporting:
                    continuation.resume(throwing: PlaybackEngineError.audioExtractionFailed)
                @unknown default:
                    continuation.resume(throwing: PlaybackEngineError.audioExtractionFailed)
                }
            }
        }
    }

    private func deviceID(for uid: String) -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var propertySize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize
        )

        guard status == noErr, propertySize > 0 else { return nil }

        let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = Array(repeating: AudioDeviceID(0), count: deviceCount)

        let fetchStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &deviceIDs
        )

        guard fetchStatus == noErr else { return nil }

        for deviceID in deviceIDs {
            if uid == deviceUID(for: deviceID) {
                return deviceID
            }
        }
        return nil
    }

    private func deviceUID(for deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var propertySize = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
        var uid: Unmanaged<CFString>?
        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &propertySize, &uid)
        guard status == noErr, let uidValue = uid?.takeRetainedValue() else { return nil }
        return uidValue as String
    }

    private func defaultOutputDeviceID() -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &deviceID
        )
        return status == noErr ? deviceID : nil
    }

    private func outputChannelCount(for deviceID: AudioDeviceID) -> Int {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var propertySize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &propertySize)
        guard status == noErr, propertySize > 0 else { return 0 }

        let bufferListPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(propertySize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferListPointer.deallocate() }

        let result = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &propertySize, bufferListPointer)
        guard result == noErr else { return 0 }

        let audioBufferList = bufferListPointer.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private func outputSampleRate(for deviceID: AudioDeviceID) -> Double? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate = Float64(0)
        var propertySize = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &propertySize, &sampleRate)
        return status == noErr ? sampleRate : nil
    }

    // MARK: - Private Methods - Time Observation

    /// Setup time observer for current player
    private func setupTimeObserver() {
        guard let player = currentPlayer else { return }

        // Use a standard video timescale (600 is common for 24/30/60fps content)
        // Observer fires once per frame at the timeline's frame rate
        let interval = CMTime(seconds: 1.0 / frameRate.fps, preferredTimescale: 600)

        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.handleTimeUpdate()
            }
        }
    }

    /// Remove time observer
    private func removeTimeObserver() {
        if let observer = timeObserver {
            currentPlayer?.removeTimeObserver(observer)
            timeObserver = nil
        }
    }

    /// Frame counter for throttled audio sync
    private var lastAudioSyncFrame: Int = -1

    /// Handle periodic time update
    ///
    /// IMPORTANT: This fires at frame rate (24-60 fps). Keep it minimal to avoid stuttering.
    /// Do NOT manipulate player.rate or seek frequently - that causes micro-stalls.
    private func handleTimeUpdate() {
        guard !isSeeking, let reel = activeReel, let player = currentPlayer else { return }

        // In MTC sync mode, let video play naturally while correcting drift at
        // the user-configured frame threshold. Corrections are rate-limited to
        // avoid repeated seeks while a decoder is settling.
        if isMTCSynced {
            // Use integer arithmetic to avoid floating-point drift over time.
            // Frame = time * fps = (value/timescale) * (num/denom) = (value * num) / (timescale * denom)
            let playerTime = player.currentTime()
            let sourceFrame = Int(
                Int64(playerTime.value) * Int64(reel.sourceFrameRate.rationalNumerator) /
                (Int64(playerTime.timescale) * Int64(reel.sourceFrameRate.rationalDenominator))
            )
            let videoFrame = (sourceFrame - reel.sourceStartFrame) + reel.timelineStartFrame

            let absDrift = abs(videoFrame - mtcTargetFrame)
            let driftThreshold = max(1, AppSettings.shared.syncDriftThreshold)
            let now = Date()
            let canResync = now.timeIntervalSince(lastMTCResyncTime) >= minimumMTCResyncInterval

            if absDrift > driftThreshold && canResync && !isSeekingVideo {
                lastMTCResyncTime = now
                seekWithinReel(reel, timelineFrame: mtcTargetFrame, resumeAfterSeek: true) {}
            }
            return
        }

        // Not in MTC mode - video position drives timeline position
        // Use integer arithmetic to avoid floating-point drift over time.
        let playerTime = player.currentTime()
        let sourceFrame = Int(
            Int64(playerTime.value) * Int64(reel.sourceFrameRate.rationalNumerator) /
            (Int64(playerTime.timescale) * Int64(reel.sourceFrameRate.rationalDenominator))
        )
        let videoFrame = (sourceFrame - reel.sourceStartFrame) + reel.timelineStartFrame

        if videoFrame != currentFrame {
            let previousFrame = currentFrame
            currentFrame = max(0, videoFrame)
            updateCurrentTimecode()

            // Notify TransportActor of frame update
            if let onFrameUpdate = onFrameUpdate {
                Task { await onFrameUpdate(currentFrame) }
            }

            // Check for reel boundary
            if currentFrame >= reel.timelineEndFrame {
                handleReelEnd()
            }

            // Check for preload
            checkPreload()

            // Throttle audio sync - only sync every ~30 frames to reduce load
            let framesSinceLastSync = abs(currentFrame - lastAudioSyncFrame)
            let isSignificantJump = abs(currentFrame - previousFrame) > 5
            if framesSinceLastSync >= 30 || isSignificantJump || lastAudioSyncFrame < 0 {
                syncAudioClips()
                lastAudioSyncFrame = currentFrame
            }
        }
    }

    /// Handle reaching end of current reel
    private func handleReelEnd() {
        guard let currentReel = activeReel else { return }

        // Check if there's a next reel
        if let nextReel = timeline.sortedVideoReels.first(where: {
            $0.timelineStartFrame == currentReel.timelineEndFrame
        }) {
            // Seamless transition to next reel
            if preloadingReelId == nextReel.id, preloadPlayer != nil {
                switchToPreloadedPlayer(nextReel)
            } else {
                // Need to load the next reel
                Task {
                    do {
                        try await loadReel(nextReel)
                    } catch {
                        debugPrint("PlaybackEngine.handleReelEnd: Failed to load next reel '\(nextReel.sourceURL.lastPathComponent)': \(error)")
                    }
                    if isPlaying {
                        currentPlayer?.play()
                    }
                }
            }
        } else {
            // Entering a gap
            isInGap = true
            activeReel = nil
            currentPlayer?.pause()

            if isPlaying {
                startGapPlayback()
            }
        }
    }

    /// Update current timecode from frame
    private func updateCurrentTimecode() {
        currentTimecode = timeline.config.timecode(at: currentFrame)
    }

    private func performPendingSeekIfNeeded() {
        guard !isSeeking, let targetFrame = pendingSeekFrame else { return }
        pendingSeekFrame = nil

        let wasPlaying = isPlaying
        if wasPlaying {
            currentPlayer?.pause()
            stopGapPlayback()
            stopAllAudioClips()
        }

        isSeeking = true

        performSeek(to: targetFrame) { [weak self] in
            guard let self else { return }
            self.isSeeking = false

            if self.pendingSeekFrame != nil {
                self.performPendingSeekIfNeeded()
                return
            }

            if wasPlaying, self.isPlaying {
                if self.isInGap {
                    self.startGapPlayback()
                } else {
                    self.currentPlayer?.play()
                }
            }

            self.syncAudioClips()
        }
    }

    private func performSeek(to frame: Int, completion: @escaping () -> Void) {
        if let reel = timeline.videoReel(at: frame) {
            isInGap = false
            activeReel = reel

            if reel.id != currentReelId {
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await self.loadReel(reel)
                    } catch {
                        debugPrint("PlaybackEngine.seek: Failed to load reel '\(reel.sourceURL.lastPathComponent)': \(error)")
                    }
                    self.seekWithinReel(reel, timelineFrame: frame, resumeAfterSeek: false, completion: completion)
                }
            } else {
                seekWithinReel(reel, timelineFrame: frame, resumeAfterSeek: false, completion: completion)
            }
        } else {
            isInGap = true
            activeReel = nil
            currentPlayer?.pause()
            completion()
        }
    }

    /// Update timeline properties when timeline changes
    private func updateTimelineProperties() {
        durationFrames = timeline.config.durationFrames
        hasContent = !timeline.videoReels.isEmpty || timeline.audioLanes.contains { !$0.clips.isEmpty }
        currentTimecode = timeline.config.timecode(at: currentFrame)
        isInGap = timeline.videoReel(at: currentFrame) == nil
        if isInGap && timeline.videoReels.isEmpty {
            activeReel = nil
        }

        // Clean up asset cache for removed reels
        let currentReelIds = Set(timeline.videoReels.map(\.id))
        for reelId in Array(assetCache.keys) where !currentReelIds.contains(reelId) {
            assetCache.removeValue(forKey: reelId)
        }
    }

    // MARK: - Cleanup

    /// Cleans up all resources before deallocation.
    ///
    /// Stops all playback, releases audio engine resources, clears caches,
    /// removes CoreAudio property listeners, and deletes temporary audio extraction files.
    ///
    /// - Important: Call this method before the engine is deallocated to ensure
    ///   proper resource cleanup. The `deinit` cannot access `@MainActor` properties.
    func cleanup() {
        // Stop gap timer
        gapTimer?.invalidate()
        gapTimer = nil

        // Remove time observer from player
        if let observer = timeObserver, let player = currentPlayer {
            player.removeTimeObserver(observer)
        }
        timeObserver = nil

        // Remove meter tap
        removeMeterTap()
        isMeteringEnabled = false

        // Remove sample rate change listener before releasing audio engine
        removeSampleRateListener()

        // Stop and clean up audio engine
        audioEngine.stop()

        // Clear caches. Nothing is extracted to disk any more, so there are no
        // temporary files to delete alongside them.
        assetCache.removeAll()
        audioPlayers.removeAll()
        failedClipCooldowns.removeAll()
    }

    deinit {
        // Note: MainActor-isolated properties cannot be accessed in deinit.
        // The cleanup() method should be called before deallocation.
        // The audio engine and timer will be cleaned up automatically when released.
    }
}

// MARK: - Errors

/// Errors that can occur during playback operations.
enum PlaybackEngineError: LocalizedError {
    /// The video asset cannot be played (corrupt or unsupported format).
    case notPlayable

    /// The requested video reel was not found in the timeline.
    case reelNotFound

    /// Seek operation failed to complete.
    case seekFailed

    /// No audio track exists at the specified index.
    case noAudioTrack

    /// Failed to extract audio from a video file to a temporary file.
    case audioExtractionFailed

    /// Failed to instantiate an Audio Unit (e.g., MatrixMixer).
    case audioUnitInstantiationFailed

    var errorDescription: String? {
        switch self {
        case .notPlayable:
            return "The video file cannot be played."
        case .reelNotFound:
            return "The video reel could not be found."
        case .seekFailed:
            return "Failed to seek to the specified position."
        case .noAudioTrack:
            return "No audio track was found."
        case .audioExtractionFailed:
            return "Failed to extract audio from the source."
        case .audioUnitInstantiationFailed:
            return "Failed to create audio routing unit."
        }
    }
}
