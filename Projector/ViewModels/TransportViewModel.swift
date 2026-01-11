//
//  TransportViewModel.swift
//  Projector
//
//  THE CONTRACT CONSUMER: TransportServiceProtocol
//  Defined by: arch-architect
//  Consumed by: ui-specialist
//

import Foundation
import SwiftUI
import Combine
import SwiftTimecodeCore

// MARK: - TransportViewModel

/// ViewModel for transport controls that observes TransportServiceProtocol.
///
/// This ViewModel subscribes to the transport service's `AsyncStream` and exposes
/// `@Published` properties for SwiftUI views to observe. All UI updates happen
/// on the main thread via `@MainActor`.
///
/// ## Architecture
///
/// ```
/// ┌─────────────────────────────────────────────────────────────────┐
/// │                    SwiftUI Views                                 │
/// │  (TransportBarView, VitalControlsBar, etc.)                     │
/// │                         │                                        │
/// │                         │ @Published bindings                    │
/// │                         ▼                                        │
/// │  TransportViewModel (@MainActor) ◀── YOU ARE HERE               │
/// │                         │                                        │
/// │                         │ AsyncStream observation                │
/// │                         ▼                                        │
/// │              TransportServiceProtocol                            │
/// └─────────────────────────────────────────────────────────────────┘
/// ```
///
/// ## Usage
///
/// ```swift
/// struct TransportBarView: View {
///     @ObservedObject var viewModel: TransportViewModel
///
///     var body: some View {
///         HStack {
///             Button(action: { viewModel.togglePlayback() }) {
///                 Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
///             }
///             Text(viewModel.timecodeString)
///         }
///     }
/// }
/// ```
@MainActor
public final class TransportViewModel: ObservableObject {

    // MARK: - Published Transport State

    /// Whether playback is currently active.
    @Published private(set) var isPlaying: Bool = false

    /// Current position on the timeline as timecode.
    @Published private(set) var currentTimecode: Timecode = .init(
        .components(h: 0, m: 0, s: 0, f: 0),
        at: .fps24,
        by: .clamping
    )

    /// Current position on the timeline in frames.
    @Published private(set) var currentFrame: Int = 0

    /// Total duration of the timeline in frames.
    @Published private(set) var durationFrames: Int = 0

    /// Timeline frame rate.
    @Published private(set) var frameRate: TimecodeFrameRate = .fps24

    /// Whether the playhead is in a gap (no video reel at current position).
    @Published private(set) var isInGap: Bool = false

    /// Whether any content is loaded.
    @Published private(set) var hasContent: Bool = false

    /// ID of the currently active video reel, if any.
    @Published private(set) var activeReelId: UUID?

    /// Display name of the currently active video reel, if any.
    @Published private(set) var activeReelName: String?

    /// Current loading state of the transport.
    @Published private(set) var loadingState: TransportLoadingState = .idle

    // MARK: - Computed Properties

    /// The current timecode as a formatted string.
    var timecodeString: String {
        currentTimecode.stringValue()
    }

    /// Progress through the timeline (0.0 to 1.0).
    var progress: Double {
        guard durationFrames > 0 else { return 0 }
        return Double(currentFrame) / Double(durationFrames)
    }

    /// Whether playback controls should be enabled.
    var canPlay: Bool {
        hasContent
    }

    /// Whether the transport is currently busy (seeking, loading).
    var isBusy: Bool {
        loadingState.isBusy
    }

    /// Human-readable status text.
    var statusText: String {
        if !hasContent {
            return "No Content"
        }
        if loadingState.isBusy {
            return loadingState.displayName
        }
        if isInGap {
            return "Gap"
        }
        if let reelName = activeReelName {
            return reelName
        }
        return isPlaying ? "Playing" : "Stopped"
    }

    // MARK: - Private Properties

    /// The transport service being observed.
    private let service: TransportServiceProtocol

    /// Task for observing transport state stream.
    private var transportStateTask: Task<Void, Never>?

    // MARK: - Initialization

    /// Creates a new transport view model.
    ///
    /// - Parameter service: The transport service to observe.
    public init(service: TransportServiceProtocol) {
        self.service = service
        subscribeToTransportState()
    }

    deinit {
        transportStateTask?.cancel()
    }

    // MARK: - Stream Subscription

    /// Subscribes to the transport state stream.
    private func subscribeToTransportState() {
        transportStateTask = Task { [weak self] in
            guard let self else { return }

            for await state in service.transportStateStream {
                // Task.isCancelled check for clean shutdown
                guard !Task.isCancelled else { break }

                await MainActor.run { [weak self] in
                    self?.updateState(from: state)
                }
            }
        }
    }

    /// Updates published properties from a transport state snapshot.
    private func updateState(from state: TransportState) {
        isPlaying = state.isPlaying
        currentTimecode = state.currentTimecode
        currentFrame = state.currentFrame
        durationFrames = state.durationFrames
        frameRate = state.frameRate
        isInGap = state.isInGap
        hasContent = state.hasContent
        activeReelId = state.activeReelId
        activeReelName = state.activeReelName
        loadingState = state.loadingState
    }

    // MARK: - Transport Commands

    /// Start playback from the current position.
    func play() {
        Task { await service.play() }
    }

    /// Pause playback at the current position.
    func pause() {
        Task { await service.pause() }
    }

    /// Toggle between play and pause states.
    func togglePlayback() {
        Task { await service.togglePlayback() }
    }

    /// Stop playback and return to the start of the timeline.
    func stop() {
        Task { await service.stop() }
    }

    /// Seek to a specific frame on the timeline.
    ///
    /// - Parameter frame: Target frame number.
    func seekToFrame(_ frame: Int) {
        Task { await service.seekToFrame(frame) }
    }

    /// Seek to a specific timecode.
    ///
    /// - Parameter timecode: Target timecode.
    func seekToTimecode(_ timecode: Timecode) {
        Task { await service.seekToTimecode(timecode) }
    }

    /// Step forward by one frame.
    func stepForward() {
        Task { await service.stepForward() }
    }

    /// Step backward by one frame.
    func stepBackward() {
        Task { await service.stepBackward() }
    }

    // MARK: - MIDI Commands

    /// Select a MIDI input source by name.
    ///
    /// - Parameter name: Display name of the MIDI input, or `nil` to disconnect.
    func selectMIDIInput(_ name: String?) {
        Task { await service.selectMIDIInput(name) }
    }

    /// Refresh the list of available MIDI inputs.
    func refreshMIDIInputs() {
        Task { await service.refreshMIDIInputs() }
    }

    /// Set the local frame rate for MTC interpretation.
    ///
    /// - Parameter frameRate: The frame rate to use for MTC decoding.
    func setMTCFrameRate(_ frameRate: TimecodeFrameRate) {
        Task { await service.setMTCFrameRate(frameRate) }
    }

    // MARK: - Audio Configuration

    /// Set the audio output device.
    ///
    /// - Parameter deviceUID: CoreAudio device UID, or `nil` for system default.
    func setAudioOutputDevice(_ deviceUID: String?) {
        Task { await service.setAudioOutputDevice(deviceUID) }
    }
}
