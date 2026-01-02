import Foundation
import Combine
import MIDIKitIO
import MIDIKitSync
import SwiftTimecodeCore

/// Manages MIDI input for MTC (MIDI Time Code) and MMC (MIDI Machine Control) reception
@MainActor
final class MIDIManager: ObservableObject {
    // MARK: - Published Properties

    /// Current timecode from MTC
    @Published private(set) var currentTimecode: Timecode

    /// MTC receiver state
    @Published private(set) var mtcState: MTCReceiver.State = .idle

    /// Whether MTC is actively being received
    @Published private(set) var isReceivingMTC: Bool = false

    /// Selected MIDI input source name
    @Published var selectedInputName: String? {
        didSet {
            if oldValue != selectedInputName {
                reconnectInput()
            }
        }
    }

    /// Available MIDI input sources
    @Published private(set) var availableInputs: [String] = []

    /// Last MMC command received
    @Published private(set) var lastMMCCommand: MMCCommand?

    // MARK: - Callbacks

    /// Called when MTC timecode updates (for video sync)
    var onTimecodeChanged: ((Timecode) -> Void)?

    /// Called when MMC transport command is received
    var onMMCCommand: ((MMCCommand) -> Void)?

    // MARK: - Private Properties

    private var midiManager: MIDIKitIO.MIDIManager?
    private var mtcReceiver: MTCReceiver?
    private var inputConnectionID: String = "ProjectorMIDIInput"
    private var virtualInputTag: String = "ProjectorVirtualInput"
    private var cancellables = Set<AnyCancellable>()

    /// Name of our virtual MIDI input port
    static let virtualInputName = "Projector MIDI IN"

    // MARK: - MMC Commands

    enum MMCCommand: Equatable {
        case stop
        case play
        case deferredPlay
        case fastForward
        case rewind
        case pause
        case locate(Timecode)

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

    init() {
        self.currentTimecode = Timecode(.components(h: 0, m: 0, s: 0, f: 0), at: .fps24, by: .clamping)
        // Default to our virtual MIDI input port
        self.selectedInputName = Self.virtualInputName
        setupMIDI()
        debugLog("MIDIManager initialized")
    }

    // MARK: - Setup

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

    private func stopMIDI() {
        midiManager = nil
        mtcReceiver = nil
    }

    // MARK: - Input Management

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

    private func handleMTCTimecode(_ timecode: Timecode, displayNeedsUpdate: Bool) {
        if displayNeedsUpdate {
            self.currentTimecode = timecode
            self.onTimecodeChanged?(timecode)
        }
    }

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

    private func handleMMCCommand(_ command: MMCCommand) {
        debugLog("MMC Command received: \(command.displayName)")
        self.lastMMCCommand = command
        self.onMMCCommand?(command)
    }

    // MARK: - Universal SysEx Handling

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

    /// Update the local frame rate for MTC interpretation
    func setLocalFrameRate(_ frameRate: TimecodeFrameRate) {
        mtcReceiver?.setLocalFrameRate(frameRate)
    }

    // MARK: - Debug Logging

    private static let debugLogURL: URL = {
        let containerURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let logDir = containerURL.appendingPathComponent("Projector", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        return logDir.appendingPathComponent("midi_debug.log")
    }()

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
    static let MIDIKitIOSetupChanged = Notification.Name("MIDIKitIOSetupChangedNotification")
}
