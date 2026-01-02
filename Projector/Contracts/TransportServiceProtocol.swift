//
//  TransportServiceProtocol.swift
//  Projector
//
//  THE CONTRACT: Transport Service
//  Defined by: arch-architect
//  Implemented by: backend-logic (TransportActor + MIDITransportActor)
//  Consumed by: ui-specialist (TransportViewModel)
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
    public init(
        isPlaying: Bool,
        currentTimecode: Timecode,
        currentFrame: Int,
        durationFrames: Int,
        frameRate: TimecodeFrameRate,
        isInGap: Bool,
        hasContent: Bool
    ) {
        self.isPlaying = isPlaying
        self.currentTimecode = currentTimecode
        self.currentFrame = currentFrame
        self.durationFrames = durationFrames
        self.frameRate = frameRate
        self.isInGap = isInGap
        self.hasContent = hasContent
    }

    /// An empty state representing no content loaded.
    public static let empty = TransportState(
        isPlaying: false,
        currentTimecode: Timecode(.components(h: 0, m: 0, s: 0, f: 0), at: .fps24, by: .clamping),
        currentFrame: 0,
        durationFrames: 0,
        frameRate: .fps24,
        isInGap: false,
        hasContent: false
    )
}

// MARK: - MIDI Sync State Types

/// Represents the current MTC (MIDI Time Code) sync state.
///
/// This enum mirrors `MTCReceiver.State` from MIDIKit but is defined
/// independently to avoid leaking Logic layer dependencies to the UI.
///
/// ## Thread Safety
/// This type is `Sendable` and can safely cross actor boundaries.
public enum MTCSyncState: Sendable, Equatable, Hashable {
    /// No MTC data is being received.
    case idle

    /// MTC quarter-frames are being received; waiting to lock.
    case preSync

    /// MTC is locked and timecode is synchronized.
    case sync

    /// MTC data has dropped out; freewheeling to maintain continuity.
    case freewheeling

    /// Incoming MTC frame rate is incompatible with local frame rate.
    case incompatibleFrameRate

    /// Human-readable description for UI display.
    public var displayName: String {
        switch self {
        case .idle: return "Idle"
        case .preSync: return "Pre-Sync"
        case .sync: return "Synced"
        case .freewheeling: return "Freewheeling"
        case .incompatibleFrameRate: return "Frame Rate Mismatch"
        }
    }

    /// Whether this state indicates active reception of MTC.
    public var isReceiving: Bool {
        switch self {
        case .idle, .incompatibleFrameRate:
            return false
        case .preSync, .sync, .freewheeling:
            return true
        }
    }
}

/// MMC (MIDI Machine Control) commands received from external devices.
///
/// This enum represents transport commands that can be triggered via MMC,
/// allowing DAWs and hardware controllers to control Projector's playback.
///
/// ## Thread Safety
/// This type is `Sendable` and can safely cross actor boundaries.
public enum MMCTransportCommand: Sendable, Equatable {
    /// Stop playback.
    case stop

    /// Start playback.
    case play

    /// Deferred play (wait for next frame boundary).
    case deferredPlay

    /// Fast-forward (shuttle forward).
    case fastForward

    /// Rewind (shuttle backward).
    case rewind

    /// Pause playback.
    case pause

    /// Locate to a specific timecode.
    case locate(Timecode)

    /// Human-readable description for UI display.
    public var displayName: String {
        switch self {
        case .stop: return "Stop"
        case .play: return "Play"
        case .deferredPlay: return "Deferred Play"
        case .fastForward: return "Fast Forward"
        case .rewind: return "Rewind"
        case .pause: return "Pause"
        case .locate(let tc): return "Locate to \(tc.stringValue())"
        }
    }
}

/// Complete MIDI sync state for UI display.
///
/// Combines MTC sync state with additional metadata needed for
/// the MIDI settings panel and sync status indicators.
///
/// ## Thread Safety
/// This type is `Sendable` and can safely cross actor boundaries.
public struct MIDISyncState: Sendable, Equatable {
    /// Current MTC receiver state.
    public let mtcState: MTCSyncState

    /// Last received MTC timecode (may differ from transport position).
    public let mtcTimecode: Timecode?

    /// Whether MTC is actively being received.
    public let isReceivingMTC: Bool

    /// Last MMC command received (for status display).
    public let lastMMCCommand: MMCTransportCommand?

    /// Name of the selected MIDI input source.
    public let selectedInputName: String?

    /// Available MIDI input sources.
    public let availableInputs: [String]

    /// Creates a new MIDI sync state snapshot.
    ///
    /// - Parameters:
    ///   - mtcState: Current MTC receiver state
    ///   - mtcTimecode: Last received MTC timecode
    ///   - isReceivingMTC: Whether MTC is being received
    ///   - lastMMCCommand: Last MMC command received
    ///   - selectedInputName: Selected MIDI input name
    ///   - availableInputs: List of available MIDI inputs
    public init(
        mtcState: MTCSyncState,
        mtcTimecode: Timecode?,
        isReceivingMTC: Bool,
        lastMMCCommand: MMCTransportCommand?,
        selectedInputName: String?,
        availableInputs: [String]
    ) {
        self.mtcState = mtcState
        self.mtcTimecode = mtcTimecode
        self.isReceivingMTC = isReceivingMTC
        self.lastMMCCommand = lastMMCCommand
        self.selectedInputName = selectedInputName
        self.availableInputs = availableInputs
    }

    /// Empty state representing no MIDI activity.
    public static let empty = MIDISyncState(
        mtcState: .idle,
        mtcTimecode: nil,
        isReceivingMTC: false,
        lastMMCCommand: nil,
        selectedInputName: nil,
        availableInputs: []
    )
}

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
 ## Logic Layer Implementation (backend-logic)

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

 ## UI Layer Consumption (ui-specialist)

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

// MARK: - Migration Guide

/*
 ## Migrating from @MainActor MIDIManager

 ### Before (VIOLATES STANDARDS):
 ```swift
 @MainActor
 final class MIDIManager: ObservableObject {
     @Published var currentTimecode: Timecode  // Blocks UI on every update!

     func handleMTCQuarterFrame() {
         // Runs on main thread - UI hitches during sync
     }
 }
 ```

 ### After (COMPLIANT):
 ```swift
 // Logic Layer
 actor MIDITransportActor {
     private var currentTimecode: Timecode  // Actor-isolated

     func handleMTCQuarterFrame() async {
         // Runs on actor - UI never blocked
     }
 }

 // Presentation Layer
 @MainActor
 final class TransportViewModel: ObservableObject {
     @Published var timecode: Timecode  // Only updated via AsyncStream
 }
 ```

 ### Key Changes:
 1. Replace @MainActor class with actor
 2. Replace @Published with AsyncStream emissions
 3. Replace Combine callbacks with async iteration
 4. Move MIDIKit types to actor, expose contract types to UI
 */
