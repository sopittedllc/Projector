import Foundation
import Combine
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

    /// Display name of the currently selected MIDI input port.
    ///
    /// `nil` indicates no input is selected (all inputs disconnected).
    /// Includes both the virtual "Projector MIDI IN" port and any connected hardware.
    @Published public var selectedInputName: String?

    /// All available MIDI input port names.
    ///
    /// Includes the virtual port and any connected MIDI hardware inputs.
    /// Updated after ``refreshInputs()`` is called or when hardware is connected/disconnected.
    @Published public var availableInputs: [String] = []

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
            return "Frame Rate Mismatch (expecting \(String(format: "%.2f", localFrameRate.frameRate)))"
        default:
            return mtcState.displayName
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
    ///                  Common values include "Projector MIDI IN" (virtual) or hardware port names.
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
    /// await midiSync.selectInput("Projector MIDI IN")
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
                // Update all published properties atomically
                self.mtcState = state.mtcState
                self.mtcTimecode = state.mtcTimecode
                self.isReceivingMTC = state.isReceivingMTC
                self.lastMMCCommand = state.lastMMCCommand
                self.selectedInputName = state.selectedInputName
                self.availableInputs = state.availableInputs
                self.localFrameRate = state.localFrameRate
            }
        }
    }
}
