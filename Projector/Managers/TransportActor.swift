//
//  TransportActor.swift
//  Projector
//
//  THE CONTRACT IMPLEMENTATION: TransportServiceProtocol
//  Defined by: arch-architect
//  Implemented by: backend-logic
//  Consumed by: ui-specialist (TransportViewModel)
//

import Foundation
import Combine
import SwiftTimecodeCore

// MARK: - TransportActor

/// A Swift Actor that bridges the PlaybackEngine to the TransportServiceProtocol.
///
/// This actor observes the `@MainActor` PlaybackEngine's published properties and
/// emits state updates via `AsyncStream`, enabling thread-safe consumption by
/// ViewModels without blocking the main thread.
///
/// ## Architecture
///
/// ```
/// ┌─────────────────────────────────────────────────────────────────┐
/// │                    SwiftUI Views                                 │
/// └─────────────────────────────────────────────────────────────────┘
///                               │
///                               ▼
/// ┌─────────────────────────────────────────────────────────────────┐
/// │                 TransportViewModel (@MainActor)                  │
/// │  (consumes transportStateStream)                                 │
/// └─────────────────────────────────────────────────────────────────┘
///                               │
///                               ▼
/// ┌─────────────────────────────────────────────────────────────────┐
/// │              TransportActor (this file)                          │
/// │  - Observes PlaybackEngine via Combine                          │
/// │  - Emits TransportState via AsyncStream                         │
/// │  - Forwards commands to PlaybackEngine                           │
/// └─────────────────────────────────────────────────────────────────┘
///                               │
///                               ▼
/// ┌─────────────────────────────────────────────────────────────────┐
/// │              PlaybackEngine (@MainActor)                         │
/// │  - AVFoundation playback                                         │
/// │  - Audio routing                                                 │
/// └─────────────────────────────────────────────────────────────────┘
/// ```
///
/// ## Thread Safety
///
/// - All mutable state is protected by actor isolation
/// - PlaybackEngine access uses `MainActor.run` for safety
/// - State updates are emitted via `AsyncStream` which is safe for cross-actor consumption
public actor TransportActor: TransportServiceProtocol {

    // MARK: - Dependencies

    /// The playback engine being bridged.
    private let playbackEngine: PlaybackEngine

    /// The MIDI sync service for forwarding MIDI state.
    private let midiSyncService: MIDISyncServiceProtocol

    // MARK: - Actor State

    /// Current loading state.
    private var loadingState: TransportLoadingState = .idle

    // MARK: - Combine Subscriptions

    /// Subscriptions to PlaybackEngine's published properties.
    private var cancellables: Set<AnyCancellable> = []

    // MARK: - AsyncStream Infrastructure

    /// Continuation for emitting transport state updates.
    private var transportContinuation: AsyncStream<TransportState>.Continuation?

    /// The stream of transport state updates.
    public nonisolated var transportStateStream: AsyncStream<TransportState> {
        AsyncStream { continuation in
            Task {
                await self.registerTransportContinuation(continuation)
            }
        }
    }

    /// The stream of MIDI sync state updates (forwarded from MIDISyncService).
    public nonisolated var midiSyncStateStream: AsyncStream<MIDISyncState> {
        midiSyncService.syncStateStream
    }

    // MARK: - Initialization

    /// Creates a new transport actor.
    ///
    /// - Parameters:
    ///   - playbackEngine: The playback engine to bridge.
    ///   - midiSyncService: The MIDI sync service for MTC/MMC state.
    public init(playbackEngine: PlaybackEngine, midiSyncService: MIDISyncServiceProtocol) {
        self.playbackEngine = playbackEngine
        self.midiSyncService = midiSyncService
    }

    /// Starts observing the playback engine's state.
    ///
    /// Call this after initialization to begin receiving state updates.
    public func start() async {
        await setupPlaybackEngineObservation()
    }

    // MARK: - Transport Commands

    /// Start playback from the current position.
    public func play() async {
        await MainActor.run {
            playbackEngine.play()
        }
    }

    /// Pause playback at the current position.
    public func pause() async {
        await MainActor.run {
            playbackEngine.pause()
        }
    }

    /// Toggle between play and pause states.
    public func togglePlayback() async {
        await MainActor.run {
            playbackEngine.togglePlayback()
        }
    }

    /// Stop playback and return to the start of the timeline.
    public func stop() async {
        await MainActor.run {
            playbackEngine.stop()
        }
    }

    /// Seek to a specific frame on the timeline.
    ///
    /// - Parameter frame: Target frame number (clamped to valid range).
    public func seekToFrame(_ frame: Int) async {
        loadingState = .seeking
        emitState()

        await MainActor.run {
            playbackEngine.seekToFrame(frame)
        }

        // The loading state will be reset when we observe the frame change
        loadingState = .idle
        emitState()
    }

    /// Seek to a specific timecode.
    ///
    /// - Parameter timecode: Target timecode.
    public func seekToTimecode(_ timecode: Timecode) async {
        loadingState = .seeking
        emitState()

        await MainActor.run {
            playbackEngine.seekToTimecode(timecode)
        }

        loadingState = .idle
        emitState()
    }

    /// Step forward by one frame.
    public func stepForward() async {
        await MainActor.run {
            playbackEngine.stepForward()
        }
    }

    /// Step backward by one frame.
    public func stepBackward() async {
        await MainActor.run {
            playbackEngine.stepBackward()
        }
    }

    // MARK: - MIDI Commands (Forwarded to MIDISyncService)

    /// Select a MIDI input source by name.
    ///
    /// - Parameter name: Display name of the MIDI input, or `nil` to disconnect.
    public func selectMIDIInput(_ name: String?) async {
        await midiSyncService.selectInput(name)
    }

    /// Refresh the list of available MIDI inputs.
    public func refreshMIDIInputs() async {
        await midiSyncService.refreshAvailableInputs()
    }

    /// Set the local frame rate for MTC interpretation.
    ///
    /// - Parameter frameRate: The frame rate to use for MTC decoding.
    public func setMTCFrameRate(_ frameRate: TimecodeFrameRate) async {
        await midiSyncService.setLocalFrameRate(frameRate)
    }

    // MARK: - Audio Configuration

    /// Set the audio output device.
    ///
    /// - Parameter deviceUID: CoreAudio device UID, or `nil` for system default.
    public func setAudioOutputDevice(_ deviceUID: String?) async {
        await MainActor.run {
            playbackEngine.setAudioOutputDevice(deviceUID)
        }
    }

    // MARK: - PlaybackEngine Observation

    /// Sets up Combine observation of PlaybackEngine's published properties.
    private func setupPlaybackEngineObservation() async {
        await MainActor.run { [weak self] in
            guard let self else { return }

            // Combine all relevant publishers into a single stream
            let engine = self.playbackEngine

            Publishers.CombineLatest4(
                engine.$isPlaying,
                engine.$currentFrame,
                engine.$currentTimecode,
                engine.$durationFrames
            )
            .combineLatest(
                Publishers.CombineLatest4(
                    engine.$isInGap,
                    engine.$hasContent,
                    engine.$activeReel.map { $0?.id },
                    engine.$activeReel.map { $0?.displayName }
                )
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] combined in
                let ((isPlaying, currentFrame, currentTimecode, durationFrames),
                     (isInGap, hasContent, activeReelId, activeReelName)) = combined

                Task { [weak self] in
                    await self?.handlePlaybackStateUpdate(
                        isPlaying: isPlaying,
                        currentFrame: currentFrame,
                        currentTimecode: currentTimecode,
                        durationFrames: durationFrames,
                        isInGap: isInGap,
                        hasContent: hasContent,
                        activeReelId: activeReelId,
                        activeReelName: activeReelName
                    )
                }
            }
            .store(in: &self.cancellables)
        }
    }

    /// Handles state updates from the playback engine.
    private func handlePlaybackStateUpdate(
        isPlaying: Bool,
        currentFrame: Int,
        currentTimecode: Timecode,
        durationFrames: Int,
        isInGap: Bool,
        hasContent: Bool,
        activeReelId: UUID?,
        activeReelName: String?
    ) {
        // Get frame rate from engine
        let frameRate = playbackEngine.frameRate

        emitStateWith(
            isPlaying: isPlaying,
            currentTimecode: currentTimecode,
            currentFrame: currentFrame,
            durationFrames: durationFrames,
            frameRate: frameRate,
            isInGap: isInGap,
            hasContent: hasContent,
            activeReelId: activeReelId,
            activeReelName: activeReelName
        )
    }

    // MARK: - State Emission

    /// Registers a continuation for the transport state stream.
    private func registerTransportContinuation(_ continuation: AsyncStream<TransportState>.Continuation) {
        transportContinuation?.finish()
        transportContinuation = continuation

        // Emit initial state
        emitState()

        continuation.onTermination = { [weak self] _ in
            Task { [weak self] in
                await self?.handleTransportContinuationTermination()
            }
        }
    }

    /// Handles continuation termination.
    private func handleTransportContinuationTermination() {
        transportContinuation = nil
    }

    /// Emits the current state to all subscribers.
    private func emitState() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let engine = self.playbackEngine

            await self.emitStateWith(
                isPlaying: engine.isPlaying,
                currentTimecode: engine.currentTimecode,
                currentFrame: engine.currentFrame,
                durationFrames: engine.durationFrames,
                frameRate: engine.frameRate,
                isInGap: engine.isInGap,
                hasContent: engine.hasContent,
                activeReelId: engine.activeReel?.id,
                activeReelName: engine.activeReel?.displayName
            )
        }
    }

    /// Emits state with the given values.
    private func emitStateWith(
        isPlaying: Bool,
        currentTimecode: Timecode,
        currentFrame: Int,
        durationFrames: Int,
        frameRate: TimecodeFrameRate,
        isInGap: Bool,
        hasContent: Bool,
        activeReelId: UUID?,
        activeReelName: String?
    ) {
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

    // MARK: - Cleanup

    /// Stops observation and cleans up resources.
    public func stop() async {
        await MainActor.run { [weak self] in
            self?.cancellables.removeAll()
        }
        transportContinuation?.finish()
        transportContinuation = nil
    }
}
