import Foundation
import Combine
import SwiftUI
import SwiftTimecodeCore

// MARK: - MIDISyncViewModel

/// ViewModel that bridges the UI layer to the MIDI sync service.
///
/// This is a `@MainActor` observable object that consumes `MIDISyncServiceProtocol`
/// and exposes convenient properties and methods for SwiftUI views to display
/// MIDI synchronization state (MTC timecode, sync status, input selection, etc.).
///
/// ## Architecture
///
/// `MIDISyncViewModel` sits at the boundary between SwiftUI Views and the
/// Logic Layer (MIDISyncActor):
///
/// ```
/// ┌─────────────────────────────────────────────────────────────┐
/// │                    SwiftUI Views                            │
/// │  - Use @StateObject var midiSync: MIDISyncViewModel         │
/// │  - Access @Published properties and call methods            │
/// └─────────────────────────────────────────────────────────────┘
///                               │
///                               ▼
/// ┌─────────────────────────────────────────────────────────────┐
/// │              MIDISyncViewModel (this file)                  │
/// │  - @MainActor for UI thread safety                          │
/// │  - ObservableObject with @Published properties              │
/// │  - Subscribes to syncStateStream from service               │
/// │  - Delegates actions to the service actor                   │
/// └─────────────────────────────────────────────────────────────┘
///                               │
///                               ▼
/// ┌─────────────────────────────────────────────────────────────┐
/// │              MIDISyncActor (Logic Layer)                    │
/// │  - Implements MIDISyncServiceProtocol                       │
/// │  - Handles all MIDI processing                              │
/// │  - Emits state updates via AsyncStream                      │
/// └─────────────────────────────────────────────────────────────┘
/// ```
///
/// ## Thread Safety
///
/// - The ViewModel is confined to the main thread via `@MainActor`
/// - It safely consumes the `AsyncStream` from the service actor
/// - All state updates are delivered to the main thread before updating @Published properties
/// - A task is retained in `deinit` and cancelled to prevent memory leaks
///
/// ## Usage in Views
///
/// ```swift
/// struct MIDISyncPanel: View {
///     @StateObject var midiSync: MIDISyncViewModel
///
///     var body: some View {
///         VStack {
///             Text(midiSync.syncStatusText)
///             Text(midiSync.timecodeString)
///             Picker("Input", selection: $midiSync.selectedInputName) {
///                 ForEach(midiSync.availableInputs, id: \.self) { input in
///                     Text(input).tag(Optional(input))
///                 }
///             }
///         }
///     }
/// }
/// ```
@MainActor
public final class MIDISyncViewModel: ObservableObject {

    // MARK: - Published Properties (UI State)

    /// Current MTC receiver synchronization state (idle, locking, synced, etc.).
    ///
    /// Updates whenever the external MIDI source changes sync status.
    /// Use ``syncStatusText`` for user-friendly display.
    /// The lock the receiver has predicted, if one is pending.
    ///
    /// Republished so playback can be scheduled for the lock instant. See
    /// `MTCChaseLock`.
    @Published public var pendingLock: MTCChaseLock?

    @Published public var mtcState: MTCSyncState = .idle

    /// Current MTC timecode received from the external source, if any.
    ///
    /// `nil` when no MTC is being received or synced.
    /// Use ``timecodeString`` for formatted display.
    @Published public var mtcTimecode: Timecode?

    /// Whether MTC quarter-frame messages are actively being received.
    ///
    /// `true` indicates the external source is actively sending MTC at any state
    /// (preSync, sync, or freewheeling). `false` means idle or no input selected.
    @Published public var isReceivingMTC: Bool = false

    /// The last MIDI Machine Control (MMC) command received, if any.
    ///
    /// Reflects commands like play, stop, locate, etc. from the external source.
    /// Use ``MMCCommand.displayName`` for user display.
    @Published public var lastMMCCommand: MMCCommand?

    /// What kind of MIDI is arriving on the selected input.
    @Published public var incomingSignal: IncomingMIDISignal = .none

    /// Frame rate reported by the incoming MTC stream, if any.
    @Published public var incomingFrameRate: TimecodeFrameRate?

    /// Whether an external device (MTC or MMC) is driving the transport.
    ///
    /// When true the app is slaved to the DAW and local transport input is
    /// ignored, so the two cannot fight over the playhead.
    @Published public var isExternallyControlled: Bool = false

    /// Display name of the currently selected MIDI input port.
    ///
    /// `nil` indicates no input is selected (all inputs disconnected).
    /// Includes the built-in "Projector MTC IN" and "Projector MMC IN" ports and any connected hardware.
    @Published public var selectedInputName: String?

    /// All available MIDI input port names.
    ///
    /// Includes the virtual port and any connected MIDI hardware inputs.
    /// Updated after ``refreshInputs()`` is called or when hardware is connected/disconnected.
    @Published public var availableInputs: [String] = []

    // MARK: - Sync Quality Metrics

    /// Progress toward sync lock (0...lockFramesRequired).
    @Published public var lockProgress: Int = 0

    /// Number of frames required to establish lock.
    @Published public var lockFramesRequired: Int = 8

    /// Frames since last MTC message (0...dropoutFramesAllowed).
    @Published public var dropoutCounter: Int = 0

    /// Number of frames allowed before entering freewheeling.
    @Published public var dropoutFramesAllowed: Int = 10

    /// How long sync has been maintained, if currently synced.
    @Published public var syncDuration: TimeInterval = 0

    /// Timestamp of the last quarter-frame received.
    @Published public var lastQFTimestamp: Date?

    // MARK: - Drift Metrics

    /// Drift between MTC and local playback (in frames).
    ///
    /// Positive value means MTC is ahead, negative means MTC is behind.
    /// Use ``driftString`` for formatted display.
    @Published public var driftFrames: Double = 0.0

    /// Drift quality status for UI display.
    ///
    /// Color-coded drift severity: excellent, good, fair, poor.
    /// Use ``driftColor`` for color display.
    @Published public var driftStatus: DriftStatus = .excellent

    // MARK: - Private Properties

    /// Reference to the MIDI sync service (actor).
    ///
    /// All commands are delegated to this actor, which handles the actual
    /// MIDI processing on a dedicated execution context.
    private let service: MIDISyncServiceProtocol

    /// The stream subscription task.
    ///
    /// Held as a property so it can be cancelled in `deinit` to prevent memory leaks.
    private var streamTask: Task<Void, Never>?

    /// Local frame rate for MTC comparison.
    ///
    /// Used to compute ``syncStatusText``. May differ from the incoming MTC frame rate.
    private var localFrameRate: TimecodeFrameRate = .fps30

    // MARK: - Initialization

    /// Creates a new MIDI sync view model.
    ///
    /// Immediately subscribes to the service's `syncStateStream` and begins updating
    /// published properties as state changes arrive.
    ///
    /// - Parameter service: The MIDI sync service (typically an instance of `MIDISyncActor`)
    ///
    /// ## Precondition
    /// The service must already be started (i.e., `await midiSync.start()` must have
    /// been called on the underlying actor).
    ///
    /// ## Example
    /// ```swift
    /// let midiSync = MIDISyncActor()
    /// try await midiSync.start()
    /// let viewModel = MIDISyncViewModel(service: midiSync)
    /// ```
    public init(service: MIDISyncServiceProtocol) {
        self.service = service
        subscribeToSyncState()
    }

    // MARK: - Lifecycle

    /// Cleans up resources when the ViewModel is deallocated.
    ///
    /// Cancels the stream subscription task to prevent memory leaks and
    /// ensure the AsyncStream is properly terminated.
    deinit {
        streamTask?.cancel()
    }

    // MARK: - Computed Properties for UI Display

    /// Human-readable timecode string for display.
    ///
    /// - Returns: Formatted timecode (e.g., "01:23:45:29") if valid timecode exists,
    ///           otherwise returns "00:00:00:00".
    ///
    /// ## Example
    /// ```swift
    /// Text(midiSync.timecodeString) // "01:23:45:29"
    /// ```
    public var timecodeString: String {
        mtcTimecode?.stringValue() ?? "00:00:00:00"
    }

    /// Human-readable sync status text for display.
    ///
    /// Combines the MTC state display name with additional context:
    /// - If no input is selected: "No Input"
    /// - If input is selected but idle: "No MTC"
    /// - If frame rate mismatch: "Frame Rate Mismatch (expecting 30.00)"
    /// - Otherwise: The state's display name (e.g., "Synced", "Locking...")
    ///
    /// - Returns: A user-friendly status string suitable for display in the UI.
    ///
    /// ## Example
    /// ```swift
    /// Text(midiSync.syncStatusText)
    /// // Shows: "No Input", "Synced", "Locking...", "Frame Rate Mismatch (expecting 30.00)", etc.
    /// ```
    public var syncStatusText: String {
        guard selectedInputName != nil else {
            return "No Input"
        }

        switch mtcState {
        case .idle:
            return "No MTC"
        case .incompatibleFrameRate:
            return "Frame Rate Mismatch (expecting \(String(format: "%.2f", localFrameRate.fps)))"
        default:
            return mtcState.displayName
        }
    }

    // MARK: - Sync Quality Computed Properties

    /// Progress toward sync lock as a percentage (0.0 to 1.0).
    ///
    /// During preSync, this increases as quarter-frames are received.
    /// Once synced, this is always 1.0.
    public var lockProgressPercent: Double {
        guard lockFramesRequired > 0 else { return 0 }
        return Double(lockProgress) / Double(lockFramesRequired)
    }

    /// Whether the connection is approaching dropout.
    ///
    /// Returns `true` when dropoutCounter exceeds 50% of dropoutFramesAllowed.
    /// Use this to show a warning indicator.
    public var isApproachingDropout: Bool {
        guard dropoutFramesAllowed > 0 else { return false }
        return dropoutCounter > dropoutFramesAllowed / 2
    }

    /// Overall sync quality level for UI display.
    public var syncQuality: SyncQuality {
        switch mtcState {
        case .idle:
            return .none
        case .preSync:
            return .acquiring
        case .sync:
            if isApproachingDropout {
                return .fair
            } else if syncDuration > 5 {
                return .excellent
            } else {
                return .good
            }
        case .freewheeling:
            return .poor
        case .incompatibleFrameRate:
            return .error
        }
    }

    /// Color representing the current sync quality.
    ///
    /// - gray: Idle/no MTC
    /// - yellow: Locking/acquiring
    /// - green: Synced (good/excellent)
    /// - orange: Freewheeling or approaching dropout
    /// - red: Incompatible frame rate
    public var syncStatusColor: Color {
        syncQuality.color
    }

    /// Formatted string showing how long sync has been maintained.
    ///
    /// Returns empty string if not synced.
    public var syncDurationString: String {
        guard mtcState == .sync, syncDuration > 0 else { return "" }

        if syncDuration < 60 {
            return String(format: "%.0fs", syncDuration)
        } else if syncDuration < 3600 {
            let minutes = Int(syncDuration) / 60
            let seconds = Int(syncDuration) % 60
            return String(format: "%d:%02d", minutes, seconds)
        } else {
            let hours = Int(syncDuration) / 3600
            let minutes = (Int(syncDuration) % 3600) / 60
            return String(format: "%d:%02d:%02d", hours, minutes, Int(syncDuration) % 60)
        }
    }

    /// Formatted drift string for display.
    ///
    /// Shows drift in frames with sign (e.g., "+0.2 frames", "-1.5 frames").
    /// Only meaningful when synced.
    ///
    /// - Returns: Formatted drift string with sign and unit.
    ///
    /// ## Example
    /// ```swift
    /// Text(midiSync.driftString) // "+0.2 frames"
    /// ```
    public var driftString: String {
        let sign = driftFrames >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.1f", driftFrames)) frames"
    }

    /// Color representing the current drift status.
    ///
    /// - green: Excellent or good drift (<1.0 frames)
    /// - yellow: Fair drift (1.0-2.0 frames)
    /// - red: Poor drift (>2.0 frames)
    ///
    /// - Returns: SwiftUI color for UI display.
    ///
    /// ## Example
    /// ```swift
    /// Text(midiSync.driftString)
    ///     .foregroundColor(midiSync.driftColor)
    /// ```
    public var driftColor: Color {
        switch driftStatus {
        case .excellent, .good:
            return .green
        case .fair:
            return .yellow
        case .poor:
            return .red
        }
    }

    /// Whether a valid, synced timecode is currently being received.
    ///
    /// Returns `true` only if MTC state is `.sync` and a timecode value exists.
    /// Useful for enabling UI elements that depend on valid timecode.
    ///
    /// - Returns: `true` if synced and timecode is valid, `false` otherwise.
    ///
    /// ## Example
    /// ```swift
    /// Button("Locate") {
    ///     // Only enabled when hasValidTimecode is true
    /// }
    /// .disabled(!midiSync.hasValidTimecode)
    /// ```
    public var hasValidTimecode: Bool {
        mtcState == .sync && mtcTimecode != nil
    }

    // MARK: - Commands

    /// Selects a MIDI input port and connects MTC/MMC receivers to it.
    ///
    /// This method disconnects from the currently selected input (if any) and
    /// connects to the specified input. The service will automatically emit a
    /// new state update reflecting the change.
    ///
    /// - Parameter name: The display name of the MIDI input to select, or `nil` to disconnect.
    ///                  Common values include "Projector MTC IN" (built-in) or hardware port names.
    ///
    /// ## Thread Safety
    /// This method is safe to call from the main thread (where Views operate).
    /// It delegates to the service actor which handles the actual MIDI work.
    ///
    /// ## Example
    /// ```swift
    /// // Connect to a specific hardware input
    /// await midiSync.selectInput("ProTools MIDI OUT")
    ///
    /// // Use the virtual input
    /// await midiSync.selectInput("Projector MTC IN")
    ///
    /// // Disconnect all inputs
    /// await midiSync.selectInput(nil)
    /// ```
    public func selectInput(_ name: String?) async {
        await service.selectInput(name)
    }

    /// Refreshes the list of available MIDI input ports.
    ///
    /// Call this method after the user connects or disconnects MIDI hardware
    /// to update ``availableInputs``. The service will emit a new state update
    /// with the refreshed input list.
    ///
    /// ## Thread Safety
    /// This method is safe to call from the main thread.
    /// It delegates to the service actor which performs the enumeration.
    ///
    /// ## Example
    /// ```swift
    /// Button("Refresh Inputs") {
    ///     await midiSync.refreshInputs()
    /// }
    /// ```
    public func refreshInputs() async {
        await service.refreshAvailableInputs()
    }

    /// Sets the local MTC frame rate for synchronization comparison.
    ///
    /// This tells the MIDI sync system what frame rate your project uses.
    /// If the incoming MTC frame rate differs, the sync state will report
    /// ``MTCSyncState.incompatibleFrameRate``.
    ///
    /// - Parameter frameRate: The expected frame rate (e.g., .fps24, .fps30, .fps60)
    ///
    /// ## Thread Safety
    /// This method is safe to call from the main thread.
    /// It delegates to the service actor.
    ///
    /// ## Example
    /// ```swift
    /// // Update when user changes project frame rate
    /// await midiSync.setFrameRate(.fps24)
    /// ```
    public func setFrameRate(_ frameRate: TimecodeFrameRate) async {
        self.localFrameRate = frameRate
        await service.setLocalFrameRate(frameRate)
    }

    // MARK: - Private Helpers

    /// Subscribes to the service's state stream and updates published properties.
    ///
    /// This method starts a background task that continuously listens for
    /// `MIDISyncState` updates from the service's `AsyncStream`. As each update
    /// arrives, the @Published properties are updated on the main thread.
    ///
    /// The task is stored in ``streamTask`` so it can be cancelled in `deinit`.
    private func subscribeToSyncState() {
        streamTask = Task {
            for await state in service.syncStateStream {
                // Transitions only. This stream ticks on the idle heartbeat and
                // again on every incoming frame, so recording each update would
                // bury everything else in the ring within seconds.
                if self.mtcState != state.mtcState {
                    diagnosticLog(.info, .midi, "MTC state \(self.mtcState) -> \(state.mtcState)")
                }
                if self.selectedInputName != state.selectedInputName {
                    diagnosticLog(.info, .midi, "MIDI input: \(state.selectedInputName ?? "none")")
                }

                // Update all published properties atomically
                self.pendingLock = state.pendingLock
                self.mtcState = state.mtcState
                self.mtcTimecode = state.mtcTimecode
                self.isReceivingMTC = state.isReceivingMTC
                self.lastMMCCommand = state.lastMMCCommand
                self.incomingSignal = state.incomingSignal
                self.incomingFrameRate = state.incomingFrameRate
                self.isExternallyControlled = state.isExternallyControlled
                self.selectedInputName = state.selectedInputName
                self.availableInputs = state.availableInputs
                self.localFrameRate = state.localFrameRate

                // Sync quality metrics
                self.lockProgress = state.lockProgress
                self.lockFramesRequired = state.lockFramesRequired
                self.dropoutCounter = state.dropoutCounter
                self.dropoutFramesAllowed = state.dropoutFramesAllowed
                self.syncDuration = state.syncDuration
                self.lastQFTimestamp = state.lastQFTimestamp

                // Drift metrics
                self.driftFrames = state.driftFrames
                self.driftStatus = state.driftStatus
            }
        }
    }
}

// MARK: - SyncQuality

/// Represents the overall quality of the MIDI sync connection.
public enum SyncQuality: Sendable, Equatable {
    /// No MTC being received.
    case none

    /// Actively acquiring sync lock.
    case acquiring

    /// Synced with excellent stability (>5 seconds stable).
    case excellent

    /// Synced with good stability.
    case good

    /// Synced but approaching dropout threshold.
    case fair

    /// Connection lost, freewheeling.
    case poor

    /// Incompatible frame rate detected.
    case error

    /// Color for UI display.
    public var color: Color {
        switch self {
        case .none:
            return .gray
        case .acquiring:
            return .yellow
        case .excellent, .good:
            return .green
        case .fair:
            return .orange
        case .poor:
            return .orange
        case .error:
            return .red
        }
    }

    /// Human-readable description.
    public var displayName: String {
        switch self {
        case .none: return "No MTC"
        case .acquiring: return "Acquiring"
        case .excellent: return "Excellent"
        case .good: return "Good"
        case .fair: return "Fair"
        case .poor: return "Poor"
        case .error: return "Error"
        }
    }
}
