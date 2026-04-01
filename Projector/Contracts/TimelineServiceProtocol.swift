import Foundation
import SwiftTimecodeCore

// MARK: - Timeline State

/// State emitted by TimelineServiceProtocol
///
/// Represents the current state of the timeline, including all video reels,
/// audio lanes, and configuration. Emitted via AsyncStream whenever the timeline changes.
///
/// ## Thread Safety
/// This type is `Sendable` and can be safely passed between actors and the main thread.
public struct TimelineState: Sendable {
    /// All video reels currently on the timeline
    public let videoReels: [VideoReel]

    /// All audio lanes and their clips
    public let audioLanes: [AudioLane]

    /// Total duration of the timeline in frames
    public let durationFrames: Int

    /// Frame rate of the timeline
    public let frameRate: TimecodeFrameRate

    /// Whether the timeline has unsaved changes
    public let isDirty: Bool

    /// Configuration for the timeline (start timecode, etc.)
    public let config: TimelineConfig

    /// Creates a new timeline state
    ///
    /// - Parameters:
    ///   - videoReels: Array of video reels
    ///   - audioLanes: Array of audio lanes
    ///   - durationFrames: Total timeline duration in frames
    ///   - frameRate: Timeline frame rate
    ///   - isDirty: Whether timeline has unsaved changes
    ///   - config: Timeline configuration
    public init(
        videoReels: [VideoReel],
        audioLanes: [AudioLane],
        durationFrames: Int,
        frameRate: TimecodeFrameRate,
        isDirty: Bool,
        config: TimelineConfig
    ) {
        self.videoReels = videoReels
        self.audioLanes = audioLanes
        self.durationFrames = durationFrames
        self.frameRate = frameRate
        self.isDirty = isDirty
        self.config = config
    }
}

// MARK: - Timeline Errors

/// Errors that can occur during timeline operations
public enum TimelineError: Error, Sendable, LocalizedError {
    // MARK: File Access Errors

    /// Cannot access the file (permission denied)
    case fileAccessDenied

    /// The file does not contain an audio track
    case noAudioTrack

    /// The specified audio track index does not exist
    case invalidTrackIndex

    // MARK: Timeline Operation Errors

    /// Attempted to add a reel that overlaps with an existing reel
    case reelOverlap(frame: Int, existingReelId: UUID)

    /// Attempted to add a clip that overlaps with an existing clip
    case clipOverlap(frame: Int, laneId: UUID, existingClipId: UUID)

    /// Specified lane does not exist
    case laneNotFound(laneId: UUID)

    /// Specified reel does not exist
    case reelNotFound(reelId: UUID)

    /// Specified clip does not exist
    case clipNotFound(clipId: UUID)

    /// Invalid frame position (negative or beyond timeline bounds)
    case invalidFramePosition(frame: Int)

    /// Cannot perform operation on empty timeline
    case emptyTimeline

    // MARK: - LocalizedError Implementation

    public var errorDescription: String? {
        switch self {
        case .fileAccessDenied:
            return "Cannot access the file. Permission denied."
        case .noAudioTrack:
            return "The file does not contain an audio track."
        case .invalidTrackIndex:
            return "The specified audio track index does not exist."
        case .reelOverlap(let frame, _):
            return "Cannot add reel at frame \(frame): overlaps with existing reel."
        case .clipOverlap(let frame, _, _):
            return "Cannot add clip at frame \(frame): overlaps with existing clip."
        case .laneNotFound:
            return "The specified audio lane does not exist."
        case .reelNotFound:
            return "The specified video reel does not exist."
        case .clipNotFound:
            return "The specified audio clip does not exist."
        case .invalidFramePosition(let frame):
            return "Invalid frame position: \(frame)."
        case .emptyTimeline:
            return "Cannot perform operation on empty timeline."
        }
    }
}

// MARK: - Timeline Service Protocol

/// Contract for timeline operations (two-layer architecture)
///
/// This protocol abstracts timeline state management from the presentation layer.
/// Implemented by TimelineActor in the logic layer.
///
/// ## Architecture
/// ```
/// Presentation Layer (SwiftUI Views)
///     ↓ consumes
/// THE CONTRACT (TimelineServiceProtocol)
///     ↓ implemented by
/// Logic Layer (TimelineActor)
/// ```
///
/// ## Usage Example
/// ```swift
/// @MainActor
/// class TimelineViewModel: ObservableObject {
///     private let service: TimelineServiceProtocol
///     @Published private(set) var videoReels: [VideoReel] = []
///
///     init(service: TimelineServiceProtocol) {
///         self.service = service
///         observeTimeline()
///     }
///
///     private func observeTimeline() {
///         Task {
///             for await state in service.timelineStateStream {
///                 self.videoReels = state.videoReels
///             }
///         }
///     }
///
///     func addVideoReel(_ reel: VideoReel, at frame: Int) {
///         Task {
///             try await service.addVideoReel(reel, at: frame)
///         }
///     }
/// }
/// ```
///
/// ## Thread Safety
/// All methods are `async` and can be called from any context. State updates
/// are emitted via `timelineStateStream` which can be consumed on any actor.
public protocol TimelineServiceProtocol: Sendable {
    // MARK: - State Stream

    /// Stream of timeline state updates
    ///
    /// Emits the current state whenever the timeline changes. Subscribers receive
    /// an initial state emission immediately upon subscription, followed by updates
    /// whenever add/remove/reorder operations occur.
    ///
    /// - Note: Thread-safe. Can be consumed from any actor including @MainActor
    var timelineStateStream: AsyncStream<TimelineState> { get }

    // MARK: - Video Reel Operations

    /// Add a video reel at the specified frame position
    ///
    /// The reel must not overlap with any existing reel on the timeline.
    /// Reels are automatically ordered by their start frame position.
    ///
    /// - Parameters:
    ///   - reel: The video reel to add
    ///   - frame: Frame position to insert at (0-based, timeline coordinates)
    /// - Throws:
    ///   - `TimelineError.reelOverlap` if reel overlaps with existing reel
    ///   - `TimelineError.invalidFramePosition` if frame is negative
    /// - Note: Thread-safe, can be called from any actor
    func addVideoReel(_ reel: VideoReel, at frame: Int) async throws

    /// Remove a video reel by ID
    ///
    /// If the reel does not exist, this operation is a no-op.
    ///
    /// - Parameter id: UUID of the reel to remove
    /// - Note: Thread-safe, can be called from any actor
    func removeVideoReel(id: UUID) async

    /// Reorder video reels (for drag-drop operations)
    ///
    /// Moves a reel from one position to another in the timeline order.
    /// This does NOT change the reel's start frame, only its z-order/layering.
    ///
    /// - Parameters:
    ///   - fromIndex: Current index in the reels array
    ///   - toIndex: Target index in the reels array
    /// - Throws: `TimelineError.invalidFramePosition` if indices are out of bounds
    /// - Note: Thread-safe, can be called from any actor
    func reorderVideoReels(fromIndex: Int, toIndex: Int) async throws

    /// Update a video reel's properties
    ///
    /// Allows modifying reel properties like start frame, duration, or source.
    /// Validates that the updated reel doesn't overlap with other reels.
    ///
    /// - Parameters:
    ///   - id: UUID of the reel to update
    ///   - reel: New reel data
    /// - Throws:
    ///   - `TimelineError.reelNotFound` if reel doesn't exist
    ///   - `TimelineError.reelOverlap` if updated reel overlaps
    /// - Note: Thread-safe, can be called from any actor
    func updateVideoReel(id: UUID, reel: VideoReel) async throws

    // MARK: - Audio Lane Operations

    /// Add an audio clip to a lane
    ///
    /// The clip must not overlap with any existing clip on the same lane.
    ///
    /// - Parameters:
    ///   - clip: The audio clip to add
    ///   - laneId: Target lane UUID
    /// - Throws:
    ///   - `TimelineError.clipOverlap` if clip overlaps with existing clip
    ///   - `TimelineError.laneNotFound` if lane doesn't exist
    ///   - `TimelineError.invalidFramePosition` if clip start frame is negative
    /// - Note: Thread-safe, can be called from any actor
    func addAudioClip(_ clip: AudioClip, toLane laneId: UUID) async throws

    /// Remove an audio clip by ID
    ///
    /// If the clip does not exist, this operation is a no-op.
    ///
    /// - Parameter id: UUID of the clip to remove
    /// - Note: Thread-safe, can be called from any actor
    func removeAudioClip(id: UUID) async

    /// Create a new audio lane
    ///
    /// Lanes are added at the end of the lane list.
    ///
    /// - Parameter name: Display name for the lane
    /// - Returns: The newly created lane with generated UUID
    /// - Note: Thread-safe, can be called from any actor
    func createAudioLane(name: String) async -> AudioLane

    /// Remove an audio lane by ID
    ///
    /// All clips on the lane are also removed.
    ///
    /// - Parameter id: UUID of the lane to remove
    /// - Throws: `TimelineError.laneNotFound` if lane doesn't exist
    /// - Note: Thread-safe, can be called from any actor
    func removeAudioLane(id: UUID) async throws

    /// Update audio lane properties (name, mute, solo, volume)
    ///
    /// - Parameters:
    ///   - id: UUID of the lane to update
    ///   - lane: New lane data
    /// - Throws: `TimelineError.laneNotFound` if lane doesn't exist
    /// - Note: Thread-safe, can be called from any actor
    func updateAudioLane(id: UUID, lane: AudioLane) async throws

    // MARK: - Timeline Configuration

    /// Update timeline configuration (frame rate, start timecode, duration)
    ///
    /// Changing the frame rate may cause reels/clips to shift position if their
    /// timecode-based positions are recalculated.
    ///
    /// - Parameter config: New timeline configuration
    /// - Note: Thread-safe, can be called from any actor
    func updateConfiguration(_ config: TimelineConfig) async

    // MARK: - Queries

    /// Get the current timeline state synchronously
    ///
    /// This is a snapshot of the current state. For continuous updates,
    /// subscribe to `timelineStateStream` instead.
    ///
    /// - Returns: Current timeline state
    /// - Note: Thread-safe, can be called from any actor
    func getCurrentState() async -> TimelineState

    /// Check if a reel overlaps with existing reels
    ///
    /// Useful for validation before adding/updating reels.
    ///
    /// - Parameters:
    ///   - startFrame: Proposed start frame
    ///   - durationFrames: Proposed duration
    ///   - excludingReelId: Optional reel ID to exclude from overlap check (for updates)
    /// - Returns: True if the range overlaps with an existing reel
    /// - Note: Thread-safe, can be called from any actor
    func checkReelOverlap(
        startFrame: Int,
        durationFrames: Int,
        excludingReelId: UUID?
    ) async -> Bool

    /// Check if a clip overlaps with existing clips on a lane
    ///
    /// Useful for validation before adding/updating clips.
    ///
    /// - Parameters:
    ///   - startFrame: Proposed start frame
    ///   - durationFrames: Proposed duration
    ///   - laneId: Lane to check
    ///   - excludingClipId: Optional clip ID to exclude from overlap check (for updates)
    /// - Returns: True if the range overlaps with an existing clip on the lane
    /// - Throws: `TimelineError.laneNotFound` if lane doesn't exist
    /// - Note: Thread-safe, can be called from any actor
    func checkClipOverlap(
        startFrame: Int,
        durationFrames: Int,
        laneId: UUID,
        excludingClipId: UUID?
    ) async throws -> Bool
}
