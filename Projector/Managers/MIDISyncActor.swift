import Foundation
import MIDIKitIO
import MIDIKitSync
import SwiftTimecodeCore

// MARK: - MIDISyncActor

/// Logging for the MIDI subsystem.
///
/// Deliberately its own function rather than the shared `debugPrint` helper:
/// that name collides with Swift's stdlib `debugPrint(_:separator:terminator:)`,
/// and inside this file the stdlib overload won. Its output goes to stdout,
/// which is fully buffered when stderr is redirected to a file - so every MIDI
/// log line silently disappeared, including the ones reporting why the virtual
/// port failed to open. NSLog writes to stderr unbuffered and cannot be
/// shadowed.
@inline(__always)
func midiLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    NSLog(">>> [MIDI] \(message())")
    #endif
}

/// A Swift Actor that manages MIDI synchronization via MTC and MMC.
///
/// This actor handles all MIDI Time Code (MTC) reception and MIDI Machine Control (MMC)
/// command processing on a dedicated execution context, ensuring that high-frequency
/// MIDI callbacks never block the main thread or cause UI hitches.
///
/// ## Architecture
///
/// `MIDISyncActor` sits in the Logic Layer of the application architecture:
///
/// ```
/// ┌─────────────────────────────────────────────────────────────┐
/// │                    SwiftUI Views                            │
/// └─────────────────────────────────────────────────────────────┘
///                               │
///                               ▼
/// ┌─────────────────────────────────────────────────────────────┐
/// │                 @MainActor ViewModels                       │
/// │  (MIDISyncViewModel - consumes syncStateStream)             │
/// └─────────────────────────────────────────────────────────────┘
///                               │
///                               ▼
/// ┌─────────────────────────────────────────────────────────────┐
/// │              MIDISyncActor (this file)                      │
/// │  - Actor-isolated state                                     │
/// │  - AsyncStream for state updates                            │
/// │  - MIDIKit callback handling                                │
/// └─────────────────────────────────────────────────────────────┘
///                               │
///                               ▼
/// ┌─────────────────────────────────────────────────────────────┐
/// │              MIDIKit (MIDIKitIO, MIDIKitSync)                │
/// │  - Real-time MIDI callbacks                                 │
/// │  - MTCReceiver for timecode                                 │
/// └─────────────────────────────────────────────────────────────┘
/// ```
///
/// ## Thread Safety
///
/// - All mutable state is protected by actor isolation
/// - MIDIKit callbacks (which run on arbitrary threads) are wrapped in `Task` to hop to the actor
/// - State updates are emitted via `AsyncStream` which is safe for cross-actor consumption
/// - All types crossing actor boundaries are `Sendable`
///
/// ## Usage
///
/// ```swift
/// // Create the actor
/// let midiSync = MIDISyncActor()
///
/// // Start MIDI services
/// try await midiSync.start()
///
/// // Observe state changes from a ViewModel
/// for await state in midiSync.syncStateStream {
///     await MainActor.run {
///         self.updateUI(with: state)
///     }
/// }
///
/// // Select an input
/// await midiSync.selectInput("Projector MTC IN")
/// ```
///
/// ## Performance Considerations
///
/// - MTC can generate up to 120 updates per second at 30fps (quarter-frame messages)
/// - The actor coalesces state updates to avoid overwhelming subscribers
/// - Display updates are throttled by the `displayNeedsUpdate` flag from MTCReceiver
public actor MIDISyncActor: MIDISyncServiceProtocol {

    // MARK: - Constants

    /// Name of the virtual MIDI input a DAW sends timecode to.
    public static let mtcInputName = "Projector MTC IN"

    /// Name of the virtual MIDI input a DAW sends machine control to.
    ///
    /// ## Why two ports rather than one
    ///
    /// There was one port, `Projector MIDI IN`, carrying both. A DAW asks for
    /// its MTC destination and its MMC destination in two different dialogs, and
    /// neither says which of Projector's ports it wants - so setting up machine
    /// control meant reading `Projector MIDI IN` and `Projector MIDI OUT` and
    /// guessing which end of the arrow you were being asked about. Naming the
    /// ports after what they carry answers the question in the dialog.
    ///
    /// Both ports accept anything. Splitting them is a label for the operator,
    /// not a filter: a DAW that sends MTC and MMC down one of them still works,
    /// and refusing traffic on the "wrong" port would turn a cosmetic
    /// improvement into a way to break a working session.
    public static let mmcInputName = "Projector MMC IN"

    /// Name of the virtual MIDI output Projector answers on.
    ///
    /// Only ever carries MMC replies - an Identity Reply to a device enquiry -
    /// so it is named for that. Left as `Projector MIDI OUT` it would have been
    /// the one port still named after nothing in particular, next to two that
    /// say what they are.
    public static let mmcOutputName = "Projector MMC OUT"

    /// What the single input port was called before it was split in two.
    ///
    /// Kept so a `selectedMIDIInput` stored by an older version still resolves
    /// to "the built-in ports" instead of being hunted for among the hardware
    /// and logged as missing.
    private static let legacyInputName = "Projector MIDI IN"

    /// Every name that means one of Projector's own always-on ports.
    private static var builtInInputNames: Set<String> {
        [mtcInputName, mmcInputName, legacyInputName]
    }

    /// Tag for the MTC virtual input in MIDIKit.
    private static let mtcInputTag = "ProjectorVirtualInput"

    /// Tag for the MMC virtual input in MIDIKit.
    private static let mmcInputTag = "ProjectorVirtualMMCInput"

    /// Tag for the virtual MIDI output in MIDIKit.
    private static let mmcOutputTag = "ProjectorVirtualOutput"

    /// Tag for external MIDI input connections.
    private static let inputConnectionTag = "ProjectorMIDIInput"

    /// MMC Device ID (1-126, or 127 for all-call).
    /// Using 0x7F (127) means respond to all MMC messages.
    private static let mmcDeviceID: UInt8 = 0x7F

    // MARK: - Actor State

    /// The MIDIKit manager instance.
    private var midiManager: MIDIKitIO.MIDIManager?

    /// What kind of MIDI traffic was seen most recently.
    private var incomingSignal: IncomingMIDISignal = .none

    /// When traffic was last seen, used to decay the signal back to `.none`.
    private var lastIncomingAt: Date?

    /// Frame rate reported by the incoming MTC stream.
    private var incomingFrameRate: TimecodeFrameRate?

    /// Quarter-frames seen since start, logged periodically as proof of arrival.
    private var quarterFrameCount: Int = 0

    /// Why the virtual MIDI input could not be created, if it failed.
    /// Nil when the port exists.
    public private(set) var virtualInputError: String?

    /// The MTC receiver for timecode processing.
    private var mtcReceiver: MTCReceiver?

    /// Current MTC receiver state.
    private var mtcState: MTCSyncState = .idle

    /// Current MTC timecode, if any.
    private var mtcTimecode: Timecode?

    /// Whether MTC quarter-frames are actively being received.
    private var isReceivingMTC: Bool = false

    /// Last MMC command received.
    private var lastMMCCommand: MMCCommand?

    /// When an external device last drove the transport (MTC or MMC).
    private var lastExternalControlAt: Date?

    /// Whether an external device is currently driving the transport.
    private var isExternallyControlled = false

    /// How long external control persists after the last MTC frame or MMC
    /// command before the local transport is handed back.
    private static let externalControlTimeout: TimeInterval = 2.0

    /// Name of the currently selected MIDI input.
    private var selectedInputName: String?

    /// Names of all available MIDI input ports.
    private var availableInputs: [String] = []

    /// Local frame rate for MTC sync comparison.
    private var localFrameRate: TimecodeFrameRate = .fps30

    // MARK: - Sync Quality Metrics

    /// Continuous MTC frames the receiver must see before it declares lock.
    ///
    /// This is preroll, and it is dead time: MIDIKit converts it straight into a
    /// delay before `.sync`, and `.sync` is what starts the picture. At 8 - the
    /// value this shipped with - a 24fps session paid 333ms every time the DAW
    /// rolled, which is the pause you could feel between hitting play and
    /// picture moving.
    ///
    /// Two frames is one assembled timecode plus one confirming it, which is
    /// enough to reject a stray message without making the operator wait. The
    /// cost of locking a frame early is nothing: position is already being
    /// tracked through preSync, and the drift correction in `handleTimeUpdate`
    /// pulls picture in if the first frames were wrong. MIDIKit's own default is
    /// 16; it is tuned for chasing tape, not a DAW on a virtual port in the same
    /// machine.
    private let lockFramesRequired: Int = 2

    /// Frames of missing timecode tolerated before the receiver reports idle.
    ///
    /// This is how long picture free-runs past a stop the DAW never announced.
    /// Nothing tells Projector the transport stopped - the DAW traced here sends
    /// a Locate and simply ceases timecode, no MMC Stop - so a stop is only
    /// knowable as an absence, and this is how long that absence has to last.
    ///
    /// Ten frames is 417ms at 24fps, which is a long overshoot to then settle
    /// back from on every stop. Six still rides out three consecutive missed
    /// messages - timecode arrives every two frames - while cutting the
    /// overshoot to 250ms.
    ///
    /// Not lower: freewheeling exists so a dropped message mid-reel does not
    /// hitch picture during a take, and that matters more than a crisp stop.
    private let dropoutFramesAllowed: Int = 6

    /// Progress toward sync lock (0...lockFramesRequired).
    private var lockProgress: Int = 0

    /// Frames since last MTC message.
    private var dropoutCounter: Int = 0

    /// When sync was established.
    private var syncStartTime: Date?

    /// Timestamp of the last quarter-frame received.
    private var lastQFTimestamp: Date?

    // MARK: - Drift Tracking

    /// Current local playback frame (from PlaybackEngine/TransportActor).
    private var localPlaybackFrame: Int = 0

    /// Last time drift state was emitted (for 1Hz throttling).
    private var lastDriftEmission: Date = .distantPast

    // MARK: - AsyncStream Infrastructure

    /// Continuations for every active state subscriber.
    ///
    /// Both the UI-facing view model and the transport actor consume this stream.
    /// Keeping one continuation caused the newest subscriber to disconnect the
    /// previous subscriber, which could silently stop synchronization updates.
    private var stateContinuations: [UUID: AsyncStream<MIDISyncState>.Continuation] = [:]

    /// The stream of MIDI sync state updates.
    ///
    /// Subscribers receive updates when:
    /// - MTC sync state changes (idle, preSync, sync, freewheeling, incompatibleFrameRate)
    /// - New MTC timecode is received
    /// - MMC command is received
    /// - MIDI input selection changes
    /// - Available MIDI inputs change
    ///
    /// - Note: High-frequency during active MTC sync (up to 120 updates/sec at 30fps).
    ///         Consider throttling in the consuming ViewModel if needed.
    public nonisolated var syncStateStream: AsyncStream<MIDISyncState> {
        let subscriberID = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            Task {
                await self.registerContinuation(continuation, id: subscriberID)
            }
        }
    }

    // MARK: - Initialization

    /// Creates a new MIDI sync actor.
    ///
    /// The actor is created in an unstarted state. Call ``start()`` to initialize
    /// MIDI services and begin receiving MTC/MMC.
    ///
    /// ## Example
    /// ```swift
    /// let midiSync = MIDISyncActor()
    /// try await midiSync.start()
    /// ```
    public init() {
        self.selectedInputName = Self.mtcInputName
    }

    // MARK: - Lifecycle

    /// Starts MIDI services and begins listening for MTC/MMC.
    ///
    /// This method:
    /// 1. Creates and starts the MIDIKit manager
    /// 2. Sets up the MTC receiver
    /// 3. Creates the virtual MIDI input port
    /// 4. Refreshes the list of available inputs
    /// 5. Connects to the selected input
    ///
    /// - Throws: `MIDISyncError.startupFailed` if MIDI services cannot be initialized.
    ///
    /// ## Thread Safety
    /// This method runs on the actor and is safe to call from any context.
    ///
    /// ## Example
    /// ```swift
    /// do {
    ///     try await midiSync.start()
    ///     print("MIDI sync started")
    /// } catch {
    ///     print("Failed to start MIDI: \(error)")
    /// }
    /// ```
    public func start() async throws {
        do {
            midiLog("Starting MIDI services...")
            let manager = MIDIKitIO.MIDIManager(
                clientName: "Projector",
                model: "Projector",
                manufacturer: "Projector"
            )

            try manager.start()
            self.midiManager = manager
            midiLog("MIDI manager started")

            setupMTCReceiver()
            midiLog("MTC receiver configured")

            setupVirtualInput()
            midiLog("Virtual input created")

            setupVirtualOutput()
            midiLog("Virtual output created")

            await refreshAvailableInputs()
            midiLog("Available inputs: \(availableInputs)")

            reconnectInput()
            midiLog("Connected to input: \(selectedInputName ?? "none")")

            setupNotificationObservers()

            startIdleHeartbeat()

            midiLog("MIDISyncActor started successfully")
        } catch {
            midiLog("Failed to start MIDI services: \(error)")
            throw MIDISyncError.startupFailed(underlyingError: error)
        }
    }

    /// Stops MIDI services and releases resources.
    ///
    /// Call this method when the actor is no longer needed to properly clean up
    /// MIDI connections and release system resources.
    ///
    /// ## Thread Safety
    /// This method runs on the actor and is safe to call from any context.
    public func stop() async {
        idleHeartbeat?.cancel()
        idleHeartbeat = nil
        for continuation in stateContinuations.values {
            continuation.finish()
        }
        stateContinuations.removeAll()
        mtcReceiver = nil
        midiManager = nil
        midiLog("MIDISyncActor stopped")
    }

    // MARK: - Idle Heartbeat

    /// Re-emits state on a timer so the incoming-signal readout can go stale.
    private var idleHeartbeat: Task<Void, Never>?

    /// Interval between idle state emissions.
    ///
    /// Shorter than the 1.5s staleness threshold in
    /// `decayIncomingSignalIfStale()`, so a feed that stops is reported as gone
    /// within roughly two seconds.
    /// Expressed in nanoseconds rather than `Duration`, which is macOS 13.
    private static let heartbeatNanoseconds: UInt64 = 500 * NSEC_PER_MSEC

    /// Starts the periodic state emission.
    ///
    /// `decayIncomingSignalIfStale()` is only reachable from `emitState()`, and
    /// every other call to `emitState()` is triggered by an incoming MIDI event.
    /// That made the decay unreachable in the one situation it exists for: when
    /// the sender stops, no further events arrive, nothing re-emits, and the
    /// readout holds its last timecode behind a green "live" dot indefinitely -
    /// indistinguishable from a running feed. This heartbeat is what lets a
    /// stalled feed actually be reported as stalled.
    private func startIdleHeartbeat() {
        idleHeartbeat?.cancel()
        idleHeartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.heartbeatNanoseconds)
                guard !Task.isCancelled else { return }
                await self?.emitState()
            }
        }
    }

    // MARK: - MIDISyncServiceProtocol Commands

    /// Selects a MIDI input port by name.
    ///
    /// This method disconnects from the current input (if any) and connects to
    /// the specified input. If `nil` is passed, all inputs are disconnected.
    ///
    /// - Parameter name: The display name of the MIDI input, or `nil` to disconnect.
    ///
    /// - Note: The built-in ports are always available and allow
    ///         DAWs to send MIDI directly to the application.
    ///
    /// ## Thread Safety
    /// This method runs on the actor and is safe to call from any context.
    ///
    /// ## Example
    /// ```swift
    /// // Connect to a specific input
    /// await midiSync.selectInput("Pro Tools MIDI Out")
    ///
    /// // Use the virtual input
    /// await midiSync.selectInput(MIDISyncActor.mtcInputName)
    ///
    /// // Disconnect all inputs
    /// await midiSync.selectInput(nil)
    /// ```
    public func selectInput(_ name: String?) async {
        guard selectedInputName != name else { return }
        selectedInputName = name
        reconnectInput()
        emitState()
        midiLog("Selected MIDI input: \(name ?? "none")")
    }

    /// Refreshes the list of available MIDI inputs.
    ///
    /// Call this method to update the `availableInputs` in `MIDISyncState` after
    /// the user connects or disconnects MIDI hardware.
    ///
    /// - Note: The built-in ports are always included, ahead of the hardware.
    ///
    /// ## Thread Safety
    /// This method runs on the actor and is safe to call from any context.
    ///
    /// ## Example
    /// ```swift
    /// await midiSync.refreshAvailableInputs()
    /// ```
    public func refreshAvailableInputs() async {
        guard let manager = midiManager else {
            availableInputs = [Self.mtcInputName, Self.mmcInputName]
            emitState()
            return
        }

        // Our own always-on ports first, then the hardware.
        var inputs = [Self.mtcInputName, Self.mmcInputName]

        // Add external MIDI outputs (sources) - these are where MIDI data comes FROM
        let externalSources = manager.endpoints.outputs.map { $0.displayName }
        inputs.append(contentsOf: externalSources)

        availableInputs = inputs
        emitState()
        midiLog("Refreshed available inputs: \(inputs.count) found")
    }

    /// Sets the local MTC frame rate for sync comparison.
    ///
    /// The local frame rate is used by the MTC receiver to detect frame rate
    /// mismatches between the incoming MTC stream and the project settings.
    ///
    /// - Parameter frameRate: The expected frame rate of incoming MTC.
    ///
    /// - Note: If the incoming MTC frame rate doesn't match, the sync state
    ///         will be set to `.incompatibleFrameRate`.
    ///
    /// ## Thread Safety
    /// This method runs on the actor and is safe to call from any context.
    ///
    /// ## Example
    /// ```swift
    /// // Set to match project frame rate
    /// await midiSync.setLocalFrameRate(.fps23_976)
    /// ```
    public func setLocalFrameRate(_ frameRate: TimecodeFrameRate) async {
        localFrameRate = frameRate
        mtcReceiver?.setLocalFrameRate(frameRate)
        emitState()
        midiLog("Set local frame rate: \(frameRate)")
    }

    /// Updates the local playback frame position for drift calculation.
    ///
    /// Call this method from the transport layer whenever playback position changes.
    /// Used to calculate drift between MTC and local playback.
    ///
    /// - Parameter frame: The current playback frame position.
    ///
    /// - Note: Drift updates are throttled to 1Hz to prevent UI jitter.
    ///
    /// ## Thread Safety
    /// This method runs on the actor and is safe to call from any context.
    ///
    /// ## Example
    /// ```swift
    /// await midiSync.updateLocalPlaybackFrame(1234)
    /// ```
    public func updateLocalPlaybackFrame(_ frame: Int) async {
        localPlaybackFrame = frame

        // Throttle drift emission to 1Hz
        let now = Date()
        if now.timeIntervalSince(lastDriftEmission) >= 1.0 {
            emitState()
            lastDriftEmission = now
        }
    }

    // MARK: - MTC Receiver Setup

    /// Sets up the MTC receiver with callbacks wrapped in Task for actor isolation.
    private func setupMTCReceiver() {
        // Capture self weakly for the closure
        // The closure runs on arbitrary threads from MIDIKit
        let receiver = MTCReceiver(
            name: "Projector MTC",
            initialLocalFrameRate: localFrameRate,
            syncPolicy: .init(
                lockFrames: lockFramesRequired,
                dropOutFrames: dropoutFramesAllowed
            )
        ) { [weak self] timecode, _, _, displayNeedsUpdate in
            // CRITICAL: Wrap in Task to hop to actor context
            // This callback runs on an arbitrary thread from MIDIKit
            Task { [weak self] in
                await self?.handleMTCTimecode(timecode, displayNeedsUpdate: displayNeedsUpdate)
            }
        } stateChanged: { [weak self] state in
            // CRITICAL: Wrap in Task to hop to actor context
            Task { [weak self] in
                await self?.handleMTCStateChange(state)
            }
        }

        self.mtcReceiver = receiver
        midiLog("MTC receiver configured")
    }

    /// Sets up the virtual MIDI input ports that DAWs can send to.
    ///
    /// Both ports route into the same handler. See ``mmcInputName`` for why
    /// there are two.
    private func setupVirtualInput() {
        guard let manager = midiManager else { return }

        // The MTC port keeps the UID key the single port used, so a DAW that
        // already had a destination saved keeps working. CoreMIDI routing is by
        // unique ID, not by name, so from the DAW's side this is a rename of a
        // port it is already pointed at rather than a port disappearing.
        let mtcFailure = addVirtualInput(
            to: manager,
            name: Self.mtcInputName,
            tag: Self.mtcInputTag,
            uniqueIDKey: "ProjectorMIDIInputUID"
        )

        let mmcFailure = addVirtualInput(
            to: manager,
            name: Self.mmcInputName,
            tag: Self.mmcInputTag,
            uniqueIDKey: "ProjectorMMCInputUID"
        )

        // Surfaced, not swallowed: without a port nothing a DAW sends can ever
        // arrive, and the failure was previously invisible. Either one failing
        // is worth reporting - a session with timecode but no transport control
        // is as broken as one with neither, just less obviously.
        virtualInputError = mtcFailure ?? mmcFailure
    }

    /// Creates one always-on virtual input.
    ///
    /// - Parameters:
    ///   - manager: The MIDIKit manager to create the port on.
    ///   - name: The port name a DAW will show.
    ///   - tag: MIDIKit's handle for the port.
    ///   - uniqueIDKey: Defaults key the CoreMIDI unique ID persists under, so
    ///     the port keeps its identity - and a DAW's saved routing to it - across
    ///     launches.
    /// - Returns: A description of the failure, or `nil` when the port exists.
    private func addVirtualInput(
        to manager: MIDIKitIO.MIDIManager,
        name: String,
        tag: String,
        uniqueIDKey: String
    ) -> String? {
        do {
            try manager.addInput(
                name: name,
                tag: tag,
                uniqueID: .userDefaultsManaged(key: uniqueIDKey),
                receiver: .events { [weak self] events, _, _ in
                    // CRITICAL: Wrap in Task to hop to actor context
                    Task { [weak self] in
                        await self?.handleMIDIEvents(events)
                    }
                }
            )
            midiLog("Virtual MIDI input '\(name)' created")
            return nil
        } catch {
            midiLog("FAILED to create virtual MIDI input '\(name)': \(error)")
            return error.localizedDescription
        }
    }

    /// Sets up the virtual MIDI output port for sending responses (Identity Reply, etc.).
    private func setupVirtualOutput() {
        guard let manager = midiManager else { return }

        do {
            try manager.addOutput(
                name: Self.mmcOutputName,
                tag: Self.mmcOutputTag,
                uniqueID: .userDefaultsManaged(key: "ProjectorMIDIOutputUID")
            )
            midiLog("Virtual MIDI output '\(Self.mmcOutputName)' created")
        } catch {
            midiLog("Failed to create virtual MIDI output: \(error)")
        }
    }

    /// Sets up notification observers for MIDI setup changes.
    private func setupNotificationObservers() {
        // Note: NotificationCenter observers need careful handling with actors
        // We use Task to hop back to actor context
        NotificationCenter.default.addObserver(
            forName: .midiKitIOSetupChanged,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { [weak self] in
                await self?.refreshAvailableInputs()
            }
        }
    }

    // MARK: - Input Connection

    /// Reconnects to the currently selected MIDI input.
    private func reconnectInput() {
        guard let manager = midiManager else { return }

        // Remove existing connection
        if let existingConnection = manager.managedInputConnections[Self.inputConnectionTag] {
            existingConnection.removeAllOutputs()
        }

        guard let inputName = selectedInputName else { return }

        // Selecting one of our own ports connects nothing: they are created by
        // `setupVirtualInput()` and receive continuously, whatever is selected.
        // The legacy name counts, so a selection stored before the split is not
        // hunted for among the hardware and logged as missing.
        if Self.builtInInputNames.contains(inputName) {
            midiLog("Using built-in MIDI input: \(inputName)")
            return
        }

        // Find matching endpoint (outputs are sources that send MIDI data)
        guard let endpoint = manager.endpoints.outputs.first(where: { $0.displayName == inputName }) else {
            midiLog("MIDI source not found: \(inputName)")
            return
        }

        do {
            if let existingConnection = manager.managedInputConnections[Self.inputConnectionTag] {
                existingConnection.add(outputs: [endpoint])
                midiLog("Added MIDI source: \(inputName)")
            } else {
                try manager.addInputConnection(
                    to: .none,
                    tag: Self.inputConnectionTag,
                    receiver: .events { [weak self] events, _, _ in
                        Task { [weak self] in
                            await self?.handleMIDIEvents(events)
                        }
                    }
                )
                manager.managedInputConnections[Self.inputConnectionTag]?.add(outputs: [endpoint])
                midiLog("Connected to MIDI source: \(inputName)")
            }
        } catch {
            midiLog("Failed to connect to MIDI source: \(error)")
        }
    }

    // MARK: - MIDI Event Handling

    /// Handles incoming MIDI events.
    ///
    /// This method is called from MIDIKit callbacks via Task, ensuring it runs
    /// on the actor's execution context.
    ///
    /// - Parameter events: The MIDI events to process.
    private func handleMIDIEvents(_ events: [MIDIEvent]) {
        for event in events {
            // Feed to MTC receiver for timecode parsing
            mtcReceiver?.midiIn(event: event)

            // Check for SysEx messages (MTC Full Frame, MMC commands, Identity Request)
            switch event {
            case .sysEx7(let sysEx):
                midiLog("SysEx7: \(sysEx.data.map { String(format: "%02X", $0) }.joined(separator: " "))")
                handleSysEx(sysEx.data)
            case .universalSysEx7(let universalSysEx):
                midiLog("UniversalSysEx7: type=\(universalSysEx.universalType), subID1=\(universalSysEx.subID1), subID2=\(universalSysEx.subID2)")
                handleUniversalSysEx(universalSysEx)
            case .timecodeQuarterFrame:
                // Individually far too noisy to log, but silence made it
                // impossible to tell "no quarter-frames" from "not logged".
                // Count them and report at a readable cadence instead.
                quarterFrameCount += 1
                noteIncoming(.timecode)
                if quarterFrameCount % 120 == 1 {
                    midiLog("MTC quarter-frames received: \(quarterFrameCount) (rate: \(incomingFrameRate?.stringValue ?? "detecting"))")
                }
            case .timingClock:
                // MIDI Beat Clock: tempo, not position. Sync can never lock on
                // it, so it's tracked separately rather than counted as MIDI.
                noteIncoming(.beatClock)
            default:
                noteIncoming(.other)
                midiLog("Other event: \(event)")
            }
        }
    }

    /// Record incoming traffic, preferring timecode over lesser signals so a
    /// DAW sending both clock and MTC reports as timecode.
    private func noteIncoming(_ signal: IncomingMIDISignal) {
        lastIncomingAt = Date()
        let rank: (IncomingMIDISignal) -> Int = { s in
            switch s {
            case .none: return 0
            case .other: return 1
            case .beatClock: return 2
            case .timecode: return 3
            }
        }
        if rank(signal) >= rank(incomingSignal) {
            incomingSignal = signal
        }
        // Only positional timecode counts as being driven. Beat clock carries
        // tempo but cannot position the playhead, and `.other` is any stray note
        // or SysEx - treating either as control would lock the user out of their
        // own transport whenever a controller sent something incidental.
        if signal == .timecode {
            noteExternalControl()
        }
    }

    /// Record that an external device is driving the transport.
    ///
    /// Called for MTC and for MMC transport commands. MMC is a one-shot event -
    /// `handleMMCCommand` clears `lastMMCCommand` as soon as it emits, so there
    /// is no lasting state to read - which is why control is tracked here as a
    /// timestamp instead.
    private func noteExternalControl() {
        lastExternalControlAt = Date()
        if !isExternallyControlled {
            isExternallyControlled = true
            midiLog("External control ACQUIRED - local transport disabled (slave mode)")
        }
    }

    /// Decay the incoming signal when traffic stops, so the readout doesn't
    /// claim a live feed after the sender goes away.
    private func decayIncomingSignalIfStale() {
        if let last = lastIncomingAt, Date().timeIntervalSince(last) > 1.5 {
            incomingSignal = .none
            incomingFrameRate = nil
        }
        // Released on a longer window than the readout: MMC arrives as isolated
        // commands rather than a stream, so a tighter timeout would hand the
        // transport back between a DAW's Locate and its Play.
        if isExternallyControlled,
           let last = lastExternalControlAt,
           Date().timeIntervalSince(last) > Self.externalControlTimeout {
            isExternallyControlled = false
            midiLog("External control RELEASED - local transport re-enabled")
        }
    }

    // MARK: - Identity Request/Reply

    /// Handles MIDI Identity Request and sends Identity Reply.
    ///
    /// Identity Request format: F0 7E <channel> 06 01 F7
    /// Identity Reply format: F0 7E <channel> 06 02 <manufacturer> <family> <model> <version> F7
    ///
    /// - Parameter channel: The channel/device ID from the request.
    private func handleIdentityRequest(channel: UInt8) {
        // Only respond if the request is for us (our device ID) or all-call (0x7F)
        guard channel == Self.mmcDeviceID || channel == 0x7F else { return }

        midiLog("Received Identity Request, sending reply")

        // Send Identity Reply
        // Using non-commercial manufacturer ID (0x7D) for development
        // Family: 0x0001 (arbitrary), Model: 0x0001 (arbitrary), Version: 0x01 0x00 0x00 0x00
        sendIdentityReply(channel: channel)
    }

    /// Sends an Identity Reply message.
    ///
    /// - Parameter channel: The channel to respond on.
    private func sendIdentityReply(channel: UInt8) {
        guard let manager = midiManager,
              let output = manager.managedOutputs[Self.mmcOutputTag] else {
            midiLog("Cannot send Identity Reply - no output port")
            return
        }

        // Identity Reply data (after F0 and before F7):
        // 7E <channel> 06 02 <manufacturer-id> <family-lsb> <family-msb> <model-lsb> <model-msb> <ver1> <ver2> <ver3> <ver4>
        // Using 0x7D (non-commercial/educational manufacturer ID)
        let replyData: [UInt8] = [
            0x7D,       // Manufacturer ID (non-commercial)
            0x01, 0x00, // Family (Projector)
            0x01, 0x00, // Model
            0x01, 0x00, 0x00, 0x00  // Version 1.0.0.0
        ]

        // Built with MIDIKit's Universal SysEx constructor rather than raw
        // bytes. The previous version hand-assembled the message starting at
        // 0x7E and passed it to `sysEx7(rawBytes:)`, which expects a COMPLETE
        // message including the 0xF0 / 0xF7 framing - so every reply was
        // rejected as `malformed` and the app never answered a device enquiry.
        // This constructor supplies the framing and the 0x7E itself.
        do {
            let sysExEvent = try MIDIEvent.universalSysEx7(
                universalType: .nonRealTime,
                deviceID: UInt7(channel & 0x7F),
                subID1: 0x06,   // General Information
                subID2: 0x02,   // Identity Reply
                data: replyData
            )
            try output.send(event: sysExEvent)
            midiLog("Sent Identity Reply on channel \(channel)")
        } catch {
            midiLog("Failed to send Identity Reply: \(error)")
        }
    }

    /// Handles MTC timecode updates from the receiver.
    ///
    /// - Parameters:
    ///   - timecode: The current timecode value.
    ///   - displayNeedsUpdate: Whether the display should be updated.
    private func handleMTCTimecode(_ timecode: Timecode, displayNeedsUpdate: Bool) {
        // Update last quarter-frame timestamp for jitter/dropout tracking
        lastQFTimestamp = Date()

        // Reset dropout counter when we receive data
        dropoutCounter = 0

        noteIncoming(.timecode)

        // Read the rate from the DECODER, not from the delivered Timecode.
        //
        // `timecode.frameRate` is the rate the receiver converted INTO - which
        // is our local project rate, or a conversion artifact mid-lock. Using it
        // made the readout oscillate between 24 and 25 while Cubase held a
        // steady rate. `MTCReceiver.mtcFrameRate` is the rate decoded from the
        // quarter-frame stream itself: what the sender is actually running at.
        let decoded = mtcReceiver?.mtcFrameRate.reportedRate(forProject: localFrameRate)
        if incomingFrameRate != decoded {
            incomingFrameRate = decoded
            midiLog("Incoming MTC frame rate: \(decoded?.stringValue ?? "unknown") (project: \(localFrameRate.stringValue))")
        }

        if displayNeedsUpdate {
            midiLog("MTC Timecode: \(timecode.stringValue())")
            mtcTimecode = timecode
            emitState()
        }
    }

    /// Handles MTC state changes from the receiver.
    ///
    /// - Parameter state: The new MTC receiver state.
    private func handleMTCStateChange(_ state: MTCReceiver.State) {
        let previousState = mtcState
        mtcState = convertMTCState(state)
        isReceivingMTC = mtcState.isReceiving

        midiLog("MTC State changed: \(previousState.displayName) -> \(mtcState.displayName)")

        // Update sync quality metrics based on state transitions
        switch mtcState {
        case .idle:
            lockProgress = 0
            dropoutCounter = 0
            syncStartTime = nil

        case .preSync:
            // During preSync, lockProgress increases toward lockFramesRequired
            // MIDIKit's MTCReceiver handles the actual frame counting internally
            // We estimate progress based on state duration or just show that we're acquiring
            if previousState == .idle {
                lockProgress = 0
            }
            // Increment lock progress (capped at lockFramesRequired - 1 until sync)
            lockProgress = min(lockProgress + 1, lockFramesRequired - 1)
            syncStartTime = nil

        case .sync:
            lockProgress = lockFramesRequired
            dropoutCounter = 0
            if syncStartTime == nil {
                syncStartTime = Date()
            }

        case .freewheeling:
            // During freewheeling, dropoutCounter increases toward dropoutFramesAllowed
            dropoutCounter = min(dropoutCounter + 1, dropoutFramesAllowed)

        case .incompatibleFrameRate:
            lockProgress = 0
            dropoutCounter = 0
            syncStartTime = nil
        }

        emitState()
        midiLog("MTC state changed: \(mtcState.displayName)")
    }

    /// Converts MIDIKit's MTCReceiver.State to our protocol's MTCSyncState.
    ///
    /// - Parameter state: The MIDIKit state to convert.
    /// - Returns: The corresponding `MTCSyncState` value.
    private func convertMTCState(_ state: MTCReceiver.State) -> MTCSyncState {
        switch state {
        case .idle: return .idle
        case .preSync: return .preSync
        case .sync: return .sync
        case .freewheeling: return .freewheeling
        case .incompatibleFrameRate: return .incompatibleFrameRate
        @unknown default: return .idle
        }
    }

    // MARK: - SysEx Parsing

    /// Handles raw SysEx data for MTC Full Frame, MMC commands, and Identity Request.
    ///
    /// - Parameter data: The SysEx data (F0/F7 already stripped by MIDIKit).
    private func handleSysEx(_ data: [UInt8]) {
        guard data.count >= 3 else { return }

        // Check for Universal Non-Real Time SysEx (Identity Request)
        // Format: 7E <device-id> 06 01
        if data[0] == 0x7E && data.count >= 4 && data[2] == 0x06 && data[3] == 0x01 {
            handleIdentityRequest(channel: data[1])
            return
        }

        // Universal Real-Time SysEx format: F0 7F <device-id> <sub-id-1> <sub-id-2> ... F7
        // Note: MIDIKit strips F0/F7, so data starts at 7F
        guard data.count >= 4, data[0] == 0x7F else { return }

        let subId1 = data[2]

        // Handle MTC Full Frame messages (sub-id-1 = 0x01)
        if subId1 == 0x01 && data.count >= 8 && data[3] == 0x01 {
            handleMTCFullFrame(data)
            return
        }

        // Handle MMC commands (sub-id-1 = 0x06)
        guard subId1 == 0x06 else { return }
        handleMMCFromSysEx(data)
    }

    /// Handles Universal SysEx messages for MTC, MMC, and Identity Request.
    ///
    /// - Parameter sysEx: The parsed Universal SysEx event.
    private func handleUniversalSysEx(_ sysEx: MIDIEvent.UniversalSysEx7) {
        // Handle Non-Real Time messages (Identity Request)
        if sysEx.universalType == .nonRealTime {
            // Identity Request: subID1 = 0x06 (General Information), subID2 = 0x01 (Identity Request)
            if sysEx.subID1.uInt8Value == 0x06 && sysEx.subID2.uInt8Value == 0x01 {
                handleIdentityRequest(channel: sysEx.deviceID.uInt8Value)
            }
            return
        }

        // Handle Real Time messages (MTC, MMC)
        guard sysEx.universalType == .realTime else { return }

        if sysEx.subID1.uInt8Value == 0x01 && sysEx.subID2.uInt8Value == 0x01 {
            // MTC Full Frame message
            handleMTCFullFrameFromUniversal(sysEx.data)
        } else if sysEx.subID1.uInt8Value == 0x06 {
            // MMC command
            handleMMCFromUniversal(command: sysEx.subID2, data: sysEx.data)
        }
    }

    /// Parses MTC Full Frame from raw SysEx data.
    ///
    /// ## A Full Frame is a locate
    ///
    /// Quarter-frames mean "the transport is running"; a Full Frame means "the
    /// transport has jumped to here", which is every scrub, every playhead drag
    /// and every marker recall while the DAW is stopped.
    ///
    /// This used to set `mtcTimecode` and stop there, which made it
    /// indistinguishable downstream from a running-timecode update. The
    /// consumer then had to guess from how far the position had moved, and its
    /// guess was a 10-frame threshold - so a scrub shorter than 10 frames (417ms
    /// at 24fps) updated the readout and left the picture where it was. Raising
    /// it as a locate as well tells the consumer what the message actually
    /// meant, instead of asking it to infer intent from distance.
    ///
    /// - Parameter data: The SysEx data array.
    private func handleMTCFullFrame(_ data: [UInt8]) {
        // MTC Full Frame format (after F0/F7 stripped):
        // 7F <dev> 01 01 <hr> <mn> <sc> <fr>
        guard data.count >= 8 else { return }

        let hrByte = data[4]
        let frameRateBits = (hrByte >> 5) & 0x03
        let hours = Int(hrByte & 0x1F)
        let minutes = Int(data[5])
        let seconds = Int(data[6])
        let frames = Int(data[7])

        let frameRate = frameRateFromBits(frameRateBits)

        if let timecode = try? Timecode(
            .components(h: hours, m: minutes, s: seconds, f: frames),
            at: frameRate
        ) {
            mtcTimecode = timecode
            // Emits for us, with the timecode above already in place.
            handleMMCCommand(.locate(timecode))
        }
    }

    /// Parses MTC Full Frame from Universal SysEx data.
    ///
    /// Same as ``handleMTCFullFrame(_:)``, including raising the position as a
    /// locate: which SysEx framing a DAW happens to use does not change what a
    /// Full Frame means.
    ///
    /// - Parameter data: The data portion of the Universal SysEx.
    private func handleMTCFullFrameFromUniversal(_ data: [UInt8]) {
        guard data.count >= 4 else { return }

        let hrByte = data[0]
        let frameRateBits = (hrByte >> 5) & 0x03
        let hours = Int(hrByte & 0x1F)
        let minutes = Int(data[1])
        let seconds = Int(data[2])
        let frames = Int(data[3])

        let frameRate = frameRateFromBits(frameRateBits)

        if let timecode = try? Timecode(
            .components(h: hours, m: minutes, s: seconds, f: frames),
            at: frameRate
        ) {
            mtcTimecode = timecode
            handleMMCCommand(.locate(timecode))
        }
    }

    // MARK: - MMC Command Handling

    /// Parses MMC commands from raw SysEx data.
    ///
    /// - Parameter data: The SysEx data array.
    private func handleMMCFromSysEx(_ data: [UInt8]) {
        guard data.count >= 4 else { return }
        let command = data[3]

        switch command {
        case 0x01: handleMMCCommand(.stop)
        case 0x02: handleMMCCommand(.play)
        case 0x03: handleMMCCommand(.deferredPlay)
        case 0x04: handleMMCCommand(.fastForward)
        case 0x05: handleMMCCommand(.rewind)
        case 0x09: handleMMCCommand(.pause)
        case 0x44: parseLocateCommand(data)
        default: break
        }
    }

    /// Parses MMC commands from Universal SysEx.
    ///
    /// - Parameters:
    ///   - command: The MMC command byte.
    ///   - data: The data portion of the Universal SysEx.
    private func handleMMCFromUniversal(command: UInt7, data: [UInt8]) {
        switch command.uInt8Value {
        case 0x01: handleMMCCommand(.stop)
        case 0x02: handleMMCCommand(.play)
        case 0x03: handleMMCCommand(.deferredPlay)
        case 0x04: handleMMCCommand(.fastForward)
        case 0x05: handleMMCCommand(.rewind)
        case 0x09: handleMMCCommand(.pause)
        case 0x44: parseLocateCommandFromUniversal(data)
        default: break
        }
    }

    /// Parses a Locate command from raw SysEx data.
    ///
    /// - Parameter data: The SysEx data array.
    private func parseLocateCommand(_ data: [UInt8]) {
        // Locate format: 44 06 01 <hr> <mn> <sc> <fr> <sf>
        guard data.count >= 10, data[4] == 0x06, data[5] == 0x01 else { return }

        let hours = Int(data[6] & 0x1F)
        let frameRateBits = (data[6] >> 5) & 0x03
        let minutes = Int(data[7])
        let seconds = Int(data[8])
        let frames = Int(data[9])

        let frameRate = frameRateFromBits(frameRateBits)

        if let timecode = try? Timecode(
            .components(h: hours, m: minutes, s: seconds, f: frames),
            at: frameRate
        ) {
            handleMMCCommand(.locate(timecode))
        }
    }

    /// Parses a Locate command from Universal SysEx data.
    ///
    /// - Parameter data: The data portion of the Universal SysEx.
    private func parseLocateCommandFromUniversal(_ data: [UInt8]) {
        // Locate format: 06 01 <hr> <mn> <sc> <fr> <sf>
        guard data.count >= 5, data[0] == 0x06, data[1] == 0x01 else { return }

        let hours = Int(data[2] & 0x1F)
        let frameRateBits = (data[2] >> 5) & 0x03
        let minutes = Int(data[3])
        let seconds = Int(data[4])
        let frames = data.count > 5 ? Int(data[5]) : 0

        let frameRate = frameRateFromBits(frameRateBits)

        if let timecode = try? Timecode(
            .components(h: hours, m: minutes, s: seconds, f: frames),
            at: frameRate
        ) {
            handleMMCCommand(.locate(timecode))
        }
    }

    /// Handles an MMC command by updating state and emitting.
    ///
    /// - Parameter command: The MMC command received.
    private func handleMMCCommand(_ command: MMCCommand) {
        lastMMCCommand = command
        noteExternalControl()
        emitState()
        // MMC is an event, not persistent state. Keeping the last command in
        // subsequent MTC snapshots caused Play/Stop/Locate to execute repeatedly.
        lastMMCCommand = nil
        midiLog("MMC COMMAND RECEIVED: \(command.displayName)")
    }

    // MARK: - Utility Methods

    /// Converts frame rate bits from MTC/MMC to TimecodeFrameRate.
    ///
    /// - Parameter bits: The 2-bit frame rate code (0-3).
    /// - Returns: The corresponding `TimecodeFrameRate`.
    private func frameRateFromBits(_ bits: UInt8) -> TimecodeFrameRate {
        switch bits {
        case 0: return .fps24
        case 1: return .fps25
        case 2: return .fps29_97d
        case 3: return .fps30
        default: return .fps24
        }
    }

    // MARK: - State Emission

    /// Registers a continuation for the AsyncStream.
    ///
    /// - Parameter continuation: The continuation to register.
    private func registerContinuation(
        _ continuation: AsyncStream<MIDISyncState>.Continuation,
        id: UUID
    ) {
        stateContinuations[id] = continuation

        // Emit initial state immediately
        emitState()

        // Handle termination
        continuation.onTermination = { [weak self] _ in
            Task { [weak self] in
                await self?.handleContinuationTermination(id: id)
            }
        }
    }

    /// Handles continuation termination.
    private func handleContinuationTermination(id: UUID) {
        stateContinuations.removeValue(forKey: id)
    }

    /// Emits the current state to all subscribers.
    private func emitState() {
        decayIncomingSignalIfStale()

        // Calculate sync duration if currently synced
        let syncDuration: TimeInterval
        if let startTime = syncStartTime, mtcState == .sync {
            syncDuration = Date().timeIntervalSince(startTime)
        } else {
            syncDuration = 0
        }

        // Calculate drift between MTC and local playback
        let driftFrames: Double
        let driftStatus: DriftStatus

        if let mtcTimecode = mtcTimecode, mtcState == .sync {
            // Convert MTC timecode to frame number
            let mtcFrame = mtcTimecode.frameCount.wholeFrames

            // Drift = MTC frame - local playback frame
            // Positive means MTC is ahead, negative means MTC is behind
            driftFrames = Double(mtcFrame) - Double(localPlaybackFrame)

            // Determine drift quality status
            let absDrift = abs(driftFrames)
            if absDrift < 0.5 {
                driftStatus = .excellent
            } else if absDrift < 1.0 {
                driftStatus = .good
            } else if absDrift < 2.0 {
                driftStatus = .fair
            } else {
                driftStatus = .poor
            }
        } else {
            // No sync or no MTC timecode - no drift
            driftFrames = 0.0
            driftStatus = .excellent
        }

        let state = MIDISyncState(
            mtcState: mtcState,
            mtcTimecode: mtcTimecode,
            isReceivingMTC: isReceivingMTC,
            lastMMCCommand: lastMMCCommand,
            selectedInputName: selectedInputName,
            availableInputs: availableInputs,
            localFrameRate: localFrameRate,
            incomingSignal: incomingSignal,
            incomingFrameRate: incomingFrameRate,
            isExternallyControlled: isExternallyControlled,
            lockProgress: lockProgress,
            lockFramesRequired: lockFramesRequired,
            dropoutCounter: dropoutCounter,
            dropoutFramesAllowed: dropoutFramesAllowed,
            syncDuration: syncDuration,
            lastQFTimestamp: lastQFTimestamp,
            driftFrames: driftFrames,
            driftStatus: driftStatus
        )
        for continuation in stateContinuations.values {
            continuation.yield(state)
        }
    }

    // MARK: - Debug Logging

    /// URL for the debug log file.
    private static let debugLogURL: URL = {
        guard let containerURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            // Fallback to temporary directory if Application Support is unavailable
            return FileManager.default.temporaryDirectory.appendingPathComponent("Projector/midi_sync_debug.log")
        }
        let logDir = containerURL.appendingPathComponent("Projector", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        return logDir.appendingPathComponent("midi_sync_debug.log")
    }()

    /// Writes a debug log message to the log file.
    ///
    /// - Parameter message: The message to log.
    private nonisolated func debugPrint(_ message: String) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = dateFormatter.string(from: Date())
        let logLine = "[\(timestamp)] [MIDISyncActor] \(message)\n"

        if let data = logLine.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: Self.debugLogURL.path) {
                if let handle = try? FileHandle(forWritingTo: Self.debugLogURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                }
            } else {
                try? data.write(to: Self.debugLogURL)
            }
        }
    }
}

// MARK: - Incoming Rate Reporting

extension MTCFrameRate {

    /// The frame rate to report for a stream arriving at this MTC base rate.
    ///
    /// ## MTC carries a family, not a rate
    ///
    /// Quarter-frames encode one of four base rates - 24, 25, 29.97 drop and 30
    /// - and every timecode rate is transmitted on the base it belongs to. A
    /// 23.976 session and a 24 session both go out as MTC 24; 29.97 and 30 both
    /// go out as MTC 30. Nothing on the wire tells them apart, because nothing
    /// needs to: within a family the labels are identical and only wall-clock
    /// speed differs, which the sender and receiver each already know.
    ///
    /// So the base rate's `directEquivalentFrameRate` is not "the rate the
    /// sender is running at". It is one member of the family, and naming it as
    /// the incoming rate accused a correctly configured 23.976 session of a
    /// mismatch against itself: the readout went red and read "24 ≠ 23.976",
    /// with a tooltip telling the user to change the project to 24 - which would
    /// have been the actual error, on the most common rate for picture. The same
    /// applied to 29.97 against 30.
    ///
    /// Reporting the project's own rate whenever it belongs to the arriving
    /// family says exactly as much as MTC knows. A real mismatch - 25 against a
    /// 24 family - still resolves to a different rate and still shows.
    ///
    /// - Parameter project: The timeline's frame rate.
    /// - Returns: The project rate when it transmits on this base, otherwise the
    ///   base's direct equivalent.
    func reportedRate(forProject project: TimecodeFrameRate) -> TimecodeFrameRate {
        project.transmitsMTC(using: self) ? project : directEquivalentFrameRate
    }
}

// MARK: - Supporting Types

/// Errors that can occur during MIDI sync operations.
public enum MIDISyncError: Error, Sendable {
    /// MIDI services failed to start.
    case startupFailed(underlyingError: Error)

    /// The requested MIDI input was not found.
    case inputNotFound(name: String)
}

// MARK: - Notification Name Extension

extension Notification.Name {
    /// Notification posted when MIDI device configuration changes.
    static let midiKitIOSetupChanged = Notification.Name("MIDIKitIOSetupChangedNotification")
}
