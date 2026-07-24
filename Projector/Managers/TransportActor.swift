//
//  TransportActor.swift
//  Projector
//
//  THE CONTRACT IMPLEMENTATION: TransportServiceProtocol
//  Layer: Contracts
//  Implemented in: Managers
//  Consumed in: Views
//

import Foundation
import SwiftTimecodeCore

// MARK: - TransportActor

/// Actor managing transport state and operations.
///
/// Thread-safe transport state management isolated from UI.
/// Implements TransportServiceProtocol for two-layer architecture compliance.
///
/// ## Architecture
///
/// ```
/// Presentation Layer (TransportViewModel)
///     ↓ consumes
/// THE CONTRACT (TransportServiceProtocol)
///     ↓ implemented by
/// Logic Layer (TransportActor) ← you are here
///     ↓ delegates to
/// PlaybackEngine (@MainActor - AVFoundation operations)
/// ```
///
/// ## Implementation Strategy
///
/// This actor OWNS transport state (isPlaying, currentFrame, etc.) and delegates
/// to PlaybackEngine only for AVFoundation operations (play/pause/seek).
/// PlaybackEngine provides callbacks for frame position updates.
///
/// ## Thread Safety
///
/// All methods are actor-isolated and thread-safe. PlaybackEngine operations
/// run on MainActor, but TransportActor owns the source of truth for state.
///
/// ## Usage Example
///
/// ```swift
/// let actor = TransportActor(
///     playbackEngine: engine,
///     timelineActor: timelineActor,
///     midiSyncService: midiSyncService
/// )
///
/// // Subscribe to state updates
/// Task {
///     for await state in actor.transportStateStream {
///         // Update UI
///     }
/// }
///
/// // Control transport
/// await actor.play()
/// await actor.seekToFrame(1000)
/// ```
actor TransportActor: TransportServiceProtocol {

    // MARK: - Actor-Isolated State

    /// Whether playback is currently active.
    private var isPlaying: Bool = false

    /// Current position on the timeline (in frames).
    private var currentFrame: Int = 0

    /// Current timecode based on timeline position.
    private var currentTimecode: Timecode

    /// Total duration of the timeline in frames.
    private var durationFrames: Int = 0

    /// Timeline frame rate.
    private var frameRate: TimecodeFrameRate

    /// Whether the playhead is in a gap (no video reel at current position).
    private var isInGap: Bool = false

    /// Whether any content is loaded.
    private var hasContent: Bool = false

    /// ID of the currently active video reel, if any.
    private var activeReelId: UUID?

    /// Display name of the currently active video reel, if any.
    private var activeReelName: String?

    /// Current loading state of the transport.
    private var loadingState: TransportLoadingState = .idle

    // MARK: - Dependencies

    /// The playback engine for AVFoundation operations.
    private let playbackEngine: PlaybackEngine

    /// The timeline actor for timeline state.
    private let timelineActor: TimelineActor

    /// The MIDI sync service for MTC/MMC state.
    private let midiSyncService: MIDISyncServiceProtocol

    // MARK: - AsyncStream Infrastructure

    /// Continuation for emitting transport state updates.
    private var transportContinuation: AsyncStream<TransportState>.Continuation?

    /// Observation task for timeline changes.
    private var timelineObservationTask: Task<Void, Never>?

    /// Observation task for MIDI sync commands.
    private var midiCommandObservationTask: Task<Void, Never>?

    // MARK: - Initialization

    /// Creates a new transport actor.
    ///
    /// - Parameters:
    ///   - playbackEngine: The playback engine for AVFoundation operations.
    ///   - timelineActor: The timeline actor for timeline state.
    ///   - midiSyncService: The MIDI sync service for MTC/MMC state.
    init(
        playbackEngine: PlaybackEngine,
        timelineActor: TimelineActor,
        midiSyncService: MIDISyncServiceProtocol
    ) {
        self.playbackEngine = playbackEngine
        self.timelineActor = timelineActor
        self.midiSyncService = midiSyncService

        // Initialize timecode and frame rate from timeline
        // We'll get the actual values from timeline stream
        self.frameRate = .fps24
        self.currentTimecode = Timecode(.components(h: 0, m: 0, s: 0, f: 0), at: frameRate, by: .clamping)
    }

    deinit {
        timelineObservationTask?.cancel()
        midiCommandObservationTask?.cancel()
        transportContinuation?.finish()
    }

    // MARK: - Setup

    /// Starts observing playback engine and sets up callbacks.
    ///
    /// Call this after initialization to begin receiving state updates.
    func start() async {
        // Set up PlaybackEngine callback for frame updates
        await MainActor.run {
            playbackEngine.onFrameUpdate = { [weak self] frame in
                await self?.updateCurrentFrame(frame)
            }
        }
    }

    // MARK: - TransportServiceProtocol: State Stream

    nonisolated var transportStateStream: AsyncStream<TransportState> {
        AsyncStream { continuation in
            Task {
                await self.registerTransportContinuation(continuation)
            }
        }
    }

    nonisolated var midiSyncStateStream: AsyncStream<MIDISyncState> {
        midiSyncService.syncStateStream
    }

    /// Registers a continuation for the transport state stream.
    private func registerTransportContinuation(_ continuation: AsyncStream<TransportState>.Continuation) {
        transportContinuation?.finish()
        transportContinuation = continuation

        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.handleTransportContinuationTermination()
            }
        }

        // Emit initial state
        emitState()

        // Start observing timeline and MIDI
        startObservingTimeline()
        startObservingMIDICommands()
    }

    /// Handles continuation termination.
    private func handleTransportContinuationTermination() {
        transportContinuation = nil
        timelineObservationTask?.cancel()
        midiCommandObservationTask?.cancel()
    }

    /// Starts observing timeline changes.
    private func startObservingTimeline() {
        timelineObservationTask?.cancel()

        timelineObservationTask = Task { [weak self] in
            guard let self = self else { return }

            for await state in timelineActor.timelineStateStream {
                await self.handleTimelineUpdate(state)
            }
        }
    }

    /// Handles timeline state updates.
    private func handleTimelineUpdate(_ state: TimelineState) {
        // Update timeline-derived state
        durationFrames = state.durationFrames
        frameRate = state.frameRate
        hasContent = !state.videoReels.isEmpty || !state.audioLanes.isEmpty

        // Update currentTimecode with new frame rate
        currentTimecode = Timecode(.frames(currentFrame), at: frameRate, by: .clamping)

        // Determine if we're in a gap
        updateGapState(videoReels: state.videoReels)

        emitState()
    }

    /// Updates gap state and active reel based on current frame.
    private func updateGapState(videoReels: [VideoReel]) {
        // Find reel at current position
        let reelAtPosition = videoReels.first { reel in
            let start = reel.timelineStartFrame
            let end = start + reel.durationFrames
            return currentFrame >= start && currentFrame < end
        }

        if let reel = reelAtPosition {
            isInGap = false
            activeReelId = reel.id
            activeReelName = reel.displayName
        } else {
            isInGap = !videoReels.isEmpty  // Only in gap if timeline has content
            activeReelId = nil
            activeReelName = nil
        }
    }

    /// Starts observing MIDI sync commands.
    private func startObservingMIDICommands() {
        midiCommandObservationTask?.cancel()

        midiCommandObservationTask = Task { [weak self] in
            guard let self = self else { return }

            for await syncState in midiSyncService.syncStateStream {
                await self.handleMIDISyncUpdate(syncState)
            }
        }
    }

    /// Handles MIDI sync state updates.
    private func handleMIDISyncUpdate(_ syncState: MIDISyncState) async {
        // Handle MTC timecode updates
        if let mtcTimecode = syncState.mtcTimecode {
            // Convert absolute incoming timecode into timeline-relative frames.
            let timelineState = await timelineActor.getCurrentState()
            let timelineStartFrame = timelineState.config.startTimecode.frameCount.wholeFrames
            let mtcFrame = mtcTimecode.frameCount.wholeFrames - timelineStartFrame

            // Only update if significantly different (avoid jitter)
            if abs(mtcFrame - currentFrame) > 1 {
                currentFrame = mtcFrame
                currentTimecode = mtcTimecode
                emitState()
            }
        }

        // Handle MMC commands (play/stop/locate)
        // These are handled via the command methods below
    }

    // MARK: - TransportServiceProtocol: Transport Commands

    /// Starts playback from the current position.
    func play() async {
        isPlaying = true
        loadingState = .loadingReel
        emitState()

        // Delegate to PlaybackEngine for AVFoundation operations
        await MainActor.run {
            playbackEngine.play()
        }

        loadingState = .idle
        emitState()
    }

    /// Pauses playback at the current position.
    func pause() async {
        isPlaying = false
        emitState()

        await MainActor.run {
            playbackEngine.pause()
        }
    }

    /// Toggles between play and pause states.
    func togglePlayback() async {
        if isPlaying {
            await pause()
        } else {
            await play()
        }
    }

    /// Stops playback and returns to the start of the timeline.
    func stop() async {
        isPlaying = false
        currentFrame = 0
        currentTimecode = Timecode(.frames(0), at: frameRate, by: .clamping)
        emitState()

        await MainActor.run {
            playbackEngine.stop()
        }
    }

    /// Seeks to a specific frame on the timeline.
    ///
    /// - Parameter frame: Target frame number (clamped to valid range).
    func seekToFrame(_ frame: Int) async {
        let clampedFrame = max(0, min(frame, durationFrames))

        loadingState = .seeking
        currentFrame = clampedFrame
        currentTimecode = Timecode(.frames(clampedFrame), at: frameRate, by: .clamping)
        emitState()

        await MainActor.run {
            playbackEngine.seekToFrame(clampedFrame)
        }

        loadingState = .idle
        emitState()
    }

    /// Seeks to a specific timecode.
    ///
    /// - Parameter timecode: Target timecode.
    func seekToTimecode(_ timecode: Timecode) async {
        let targetFrame = timecode.frameCount.wholeFrames
        await seekToFrame(targetFrame)
    }

    /// Steps forward by one frame.
    func stepForward() async {
        await seekToFrame(currentFrame + 1)
    }

    /// Steps backward by one frame.
    func stepBackward() async {
        await seekToFrame(currentFrame - 1)
    }

    // MARK: - TransportServiceProtocol: MIDI Commands

    /// Selects a MIDI input source by name.
    ///
    /// - Parameter name: Display name of the MIDI input, or `nil` to disconnect.
    func selectMIDIInput(_ name: String?) async {
        await midiSyncService.selectInput(name)
    }

    /// Refreshes the list of available MIDI inputs.
    func refreshMIDIInputs() async {
        await midiSyncService.refreshAvailableInputs()
    }

    /// Sets the local frame rate for MTC interpretation.
    ///
    /// - Parameter frameRate: The frame rate to use for MTC decoding.
    func setMTCFrameRate(_ frameRate: TimecodeFrameRate) async {
        await midiSyncService.setLocalFrameRate(frameRate)
    }

    // MARK: - TransportServiceProtocol: Audio Configuration

    /// Sets the audio output device.
    ///
    /// - Parameter deviceUID: CoreAudio device UID, or `nil` for system default.
    func setAudioOutputDevice(_ deviceUID: String?) async {
        await MainActor.run {
            playbackEngine.setAudioOutputDevice(deviceUID)
        }
    }

    // MARK: - State Emission

    /// Emits the current state to all subscribers.
    private func emitState() {
        let state = TransportState(
            isPlaying: isPlaying,
            currentTimecode: currentTimecode,
            currentFrame: currentFrame,
            durationFrames: durationFrames,
            frameRate: frameRate,
            isInGap: isInGap,
            hasContent: hasContent,
            activeReelId: activeReelId,
            activeReelName: activeReelName,
            loadingState: loadingState
        )
        transportContinuation?.yield(state)
    }

    // MARK: - Public Frame Update (called by PlaybackEngine)

    /// Updates the current frame position.
    ///
    /// Called by PlaybackEngine when frame position changes during playback.
    ///
    /// - Parameter frame: New frame position.
    /// - Note: Thread-safe, can be called from any actor
    func updateCurrentFrame(_ frame: Int) async {
        currentFrame = frame
        currentTimecode = Timecode(.frames(frame), at: frameRate, by: .clamping)

        // Update gap state based on new position
        let timelineState = await timelineActor.getCurrentState()
        updateGapState(videoReels: timelineState.videoReels)

        // Drift comparison uses absolute timecode frames. PlaybackEngine reports
        // timeline-relative frames, so add the timeline start offset first.
        let timelineStartFrame = timelineState.config.startTimecode.frameCount.wholeFrames
        await midiSyncService.updateLocalPlaybackFrame(timelineStartFrame + frame)

        emitState()
    }
}
