//
//  TransportServiceProtocol.swift
//  Projector
//
//  THE CONTRACT: Transport Service
//  Layer: Contracts
//  Implemented in: Managers
//  Consumed in: Views
//

import Foundation
import SwiftTimecodeCore

// MARK: - Transport State Types

/// Represents the current transport state for UI display.
///
/// This is a UI-friendly representation of the transport state, designed
/// to be consumed by SwiftUI views via the `TransportViewModel`.
///
/// ## Thread Safety
/// This type is `Sendable` and can safely cross actor boundaries.
///
/// ## Example
/// ```swift
/// let state = TransportState(
///     isPlaying: true,
///     currentTimecode: timecode,
///     frameRate: .fps24,
///     durationFrames: 3600
/// )
/// ```
public struct TransportState: Sendable, Equatable {
    /// Whether playback is currently active.
    public let isPlaying: Bool

    /// Current position on the timeline as timecode.
    public let currentTimecode: Timecode

    /// Current position on the timeline in frames.
    public let currentFrame: Int

    /// Total duration of the timeline in frames.
    public let durationFrames: Int

    /// Timeline frame rate.
    public let frameRate: TimecodeFrameRate

    /// Whether the playhead is in a gap (no video reel at current position).
    public let isInGap: Bool

    /// Whether any content is loaded.
    public let hasContent: Bool

    /// ID of the currently active video reel, if any.
    public let activeReelId: UUID?

    /// Display name of the currently active video reel, if any.
    public let activeReelName: String?

    /// Current loading state of the transport.
    public let loadingState: TransportLoadingState

    /// Creates a new transport state snapshot.
    ///
    /// - Parameters:
    ///   - isPlaying: Whether playback is active
    ///   - currentTimecode: Current position as timecode
    ///   - currentFrame: Current position in frames
    ///   - durationFrames: Total timeline duration in frames
    ///   - frameRate: Timeline frame rate
    ///   - isInGap: Whether playhead is in a video gap
    ///   - hasContent: Whether timeline has content
    ///   - activeReelId: ID of the active video reel
    ///   - activeReelName: Display name of the active video reel
    ///   - loadingState: Current loading state
    public init(
        isPlaying: Bool,
        currentTimecode: Timecode,
        currentFrame: Int,
        durationFrames: Int,
        frameRate: TimecodeFrameRate,
        isInGap: Bool,
        hasContent: Bool,
        activeReelId: UUID? = nil,
        activeReelName: String? = nil,
        loadingState: TransportLoadingState = .idle
    ) {
        self.isPlaying = isPlaying
        self.currentTimecode = currentTimecode
        self.currentFrame = currentFrame
        self.durationFrames = durationFrames
        self.frameRate = frameRate
        self.isInGap = isInGap
        self.hasContent = hasContent
        self.activeReelId = activeReelId
        self.activeReelName = activeReelName
        self.loadingState = loadingState
    }

    /// An empty state representing no content loaded.
    public static let empty = TransportState(
        isPlaying: false,
        currentTimecode: Timecode(.components(h: 0, m: 0, s: 0, f: 0), at: .fps24, by: .clamping),
        currentFrame: 0,
        durationFrames: 0,
        frameRate: .fps24,
        isInGap: false,
        hasContent: false,
        activeReelId: nil,
        activeReelName: nil,
        loadingState: .idle
    )
}

/// Represents the loading state of the transport.
public enum TransportLoadingState: Sendable, Equatable, Hashable {
    /// Transport is idle, not loading anything.
    case idle

    /// Transport is seeking to a new position.
    case seeking

    /// Transport is loading a video reel.
    case loadingReel

    /// Human-readable description for UI display.
    public var displayName: String {
        switch self {
        case .idle: return ""
        case .seeking: return "Seeking..."
        case .loadingReel: return "Loading..."
        }
    }

    /// Whether the transport is currently busy.
    public var isBusy: Bool {
        self != .idle
    }
}

// MARK: - MIDI Sync State Types
// NOTE: MTCSyncState, MMCCommand, and MIDISyncState are defined in MIDISyncServiceProtocol.swift
// This file uses those types to avoid duplication.

// MARK: - Transport Service Protocol

/// The primary contract for transport control and state observation.
///
/// This protocol defines the interface between the Logic layer (actors) and
/// the Presentation layer (ViewModels). It provides:
///
/// 1. **State Streams**: `AsyncStream` for high-frequency transport state updates
/// 2. **MIDI Sync Streams**: `AsyncStream` for MTC/MMC state changes
/// 3. **Commands**: Async methods for controlling playback
///
/// ## Architecture
///
/// ```
/// ┌─────────────────────────────────────────────────────────────────────────┐
/// │                     PRESENTATION LAYER                                   │
/// │                                                                          │
/// │  TransportBarView ←─── TransportViewModel (@MainActor)                  │
/// │                              │                                           │
/// │                              │ Observes AsyncStreams                     │
/// │                              │ Calls async commands                      │
/// │                              ▼                                           │
/// ├─────────────────── TransportServiceProtocol ────────────────────────────┤
/// │                              ▲                                           │
/// │                              │ Implemented by                            │
/// │                              │                                           │
/// │  TransportActor ◀────── MIDITransportActor ◀────── CoreMIDI Callbacks   │
/// │                                                                          │
/// │                        LOGIC LAYER                                       │
/// └─────────────────────────────────────────────────────────────────────────┘
/// ```
///
/// ## Thread Safety
///
/// - All types exposed through this protocol are `Sendable`
/// - `AsyncStream` ensures safe delivery to any actor context
/// - Commands are `async` and execute on the implementing actor
///
/// ## Usage (Presentation Layer)
///
/// ```swift
/// @MainActor
/// final class TransportViewModel: ObservableObject {
///     @Published var state = TransportState.empty
///     @Published var midiSync = MIDISyncState.empty
///
///     private let service: TransportServiceProtocol
///
///     init(service: TransportServiceProtocol) {
///         self.service = service
///         observeState()
///     }
///
///     private func observeState() {
///         Task {
///             for await newState in service.transportStateStream {
///                 self.state = newState
///             }
///         }
///     }
///
///     func togglePlayback() {
///         Task { await service.togglePlayback() }
///     }
/// }
/// ```
///
/// ## Usage (Logic Layer)
///
/// ```swift
/// actor TransportActor: TransportServiceProtocol {
///     private let (stream, continuation) = AsyncStream<TransportState>.makeStream()
///
///     var transportStateStream: AsyncStream<TransportState> { stream }
///
///     func play() async {
///         // Update internal state
///         // Emit to stream
///         continuation.yield(newState)
///     }
/// }
/// ```
public protocol TransportServiceProtocol: Sendable {

    // MARK: - State Streams (Logic → UI)

    /// Stream of transport state updates.
    ///
    /// Emits whenever playback state, position, or content changes.
    /// High-frequency during playback (up to frame rate).
    ///
    /// - Note: Consumers should be prepared for updates every ~33ms at 30fps.
    var transportStateStream: AsyncStream<TransportState> { get }

    /// Stream of MIDI sync state updates.
    ///
    /// Emits when MTC sync state changes or MMC commands are received.
    /// Lower frequency than transport state (typically on state transitions).
    var midiSyncStateStream: AsyncStream<MIDISyncState> { get }

    // MARK: - Transport Commands (UI → Logic)

    /// Start playback from the current position.
    ///
    /// If already playing, this has no effect.
    func play() async

    /// Pause playback at the current position.
    ///
    /// If already paused, this has no effect.
    func pause() async

    /// Toggle between play and pause states.
    func togglePlayback() async

    /// Stop playback and return to the start of the timeline.
    func stop() async

    /// Seek to a specific frame on the timeline.
    ///
    /// - Parameter frame: Target frame number (clamped to valid range)
    func seekToFrame(_ frame: Int) async

    /// Seek to a specific timecode.
    ///
    /// The timecode is converted to a frame number based on the timeline's
    /// frame rate and start timecode.
    ///
    /// - Parameter timecode: Target timecode
    func seekToTimecode(_ timecode: Timecode) async

    /// Step forward by one frame.
    func stepForward() async

    /// Step backward by one frame.
    func stepBackward() async

    // MARK: - MIDI Commands (UI → Logic)

    /// Select a MIDI input source by name.
    ///
    /// - Parameter name: Display name of the MIDI input, or `nil` to disconnect
    func selectMIDIInput(_ name: String?) async

    /// Refresh the list of available MIDI inputs.
    ///
    /// Call this when opening a MIDI settings panel or when the user
    /// requests a refresh.
    func refreshMIDIInputs() async

    /// Set the local frame rate for MTC interpretation.
    ///
    /// This affects how incoming MTC quarter-frames are decoded.
    ///
    /// - Parameter frameRate: The frame rate to use for MTC decoding
    func setMTCFrameRate(_ frameRate: TimecodeFrameRate) async

    // MARK: - Audio Configuration (UI → Logic)

    /// Set the audio output device.
    ///
    /// - Parameter deviceUID: CoreAudio device UID, or `nil` for system default
    func setAudioOutputDevice(_ deviceUID: String?) async
}

// MARK: - Implementation Notes

/*
 ## Logic Layer Implementation (Managers)

 The implementing actor should:

 1. **Create stream continuations** in init:
    ```swift
    actor TransportActor: TransportServiceProtocol {
        private let transportContinuation: AsyncStream<TransportState>.Continuation
        private let midiSyncContinuation: AsyncStream<MIDISyncState>.Continuation

        let transportStateStream: AsyncStream<TransportState>
        let midiSyncStateStream: AsyncStream<MIDISyncState>

        init() {
            (transportStateStream, transportContinuation) = AsyncStream.makeStream()
            (midiSyncStateStream, midiSyncContinuation) = AsyncStream.makeStream()
        }
    }
    ```

 2. **Emit state on every change**:
    ```swift
    private func emitTransportState() {
        let state = TransportState(
            isPlaying: isPlaying,
            currentTimecode: currentTimecode,
            // ... etc
        )
        transportContinuation.yield(state)
    }
    ```

 3. **Handle MIDI callbacks off MainActor**:
    ```swift
    // MIDIKit callback (runs on arbitrary thread)
    mtcReceiver = MTCReceiver(...) { [weak self] timecode, ... in
        Task {
            await self?.handleMTCTimecode(timecode)
        }
    }
    ```

 4. **Convert MIDIKit types to contract types**:
    ```swift
    private func convertMTCState(_ state: MTCReceiver.State) -> MTCSyncState {
        switch state {
        case .idle: return .idle
        case .preSync: return .preSync
        case .sync: return .sync
        case .freewheeling: return .freewheeling
        case .incompatibleFrameRate: return .incompatibleFrameRate
        }
    }
    ```

 ## UI Layer Consumption (Views)

 The ViewModel should:

 1. **Subscribe to streams on init**:
    ```swift
    @MainActor
    final class TransportViewModel: ObservableObject {
        @Published private(set) var state = TransportState.empty

        private var stateTask: Task<Void, Never>?

        init(service: TransportServiceProtocol) {
            stateTask = Task {
                for await newState in service.transportStateStream {
                    self.state = newState
                }
            }
        }

        deinit {
            stateTask?.cancel()
        }
    }
    ```

 2. **Wrap commands in Task for View actions**:
    ```swift
    func togglePlayback() {
        Task { await service.togglePlayback() }
    }
    ```

 3. **Derive computed properties for View simplicity**:
    ```swift
    var canPlay: Bool { state.hasContent }
    var timecodeString: String { state.currentTimecode.stringValue() }
    var progressPercent: Double {
        guard state.durationFrames > 0 else { return 0 }
        return Double(state.currentFrame) / Double(state.durationFrames)
    }
    ```
 */
