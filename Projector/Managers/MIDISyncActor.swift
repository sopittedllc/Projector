import Foundation
import MIDIKitIO
import MIDIKitSync
import SwiftTimecodeCore

// MARK: - MIDISyncActor

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
/// await midiSync.selectInput("Projector MIDI IN")
/// ```
///
/// ## Performance Considerations
///
/// - MTC can generate up to 120 updates per second at 30fps (quarter-frame messages)
/// - The actor coalesces state updates to avoid overwhelming subscribers
/// - Display updates are throttled by the `displayNeedsUpdate` flag from MTCReceiver
public actor MIDISyncActor: MIDISyncServiceProtocol {

    // MARK: - Constants

    /// Name of the virtual MIDI input port that DAWs can send to.
    public static let virtualInputName = "Projector MIDI IN"

    /// Tag for the virtual MIDI input in MIDIKit.
    private static let virtualInputTag = "ProjectorVirtualInput"

    /// Tag for external MIDI input connections.
    private static let inputConnectionTag = "ProjectorMIDIInput"

    // MARK: - Actor State

    /// The MIDIKit manager instance.
    private var midiManager: MIDIKitIO.MIDIManager?

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

    /// Name of the currently selected MIDI input.
    private var selectedInputName: String?

    /// Names of all available MIDI input ports.
    private var availableInputs: [String] = []

    /// Local frame rate for MTC sync comparison.
    private var localFrameRate: TimecodeFrameRate = .fps30

    // MARK: - Sync Quality Metrics

    /// Number of frames required to establish lock.
    private let lockFramesRequired: Int = 8

    /// Number of frames allowed before entering freewheeling.
    private let dropoutFramesAllowed: Int = 10

    /// Progress toward sync lock (0...lockFramesRequired).
    private var lockProgress: Int = 0

    /// Frames since last MTC message.
    private var dropoutCounter: Int = 0

    /// When sync was established.
    private var syncStartTime: Date?

    /// Timestamp of the last quarter-frame received.
    private var lastQFTimestamp: Date?

    // MARK: - AsyncStream Infrastructure

    /// Continuation for emitting state updates.
    private var stateContinuation: AsyncStream<MIDISyncState>.Continuation?

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
        AsyncStream { continuation in
            Task {
                await self.registerContinuation(continuation)
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
        self.selectedInputName = Self.virtualInputName
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
            let manager = MIDIKitIO.MIDIManager(
                clientName: "Projector",
                model: "Projector",
                manufacturer: "Projector"
            )

            try manager.start()
            self.midiManager = manager

            setupMTCReceiver()
            setupVirtualInput()
            await refreshAvailableInputs()
            reconnectInput()

            setupNotificationObservers()

            debugLog("MIDISyncActor started successfully")
        } catch {
            debugLog("Failed to start MIDI services: \(error)")
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
        stateContinuation?.finish()
        stateContinuation = nil
        mtcReceiver = nil
        midiManager = nil
        debugLog("MIDISyncActor stopped")
    }

    // MARK: - MIDISyncServiceProtocol Commands

    /// Selects a MIDI input port by name.
    ///
    /// This method disconnects from the current input (if any) and connects to
    /// the specified input. If `nil` is passed, all inputs are disconnected.
    ///
    /// - Parameter name: The display name of the MIDI input, or `nil` to disconnect.
    ///
    /// - Note: The virtual input "Projector MIDI IN" is always available and allows
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
    /// await midiSync.selectInput(MIDISyncActor.virtualInputName)
    ///
    /// // Disconnect all inputs
    /// await midiSync.selectInput(nil)
    /// ```
    public func selectInput(_ name: String?) async {
        guard selectedInputName != name else { return }
        selectedInputName = name
        reconnectInput()
        emitState()
        debugLog("Selected MIDI input: \(name ?? "none")")
    }

    /// Refreshes the list of available MIDI inputs.
    ///
    /// Call this method to update the `availableInputs` in `MIDISyncState` after
    /// the user connects or disconnects MIDI hardware.
    ///
    /// - Note: The virtual input is always included as the first option.
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
            availableInputs = [Self.virtualInputName]
            emitState()
            return
        }

        // Start with our virtual port at the top
        var inputs = [Self.virtualInputName]

        // Add external MIDI outputs (sources) - these are where MIDI data comes FROM
        let externalSources = manager.endpoints.outputs.map { $0.displayName }
        inputs.append(contentsOf: externalSources)

        availableInputs = inputs
        emitState()
        debugLog("Refreshed available inputs: \(inputs.count) found")
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
        debugLog("Set local frame rate: \(frameRate)")
    }

    // MARK: - MTC Receiver Setup

    /// Sets up the MTC receiver with callbacks wrapped in Task for actor isolation.
    private func setupMTCReceiver() {
        // Capture self weakly for the closure
        // The closure runs on arbitrary threads from MIDIKit
        let receiver = MTCReceiver(
            name: "Projector MTC",
            initialLocalFrameRate: localFrameRate,
            syncPolicy: .init(lockFrames: 8, dropOutFrames: 10)
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
        debugLog("MTC receiver configured")
    }

    /// Sets up the virtual MIDI input port that DAWs can send to.
    private func setupVirtualInput() {
        guard let manager = midiManager else { return }

        do {
            try manager.addInput(
                name: Self.virtualInputName,
                tag: Self.virtualInputTag,
                uniqueID: .userDefaultsManaged(key: "ProjectorMIDIInputUID"),
                receiver: .events { [weak self] events, _, _ in
                    // CRITICAL: Wrap in Task to hop to actor context
                    Task { [weak self] in
                        await self?.handleMIDIEvents(events)
                    }
                }
            )
            debugLog("Virtual MIDI input '\(Self.virtualInputName)' created")
        } catch {
            debugLog("Failed to create virtual MIDI input: \(error)")
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

        // If selecting our virtual port, we don't need to connect to anything external
        // The virtual input is always receiving via setupVirtualInput()
        if inputName == Self.virtualInputName {
            debugLog("Using virtual MIDI input: \(inputName)")
            return
        }

        // Find matching endpoint (outputs are sources that send MIDI data)
        guard let endpoint = manager.endpoints.outputs.first(where: { $0.displayName == inputName }) else {
            debugLog("MIDI source not found: \(inputName)")
            return
        }

        do {
            if let existingConnection = manager.managedInputConnections[Self.inputConnectionTag] {
                existingConnection.add(outputs: [endpoint])
                debugLog("Added MIDI source: \(inputName)")
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
                debugLog("Connected to MIDI source: \(inputName)")
            }
        } catch {
            debugLog("Failed to connect to MIDI source: \(error)")
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

            // Check for SysEx messages (MTC Full Frame, MMC commands)
            switch event {
            case .sysEx7(let sysEx):
                handleSysEx(sysEx.data)
            case .universalSysEx7(let universalSysEx):
                handleUniversalSysEx(universalSysEx)
            default:
                break
            }
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

        if displayNeedsUpdate {
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
        debugLog("MTC state changed: \(mtcState.displayName)")
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

    /// Handles raw SysEx data for MTC Full Frame and MMC commands.
    ///
    /// - Parameter data: The SysEx data (F0/F7 already stripped by MIDIKit).
    private func handleSysEx(_ data: [UInt8]) {
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

    /// Handles Universal SysEx messages for MTC and MMC.
    ///
    /// - Parameter sysEx: The parsed Universal SysEx event.
    private func handleUniversalSysEx(_ sysEx: MIDIEvent.UniversalSysEx7) {
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
            emitState()
        }
    }

    /// Parses MTC Full Frame from Universal SysEx data.
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
            emitState()
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
        emitState()
        debugLog("MMC command received: \(command.displayName)")
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
    private func registerContinuation(_ continuation: AsyncStream<MIDISyncState>.Continuation) {
        // Finish any existing continuation
        stateContinuation?.finish()
        stateContinuation = continuation

        // Emit initial state immediately
        emitState()

        // Handle termination
        continuation.onTermination = { [weak self] _ in
            Task { [weak self] in
                await self?.handleContinuationTermination()
            }
        }
    }

    /// Handles continuation termination.
    private func handleContinuationTermination() {
        // Clean up if needed
        stateContinuation = nil
    }

    /// Emits the current state to all subscribers.
    private func emitState() {
        // Calculate sync duration if currently synced
        let syncDuration: TimeInterval
        if let startTime = syncStartTime, mtcState == .sync {
            syncDuration = Date().timeIntervalSince(startTime)
        } else {
            syncDuration = 0
        }

        let state = MIDISyncState(
            mtcState: mtcState,
            mtcTimecode: mtcTimecode,
            isReceivingMTC: isReceivingMTC,
            lastMMCCommand: lastMMCCommand,
            selectedInputName: selectedInputName,
            availableInputs: availableInputs,
            localFrameRate: localFrameRate,
            lockProgress: lockProgress,
            lockFramesRequired: lockFramesRequired,
            dropoutCounter: dropoutCounter,
            dropoutFramesAllowed: dropoutFramesAllowed,
            syncDuration: syncDuration,
            lastQFTimestamp: lastQFTimestamp
        )
        stateContinuation?.yield(state)
    }

    // MARK: - Debug Logging

    /// URL for the debug log file.
    private static let debugLogURL: URL = {
        let containerURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let logDir = containerURL.appendingPathComponent("Projector", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        return logDir.appendingPathComponent("midi_sync_debug.log")
    }()

    /// Writes a debug log message to the log file.
    ///
    /// - Parameter message: The message to log.
    private nonisolated func debugLog(_ message: String) {
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
