import Foundation
import Combine
import MIDIKitIO
import MIDIKitSync
import SwiftTimecodeCore

// MARK: - MIDIManager

/// Manages MIDI input for MTC (MIDI Time Code) and MMC (MIDI Machine Control) reception.
///
/// `MIDIManager` provides a high-level interface for receiving MIDI timecode and machine
/// control messages from external DAWs and MIDI devices. It supports:
/// - **MTC (MIDI Time Code)**: Streaming timecode for frame-accurate sync
/// - **MMC (MIDI Machine Control)**: Transport commands (play, stop, locate, etc.)
/// - **Virtual MIDI Port**: Creates "Projector MIDI IN" for DAWs to connect to
/// - **External MIDI Sources**: Connects to hardware MIDI interfaces
///
/// ## Architecture
///
/// ```
/// ┌─────────────────────────────────────────────────────────────────┐
/// │                    External Sources                              │
/// │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐              │
/// │  │   DAW       │  │   MIDI I/F  │  │   Other     │              │
/// │  │ (Pro Tools) │  │ (USB MIDI)  │  │   Apps      │              │
/// │  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘              │
/// │         │                │                │                      │
/// │         └────────────────┴────────────────┘                      │
/// │                          │                                       │
/// │                          ▼                                       │
/// │  ┌─────────────────────────────────────────────────────────────┐│
/// │  │          MIDIManager (this file)                            ││
/// │  │  ┌─────────────────┐  ┌─────────────────────────────────┐  ││
/// │  │  │ Virtual Input   │  │ MTCReceiver                     │  ││
/// │  │  │ "Projector      │──│ - Quarter-frame decoding        │  ││
/// │  │  │  MIDI IN"       │  │ - Full-frame handling           │  ││
/// │  │  └─────────────────┘  │ - State machine (idle→sync)     │  ││
/// │  │                       └─────────────────────────────────┘  ││
/// │  └─────────────────────────────────────────────────────────────┘│
/// │                          │                                       │
/// │                          ▼                                       │
/// │  ┌─────────────────────────────────────────────────────────────┐│
/// │  │ @Published properties (for SwiftUI)                         ││
/// │  │ + Callbacks (for PlaybackEngine)                            ││
/// │  └─────────────────────────────────────────────────────────────┘│
/// └─────────────────────────────────────────────────────────────────┘
/// ```
///
/// ## Thread Safety
///
/// - `@MainActor` isolated for safe SwiftUI observation
/// - MIDI callbacks are dispatched to main actor via `Task`
/// - Uses Combine for setup change notifications
///
/// ## Usage
///
/// ```swift
/// let midiManager = MIDIManager()
///
/// // Observe timecode changes
/// midiManager.onTimecodeChanged = { timecode in
///     playbackEngine.seekTo(timecode)
/// }
///
/// // Observe MMC commands
/// midiManager.onMMCCommand = { command in
///     switch command {
///     case .play: playbackEngine.play()
///     case .stop: playbackEngine.stop()
///     case .locate(let tc): playbackEngine.seekTo(tc)
///     default: break
///     }
/// }
///
/// // Select a MIDI input
/// midiManager.selectedInputName = "ProTools MIDI OUT"
/// ```
///
/// - Note: This class is being superseded by `MIDISyncActor` which provides
///         a more testable actor-based implementation.
@MainActor
final class MIDIManager: ObservableObject {

    // MARK: - Published Properties

    /// Current timecode received from MTC.
    ///
    /// Updated when MTC quarter-frames complete a full timecode value or
    /// when an MTC Full Frame message is received. Use `onTimecodeChanged`
    /// callback for real-time sync.
    @Published private(set) var currentTimecode: Timecode

    /// Current state of the MTC receiver's state machine.
    ///
    /// Transitions through: `.idle` → `.preSync` → `.sync` → `.freewheeling`
    /// Use this to determine sync quality and connection status.
    @Published private(set) var mtcState: MTCReceiver.State = .idle

    /// Whether MTC messages are actively being received.
    ///
    /// `true` when in `.preSync`, `.sync`, or `.freewheeling` states.
    /// `false` when `.idle` or `.incompatibleFrameRate`.
    @Published private(set) var isReceivingMTC: Bool = false

    /// Display name of the currently selected MIDI input source.
    ///
    /// Set this property to connect to a different MIDI source.
    /// Setting to `nil` disconnects from all sources.
    /// Defaults to `"Projector MIDI IN"` (the virtual port).
    @Published var selectedInputName: String? {
        didSet {
            if oldValue != selectedInputName {
                reconnectInput()
            }
        }
    }

    /// All available MIDI input source names.
    ///
    /// Includes the virtual port ("Projector MIDI IN") at the top,
    /// followed by all detected hardware MIDI outputs (sources).
    /// Updated automatically when MIDI setup changes.
    @Published private(set) var availableInputs: [String] = []

    /// The most recently received MMC command.
    ///
    /// Updated when any MMC transport command is received.
    /// Use `onMMCCommand` callback for real-time handling.
    @Published private(set) var lastMMCCommand: MMCCommand?

    // MARK: - Callbacks

    /// Called when MTC timecode updates.
    ///
    /// Use this callback to sync video playback to incoming MTC.
    /// Called on the main thread.
    var onTimecodeChanged: ((Timecode) -> Void)?

    /// Called when an MMC transport command is received.
    ///
    /// Use this callback to respond to play/stop/locate commands from the DAW.
    /// Called on the main thread.
    var onMMCCommand: ((MMCCommand) -> Void)?

    // MARK: - Private Properties

    /// The underlying MIDIKit manager instance.
    private var midiManager: MIDIKitIO.MIDIManager?

    /// MIDIKit's MTC receiver for quarter-frame and full-frame decoding.
    private var mtcReceiver: MTCReceiver?

    /// Tag identifier for the input connection to external MIDI sources.
    private var inputConnectionID: String = "ProjectorMIDIInput"

    /// Tag identifier for the virtual MIDI input port.
    private var virtualInputTag: String = "ProjectorVirtualInput"

    /// Combine subscriptions for MIDI setup change notifications.
    private var cancellables = Set<AnyCancellable>()

    /// Display name of the virtual MIDI input port created by Projector.
    ///
    /// DAWs can send MTC/MMC to this port to sync with Projector.
    static let virtualInputName = "Projector MIDI IN"

    // MARK: - MMC Commands

    /// MIDI Machine Control commands for transport control.
    ///
    /// These commands are parsed from incoming MMC SysEx messages and can be
    /// used to control video playback in sync with an external DAW.
    ///
    /// ## Standard MMC Commands
    /// | Command | SysEx | Description |
    /// |---------|-------|-------------|
    /// | Stop | 0x01 | Stop playback immediately |
    /// | Play | 0x02 | Start playback from current position |
    /// | Deferred Play | 0x03 | Start at specified position |
    /// | Fast Forward | 0x04 | Fast forward (variable speed) |
    /// | Rewind | 0x05 | Rewind (variable speed) |
    /// | Pause | 0x09 | Pause at current position |
    /// | Locate | 0x44 | Seek to specified timecode |
    enum MMCCommand: Equatable {
        /// Stop playback immediately.
        case stop

        /// Start playback from current position.
        case play

        /// Start playback from a specified position (when ready).
        case deferredPlay

        /// Fast forward at variable speed.
        case fastForward

        /// Rewind at variable speed.
        case rewind

        /// Pause at current position.
        case pause

        /// Seek to a specific timecode position.
        case locate(Timecode)

        /// Human-readable display name for the command.
        var displayName: String {
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

    // MARK: - Initialization

    /// Creates a new MIDI manager and initializes MIDI infrastructure.
    ///
    /// The initializer:
    /// 1. Creates a MIDIKit manager with "Projector" as the client name
    /// 2. Sets up the MTC receiver with default 24fps and sync policy
    /// 3. Creates the "Projector MIDI IN" virtual port
    /// 4. Refreshes the list of available inputs
    /// 5. Subscribes to MIDI setup change notifications
    ///
    /// The manager defaults to receiving from the virtual port.
    init() {
        self.currentTimecode = Timecode(.components(h: 0, m: 0, s: 0, f: 0), at: .fps24, by: .clamping)
        // Default to our virtual MIDI input port
        self.selectedInputName = Self.virtualInputName
        setupMIDI()
        debugLog("MIDIManager initialized")
    }

    // MARK: - Setup

    /// Initializes MIDIKit infrastructure and configures all MIDI components.
    ///
    /// Creates the MIDI manager, MTC receiver, virtual input port, and
    /// subscribes to MIDI setup change notifications.
    private func setupMIDI() {
        do {
            // Create MIDI manager
            let manager = MIDIKitIO.MIDIManager(
                clientName: "Projector",
                model: "Projector",
                manufacturer: "Projector"
            )

            try manager.start()
            self.midiManager = manager

            // Setup MTC receiver
            setupMTCReceiver()

            // Create virtual MIDI input (destination) that DAWs can send to
            setupVirtualInput()

            // Refresh available inputs
            refreshAvailableInputs()

            // Observe MIDI setup changes
            NotificationCenter.default.publisher(for: .MIDIKitIOSetupChanged)
                .sink { [weak self] _ in
                    Task { @MainActor in
                        self?.refreshAvailableInputs()
                    }
                }
                .store(in: &cancellables)

        } catch {
            print("Failed to start MIDI manager: \(error)")
        }
    }

    /// Configures the MTC receiver with callbacks for timecode and state changes.
    ///
    /// The receiver is configured with:
    /// - Initial frame rate: 24fps
    /// - Lock frames: 8 (frames needed to establish sync)
    /// - Drop-out frames: 10 (frames allowed before freewheeling)
    private func setupMTCReceiver() {
        let receiver = MTCReceiver(
            name: "Projector MTC",
            initialLocalFrameRate: .fps24,
            syncPolicy: .init(lockFrames: 8, dropOutFrames: 10)
        ) { [weak self] timecode, messageType, direction, displayNeedsUpdate in
            Task { @MainActor in
                self?.handleMTCTimecode(timecode, displayNeedsUpdate: displayNeedsUpdate)
            }
        } stateChanged: { [weak self] state in
            Task { @MainActor in
                self?.handleMTCStateChange(state)
            }
        }

        self.mtcReceiver = receiver
    }

    /// Creates the virtual MIDI input port that DAWs can send to.
    ///
    /// The port is named "Projector MIDI IN" and uses a persistent unique ID
    /// stored in UserDefaults to maintain consistent routing across app launches.
    private func setupVirtualInput() {
        guard let manager = midiManager else { return }

        do {
            try manager.addInput(
                name: "Projector MIDI IN",
                tag: virtualInputTag,
                uniqueID: .userDefaultsManaged(key: "ProjectorMIDIInputUID"),
                receiver: .events { [weak self] events, timeStamp, source in
                    Task { @MainActor in
                        self?.handleMIDIEvents(events)
                    }
                }
            )
            debugLog("Virtual MIDI input 'Projector MIDI IN' created")
        } catch {
            print("Failed to create virtual MIDI input: \(error)")
        }
    }

    /// Stops and releases all MIDI resources.
    private func stopMIDI() {
        midiManager = nil
        mtcReceiver = nil
    }

    // MARK: - Input Management

    /// Refreshes the list of available MIDI input sources.
    ///
    /// Populates `availableInputs` with:
    /// 1. The virtual "Projector MIDI IN" port (always first)
    /// 2. All detected MIDI output endpoints (which are sources of MIDI data)
    ///
    /// Called automatically on initialization and when MIDI setup changes.
    func refreshAvailableInputs() {
        guard let manager = midiManager else {
            availableInputs = [Self.virtualInputName]
            return
        }

        // Start with our virtual port at the top
        var inputs = [Self.virtualInputName]

        // Add external MIDI outputs (sources) - these are where MIDI data comes FROM
        let externalSources = manager.endpoints.outputs.map { $0.displayName }
        inputs.append(contentsOf: externalSources)

        availableInputs = inputs
    }

    /// Reconnects to the selected MIDI input source.
    ///
    /// This method is called automatically when `selectedInputName` changes.
    /// It handles three cases:
    /// 1. `nil` selection: Disconnects from all sources
    /// 2. Virtual port selected: No action needed (always receiving)
    /// 3. External source selected: Creates/updates input connection
    private func reconnectInput() {
        guard let manager = midiManager else { return }

        // Remove existing connection by recreating without outputs
        if let existingConnection = manager.managedInputConnections[inputConnectionID] {
            existingConnection.removeAllOutputs()
        }

        guard let inputName = selectedInputName else { return }

        // If selecting our virtual port, we don't need to connect to anything
        // The virtual input is always receiving via setupVirtualInput()
        if inputName == Self.virtualInputName {
            debugLog("Using virtual MIDI input: \(inputName)")
            return
        }

        // Find matching endpoint (outputs are sources that send MIDI data)
        guard let endpoint = manager.endpoints.outputs.first(where: { $0.displayName == inputName }) else {
            print("MIDI source not found: \(inputName)")
            return
        }

        do {
            // Check if connection already exists
            if let existingConnection = manager.managedInputConnections[inputConnectionID] {
                // Add the new output to existing connection
                existingConnection.add(outputs: [endpoint])
                debugLog("Added MIDI source: \(inputName)")
            } else {
                // Create new input connection
                try manager.addInputConnection(
                    to: .none,
                    tag: inputConnectionID,
                    receiver: .events { [weak self] events, timeStamp, source in
                        Task { @MainActor in
                            self?.handleMIDIEvents(events)
                        }
                    }
                )
                // Add the output to the new connection
                manager.managedInputConnections[inputConnectionID]?.add(outputs: [endpoint])
                debugLog("Connected to MIDI source: \(inputName)")
            }
        } catch {
            print("Failed to connect to MIDI source: \(error)")
        }
    }

    // MARK: - MIDI Event Handling

    /// Processes incoming MIDI events from any source.
    ///
    /// Routes events appropriately:
    /// 1. All events are fed to the MTC receiver for quarter-frame processing
    /// 2. SysEx7 messages are parsed for MTC Full Frame and MMC commands
    /// 3. UniversalSysEx7 messages are parsed for MTC/MMC in universal format
    ///
    /// - Parameter events: Array of MIDIKit events to process
    private func handleMIDIEvents(_ events: [MIDIEvent]) {
        for event in events {
            // Feed to MTC receiver
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
    /// Only updates the published timecode and calls the callback when
    /// `displayNeedsUpdate` is true (i.e., when a full frame is complete).
    ///
    /// - Parameters:
    ///   - timecode: The new timecode value
    ///   - displayNeedsUpdate: Whether the display should refresh
    private func handleMTCTimecode(_ timecode: Timecode, displayNeedsUpdate: Bool) {
        if displayNeedsUpdate {
            self.currentTimecode = timecode
            self.onTimecodeChanged?(timecode)
        }
    }

    /// Handles MTC receiver state machine transitions.
    ///
    /// Updates `mtcState` and `isReceivingMTC` based on the new state.
    ///
    /// - Parameter state: The new MTC receiver state
    private func handleMTCStateChange(_ state: MTCReceiver.State) {
        self.mtcState = state

        switch state {
        case .idle:
            isReceivingMTC = false
        case .preSync, .sync, .freewheeling:
            isReceivingMTC = true
        case .incompatibleFrameRate:
            isReceivingMTC = false
        @unknown default:
            isReceivingMTC = false
        }
    }

    // MARK: - MMC Parsing

    /// Parses Universal Real-Time SysEx messages for MTC Full Frame and MMC commands.
    ///
    /// SysEx format (after F0/F7 stripped by MIDIKit):
    /// `7F <device-id> <sub-id-1> <sub-id-2> ...`
    ///
    /// Handles:
    /// - MTC Full Frame (sub-id-1 = 0x01, sub-id-2 = 0x01)
    /// - MMC Commands (sub-id-1 = 0x06)
    ///
    /// - Parameter data: Raw SysEx data bytes (without F0/F7 framing)
    private func handleSysEx(_ data: [UInt8]) {
        // Universal Real-Time SysEx format: F0 7F <device-id> <sub-id-1> <sub-id-2> ... F7
        // Note: MIDIKit strips F0/F7, so data starts at 7F

        guard data.count >= 4, data[0] == 0x7F else { return }

        let subId1 = data[2]

        // Handle MTC Full Frame messages (sub-id-1 = 0x01)
        // Format: 7F <dev> 01 01 <hr> <mn> <sc> <fr>
        if subId1 == 0x01 && data.count >= 8 && data[3] == 0x01 {
            handleMTCFullFrame(data)
            return
        }

        // Handle MMC commands (sub-id-1 = 0x06)
        guard subId1 == 0x06 else { return }

        let command = data[3]

        switch command {
        case 0x01: // Stop
            handleMMCCommand(.stop)

        case 0x02: // Play
            handleMMCCommand(.play)

        case 0x03: // Deferred Play
            handleMMCCommand(.deferredPlay)

        case 0x04: // Fast Forward
            handleMMCCommand(.fastForward)

        case 0x05: // Rewind
            handleMMCCommand(.rewind)

        case 0x09: // Pause
            handleMMCCommand(.pause)

        case 0x44: // Locate
            // Locate format: 44 06 01 <hr> <mn> <sc> <fr> <sf>
            if data.count >= 10, data[4] == 0x06, data[5] == 0x01 {
                let hours = Int(data[6] & 0x1F) // Mask off frame rate bits
                let minutes = Int(data[7])
                let seconds = Int(data[8])
                let frames = Int(data[9])

                // Determine frame rate from hours byte
                let frameRateBits = (data[6] >> 5) & 0x03
                let frameRate: TimecodeFrameRate
                switch frameRateBits {
                case 0: frameRate = .fps24
                case 1: frameRate = .fps25
                case 2: frameRate = .fps29_97d
                case 3: frameRate = .fps30
                default: frameRate = .fps24
                }

                if let timecode = try? Timecode(
                    .components(h: hours, m: minutes, s: seconds, f: frames),
                    at: frameRate
                ) {
                    handleMMCCommand(.locate(timecode))
                }
            }

        default:
            break
        }
    }

    /// Dispatches an MMC command to listeners.
    ///
    /// Logs the command, updates `lastMMCCommand`, and calls `onMMCCommand` callback.
    ///
    /// - Parameter command: The parsed MMC command
    private func handleMMCCommand(_ command: MMCCommand) {
        debugLog("MMC Command received: \(command.displayName)")
        self.lastMMCCommand = command
        self.onMMCCommand?(command)
    }

    // MARK: - Universal SysEx Handling

    /// Handles MIDIKit's parsed Universal SysEx messages.
    ///
    /// This is an alternative parsing path for MTC Full Frame and MMC commands
    /// when MIDIKit parses them as `UniversalSysEx7` instead of raw `SysEx7`.
    ///
    /// - Parameter sysEx: The parsed universal SysEx event
    private func handleUniversalSysEx(_ sysEx: MIDIEvent.UniversalSysEx7) {
        // MTC Full Frame: universalType = realTime, subID1 = 0x01, subID2 = 0x01
        // MMC: universalType = realTime, subID1 = 0x06

        guard sysEx.universalType == .realTime else { return }

        if sysEx.subID1.uInt8Value == 0x01 && sysEx.subID2.uInt8Value == 0x01 {
            // MTC Full Frame message
            // Data format: <hr> <mn> <sc> <fr>
            let data = sysEx.data
            guard data.count >= 4 else { return }

            let hrByte = data[0]
            let frameRateBits = (hrByte >> 5) & 0x03
            let hours = Int(hrByte & 0x1F)
            let minutes = Int(data[1])
            let seconds = Int(data[2])
            let frames = Int(data[3])

            let frameRate: TimecodeFrameRate
            switch frameRateBits {
            case 0: frameRate = .fps24
            case 1: frameRate = .fps25
            case 2: frameRate = .fps29_97d
            case 3: frameRate = .fps30
            default: frameRate = .fps24
            }

            if let timecode = try? Timecode(
                .components(h: hours, m: minutes, s: seconds, f: frames),
                at: frameRate
            ) {
                self.currentTimecode = timecode
                self.onTimecodeChanged?(timecode)
            }
        } else if sysEx.subID1.uInt8Value == 0x06 {
            // MMC command
            handleMMCSysEx(command: sysEx.subID2, data: sysEx.data)
        }
    }

    /// Parses MMC commands from Universal SysEx format.
    ///
    /// - Parameters:
    ///   - command: The MMC command byte (subID2)
    ///   - data: Additional command data (for Locate, etc.)
    private func handleMMCSysEx(command: UInt7, data: [UInt8]) {
        switch command.uInt8Value {
        case 0x01: handleMMCCommand(.stop)
        case 0x02: handleMMCCommand(.play)
        case 0x03: handleMMCCommand(.deferredPlay)
        case 0x04: handleMMCCommand(.fastForward)
        case 0x05: handleMMCCommand(.rewind)
        case 0x09: handleMMCCommand(.pause)
        case 0x44: // Locate
            // Locate format: 06 01 <hr> <mn> <sc> <fr> <sf>
            if data.count >= 5, data[0] == 0x06, data[1] == 0x01 {
                let hours = Int(data[2] & 0x1F)
                let frameRateBits = (data[2] >> 5) & 0x03
                let minutes = Int(data[3])
                let seconds = Int(data[4])
                let frames = data.count > 5 ? Int(data[5]) : 0

                let frameRate: TimecodeFrameRate
                switch frameRateBits {
                case 0: frameRate = .fps24
                case 1: frameRate = .fps25
                case 2: frameRate = .fps29_97d
                case 3: frameRate = .fps30
                default: frameRate = .fps24
                }

                if let timecode = try? Timecode(
                    .components(h: hours, m: minutes, s: seconds, f: frames),
                    at: frameRate
                ) {
                    handleMMCCommand(.locate(timecode))
                }
            }
        default: break
        }
    }

    // MARK: - MTC Full Frame (legacy raw SysEx)

    /// Parses MTC Full Frame messages from raw SysEx data.
    ///
    /// MTC Full Frame format (after F0/F7 stripped):
    /// ```
    /// 7F <dev> 01 01 <hr> <mn> <sc> <fr>
    /// [0] [1] [2][3] [4]  [5]  [6]  [7]
    /// ```
    ///
    /// The hours byte encodes both the frame rate (bits 5-6) and hours (bits 0-4).
    ///
    /// - Parameter data: Raw SysEx bytes
    private func handleMTCFullFrame(_ data: [UInt8]) {
        // MTC Full Frame format (after F0/F7 stripped):
        // 7F <dev> 01 01 <hr> <mn> <sc> <fr>
        // [0] [1] [2][3] [4]  [5]  [6]  [7]
        // hr byte: bits 5-6 = frame rate, bits 0-4 = hours

        guard data.count >= 8 else { return }

        let hrByte = data[4]
        let frameRateBits = (hrByte >> 5) & 0x03
        let hours = Int(hrByte & 0x1F)
        let minutes = Int(data[5])
        let seconds = Int(data[6])
        let frames = Int(data[7])

        // Determine frame rate from bits
        let frameRate: TimecodeFrameRate
        switch frameRateBits {
        case 0: frameRate = .fps24
        case 1: frameRate = .fps25
        case 2: frameRate = .fps29_97d
        case 3: frameRate = .fps30
        default: frameRate = .fps24
        }

        if let timecode = try? Timecode(
            .components(h: hours, m: minutes, s: seconds, f: frames),
            at: frameRate
        ) {
            self.currentTimecode = timecode
            self.onTimecodeChanged?(timecode)
        }
    }

    // MARK: - Frame Rate

    /// Updates the local frame rate for MTC interpretation.
    ///
    /// Call this when the project frame rate changes. If the incoming MTC
    /// frame rate doesn't match, the receiver will report `.incompatibleFrameRate`.
    ///
    /// - Parameter frameRate: The expected frame rate for incoming MTC
    func setLocalFrameRate(_ frameRate: TimecodeFrameRate) {
        mtcReceiver?.setLocalFrameRate(frameRate)
    }

    // MARK: - Debug Logging

    /// URL for the MIDI debug log file.
    ///
    /// Located at `~/Library/Application Support/Projector/midi_debug.log`.
    private static let debugLogURL: URL = {
        let containerURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let logDir = containerURL.appendingPathComponent("Projector", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        return logDir.appendingPathComponent("midi_debug.log")
    }()

    /// Writes a timestamped message to the MIDI debug log.
    ///
    /// - Parameter message: The message to log
    private func debugLog(_ message: String) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = dateFormatter.string(from: Date())
        let logLine = "[\(timestamp)] \(message)\n"

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

// MARK: - Notification Extension

extension Notification.Name {
    /// Posted when MIDI devices are connected or disconnected.
    ///
    /// `MIDIManager` observes this notification to refresh `availableInputs`.
    static let MIDIKitIOSetupChanged = Notification.Name("MIDIKitIOSetupChangedNotification")
}
