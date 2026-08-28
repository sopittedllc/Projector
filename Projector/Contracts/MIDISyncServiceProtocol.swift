import Foundation
import MIDIKitIO
import SwiftTimecodeCore

// MARK: - THE CONTRACT: MIDISyncServiceProtocol
// Layer: Contracts
// Implemented in: Managers
// Consumed in: Views

/// Contract for MIDI sync services (MTC reception, MMC command handling).
///
/// This protocol enables the UI layer to observe MIDI sync state without
/// blocking the main thread. All MIDI processing happens on a dedicated
/// actor, with state changes delivered via `AsyncStream`.
///
/// ## Thread Safety
/// - All types are `Sendable` for safe cross-actor communication
/// - `AsyncStream` ensures delivery to any actor context
/// - Commands are `async` and execute on the implementing actor
///
/// ## Usage
/// ```swift
/// @MainActor
/// class MIDISyncViewModel: ObservableObject {
///     private let service: MIDISyncServiceProtocol
///
///     init(service: MIDISyncServiceProtocol) {
///         self.service = service
///         Task {
///             for await state in service.syncStateStream {
///                 self.updateUI(with: state)
///             }
///         }
///     }
/// }
/// ```
public protocol MIDISyncServiceProtocol: Sendable {

    // MARK: - State Stream (Logic → UI)

    /// Stream of MIDI sync state updates.
    ///
    /// Emits when:
    /// - MTC sync state changes (idle → preSync → sync)
    /// - New MTC timecode is received
    /// - MMC command is received
    /// - MIDI input selection changes
    /// - Available MIDI inputs change
    ///
    /// - Note: High-frequency during MTC sync (up to 120 updates/sec at 30fps)
    var syncStateStream: AsyncStream<MIDISyncState> { get }

    /// Installs the timing-critical chase callback.
    ///
    /// Unlike ``syncStateStream``, this callback is invoked directly from the
    /// receiver callback and does not pass through UI observation state. It is
    /// reserved for predicted transport locks whose host-time deadline would be
    /// lost across the normal actor/stream/view-model delivery path.
    ///
    /// - Parameter handler: Main-actor callback receiving predicted locks.
    func setChaseLockHandler(
        _ handler: (@MainActor @Sendable (MTCChaseLock) -> Void)?
    ) async

    // MARK: - Commands (UI → Logic)

    /// Selects a MIDI input port by name.
    ///
    /// - Parameter name: The display name of the MIDI input, or `nil` to disconnect
    /// - Note: Automatically reconnects MTC/MMC receivers to the new input
    func selectInput(_ name: String?) async

    /// Refreshes the list of available MIDI inputs.
    ///
    /// Call this to update `availableInputs` in `MIDISyncState` after
    /// the user connects or disconnects MIDI hardware.
    func refreshAvailableInputs() async

    /// Sets the local MTC frame rate for sync comparison.
    ///
    /// - Parameter frameRate: The expected frame rate of incoming MTC
    /// - Note: Required for accurate sync when external device doesn't match project rate
    func setLocalFrameRate(_ frameRate: TimecodeFrameRate) async

    /// Updates the local playback frame position for drift calculation.
    ///
    /// Call this from the transport layer whenever playback position changes.
    /// Used to calculate drift between MTC and local playback.
    ///
    /// - Parameter frame: The current playback frame position
    /// - Note: Drift updates are throttled to 1Hz to prevent UI jitter
    func updateLocalPlaybackFrame(_ frame: Int) async
}

// MARK: - Supporting Types

/// Drift quality status for MTC sync.
public enum DriftStatus: Sendable, Equatable {
    /// Excellent sync quality (<0.5 frames drift).
    case excellent

    /// Good sync quality (0.5-1.0 frames drift).
    case good

    /// Fair sync quality (1.0-2.0 frames drift).
    case fair

    /// Poor sync quality (>2.0 frames drift).
    case poor

    /// Color for UI display.
    public var displayColor: String {
        switch self {
        case .excellent, .good: return "green"
        case .fair: return "yellow"
        case .poor: return "red"
        }
    }
}

/// Complete MIDI sync state for UI display.
///
/// This struct captures all MIDI-related state that the UI needs to display
/// sync status, timecode, and input configuration.
///
/// ## Thread Safety
/// All properties are value types or `Sendable`, making this safe to pass
/// between actors.
/// What kind of MIDI traffic is currently arriving on the selected input.
///
/// Exists so the UI can tell "nothing is connected" apart from "something is
/// sending, but not timecode" - previously identical from the user's side, and
/// the reason a DAW configured to send MIDI Clock instead of MTC looked exactly
/// like a dead cable.
public enum IncomingMIDISignal: String, Sendable, Equatable {
    /// No MIDI received recently.
    case none
    /// MTC quarter-frames arriving - this is what drives sync.
    case timecode
    /// MIDI Beat Clock arriving. Carries tempo, not timecode: it cannot
    /// position the playhead, so sync will never lock on it.
    case beatClock
    /// Other MIDI traffic (notes, SysEx, MMC) but no timecode.
    case other

    /// Short label for the transport readout.
    public var shortLabel: String {
        switch self {
        case .none: return "No MIDI"
        case .timecode: return "MTC"
        case .beatClock: return "Clock"
        case .other: return "MIDI"
        }
    }
}

/// A lock the receiver has predicted: where the transport will be, and when.
///
/// MIDIKit's `preSync` state carries both, and they are what a chase is
/// actually made of. `AVPlayer.setRate(_:time:atHostTime:)` takes exactly this
/// pair - "be at this item time when the host clock reads this" - so the
/// receiver's prediction and AVFoundation's scheduling API meet without either
/// side having to guess.
///
/// Starting playback when `.sync` arrives instead cannot be on time: `.sync`
/// means the lock instant has already passed. No sync policy makes that early
/// enough, which is why shortening `lockFrames` reduced the late start without
/// removing it.
public struct MTCChaseLock: Sendable, Equatable {

    /// When the transport reaches ``timecode``, in `mach_absolute_time` units.
    ///
    /// Taken from `DispatchTime.rawValue`, which is documented in MIDIKit's own
    /// receiver as "same as `DispatchTime(rawValue: mach_absolute_time())`", and
    /// consumed by `CMClockMakeHostTimeFromSystemUnits`, documented as
    /// converting "from the units of mach_absolute_time". The two agree, so no
    /// conversion beyond that call is needed.
    public let hostTime: UInt64

    /// The timecode the transport will be at, at ``hostTime``.
    public let timecode: Timecode

    public init(hostTime: UInt64, timecode: Timecode) {
        self.hostTime = hostTime
        self.timecode = timecode
    }
}

public struct MIDISyncState: Sendable, Equatable {

    /// A lock the receiver has predicted, or `nil` when none is pending.
    ///
    /// Published on entering `preSync`, which is the only warning a chase gets
    /// that playback should already be starting.
    public let pendingLock: MTCChaseLock?


    /// Current MTC receiver state (idle, locking, synced, etc.)
    public let mtcState: MTCSyncState

    /// Current MTC timecode received, if any.
    public let mtcTimecode: Timecode?

    /// Whether MTC quarter-frames are actively being received.
    public let isReceivingMTC: Bool

    /// The last MMC command received, if any.
    public let lastMMCCommand: MMCCommand?

    /// Name of the currently selected MIDI input, or `nil` if none.
    public let selectedInputName: String?

    /// Names of all available MIDI input ports.
    public let availableInputs: [String]

    /// The local frame rate used for sync comparison.
    public let localFrameRate: TimecodeFrameRate

    /// What kind of MIDI is currently arriving.
    public let incomingSignal: IncomingMIDISignal

    /// Frame rate reported by the incoming MTC stream, if any.
    ///
    /// MTC encodes its own rate, which may differ from the project's - a
    /// mismatch is the usual cause of sync refusing to lock.
    public let incomingFrameRate: TimecodeFrameRate?

    /// Whether an external device is currently driving the transport.
    ///
    /// True while MTC is arriving or an MMC transport command was received
    /// recently. Distinct from `incomingSignal`, which reports what kind of MIDI
    /// is present: stray notes or SysEx are traffic, not control. Used to put
    /// the app in slave mode, where local transport input is ignored so it
    /// cannot fight the DAW.
    public let isExternallyControlled: Bool

    // MARK: - Sync Quality Metrics

    /// Progress toward sync lock (0...lockFramesRequired).
    ///
    /// During preSync, this value increases as quarter-frames are received.
    /// Once it reaches `lockFramesRequired`, sync state transitions to `.sync`.
    public let lockProgress: Int

    /// Number of frames required to establish lock.
    ///
    /// This is the sync policy's `lockFrames` value (typically 8).
    public let lockFramesRequired: Int

    /// Frames since last MTC message (0...dropoutFramesAllowed).
    ///
    /// When this reaches `dropoutFramesAllowed`, sync state transitions to `.freewheeling`.
    public let dropoutCounter: Int

    /// Number of frames allowed before entering freewheeling.
    ///
    /// This is the sync policy's `dropOutFrames` value (typically 10).
    public let dropoutFramesAllowed: Int

    /// How long sync has been maintained, if currently synced.
    public let syncDuration: TimeInterval

    /// Timestamp of the last quarter-frame received.
    public let lastQFTimestamp: Date?

    /// Drift between MTC and local playback (in frames).
    ///
    /// Positive value means MTC is ahead, negative means MTC is behind.
    /// Calculated as: MTC frame - local playback frame
    public let driftFrames: Double

    /// Drift quality status for UI display.
    public let driftStatus: DriftStatus

    /// Creates a new MIDI sync state.
    public init(
        pendingLock: MTCChaseLock? = nil,
        mtcState: MTCSyncState,
        mtcTimecode: Timecode?,
        isReceivingMTC: Bool,
        lastMMCCommand: MMCCommand?,
        selectedInputName: String?,
        availableInputs: [String],
        localFrameRate: TimecodeFrameRate,
        incomingSignal: IncomingMIDISignal = .none,
        incomingFrameRate: TimecodeFrameRate? = nil,
        isExternallyControlled: Bool = false,
        lockProgress: Int = 0,
        lockFramesRequired: Int = 8,
        dropoutCounter: Int = 0,
        dropoutFramesAllowed: Int = 10,
        syncDuration: TimeInterval = 0,
        lastQFTimestamp: Date? = nil,
        driftFrames: Double = 0.0,
        driftStatus: DriftStatus = .excellent
    ) {
        self.pendingLock = pendingLock
        self.mtcState = mtcState
        self.mtcTimecode = mtcTimecode
        self.isReceivingMTC = isReceivingMTC
        self.lastMMCCommand = lastMMCCommand
        self.selectedInputName = selectedInputName
        self.availableInputs = availableInputs
        self.localFrameRate = localFrameRate
        self.incomingSignal = incomingSignal
        self.incomingFrameRate = incomingFrameRate
        self.isExternallyControlled = isExternallyControlled
        self.lockProgress = lockProgress
        self.lockFramesRequired = lockFramesRequired
        self.dropoutCounter = dropoutCounter
        self.dropoutFramesAllowed = dropoutFramesAllowed
        self.syncDuration = syncDuration
        self.lastQFTimestamp = lastQFTimestamp
        self.driftFrames = driftFrames
        self.driftStatus = driftStatus
    }

    /// Empty state for initialization.
    public static let empty = MIDISyncState(
        mtcState: .idle,
        mtcTimecode: nil,
        isReceivingMTC: false,
        lastMMCCommand: nil,
        selectedInputName: nil,
        availableInputs: [],
        localFrameRate: .fps30,
        lockProgress: 0,
        lockFramesRequired: 8,
        dropoutCounter: 0,
        dropoutFramesAllowed: 10,
        syncDuration: 0,
        lastQFTimestamp: nil,
        driftFrames: 0.0,
        driftStatus: .excellent
    )
}

/// MTC receiver sync state.
///
/// Mirrors `MTCReceiver.State` from MIDIKit without exposing the library type
/// directly to the UI layer.
public enum MTCSyncState: Sendable, Equatable, Hashable {

    /// No MTC is being received.
    case idle

    /// MTC is being received but not yet locked (building timecode).
    case preSync

    /// MTC is locked and timecode is valid.
    case sync

    /// MTC reception dropped briefly; using last known velocity.
    case freewheeling

    /// Incoming MTC frame rate doesn't match local frame rate.
    case incompatibleFrameRate

    /// Human-readable description for UI display.
    public var displayName: String {
        switch self {
        case .idle: return "No MTC"
        case .preSync: return "Locking..."
        case .sync: return "Synced"
        case .freewheeling: return "Freewheeling"
        case .incompatibleFrameRate: return "Frame Rate Mismatch"
        }
    }

    /// Whether any MTC is being received (includes preSync and freewheeling).
    public var isReceiving: Bool {
        switch self {
        case .idle, .incompatibleFrameRate: return false
        case .preSync, .sync, .freewheeling: return true
        }
    }
}

/// MMC transport commands received from external devices.
///
/// Mirrors MMC command types from MIDIKit without exposing library internals.
public enum MMCCommand: Sendable, Equatable, Hashable {
    case stop
    case play
    case deferredPlay
    case fastForward
    case rewind
    case pause
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
