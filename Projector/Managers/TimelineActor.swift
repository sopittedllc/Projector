import Foundation
import SwiftTimecodeCore

/// Actor managing timeline state and operations
///
/// Thread-safe timeline state management isolated from UI.
/// Implements TimelineServiceProtocol for two-layer architecture compliance.
///
/// ## Architecture
///
/// ```
/// Presentation Layer (TimelineViewModel)
///     ↓ consumes
/// THE CONTRACT (TimelineServiceProtocol)
///     ↓ implemented by
/// Logic Layer (TimelineActor) ← you are here
///     ↓ wraps (bridge pattern)
/// TimelineManager (@MainActor legacy)
/// ```
///
/// ## Implementation Strategy
///
/// This actor uses a **bridge pattern** to wrap the existing TimelineManager.
/// TimelineManager is @MainActor, so all operations are delegated to the main thread.
/// This allows for incremental refactoring without breaking existing code.
///
/// ## Thread Safety
///
/// All methods are actor-isolated and thread-safe. Internal operations
/// delegate to TimelineManager on the main thread using `MainActor.run`.
///
/// ## Usage Example
///
/// ```swift
/// let actor = TimelineActor(timelineManager: timelineManager)
///
/// // Subscribe to state updates
/// Task {
///     for await state in actor.timelineStateStream {
///         // Update UI
///     }
/// }
///
/// // Add a video reel
/// try await actor.addVideoReel(reel, at: 0)
/// ```
actor TimelineActor: TimelineServiceProtocol {
    // MARK: - Internal State

    /// The timeline manager (bridge to legacy @MainActor code)
    private let timelineManager: TimelineManager

    /// AsyncStream continuations for every active state subscriber.
    private var continuations: [UUID: AsyncStream<TimelineState>.Continuation] = [:]

    /// Observation task for timeline changes
    private var observationTask: Task<Void, Never>?

    /// Token for the observer registered with TimelineManager.
    private var timelineObserverID: UUID?

    /// Identifies the currently valid asynchronous observer registration.
    private var observationGeneration: UUID?

    // MARK: - Initialization

    /// Creates a new timeline actor wrapping an existing TimelineManager
    ///
    /// - Parameter timelineManager: The timeline manager to wrap
    /// - Note: TimelineManager must be on @MainActor
    init(timelineManager: TimelineManager) {
        self.timelineManager = timelineManager
    }

    deinit {
        observationTask?.cancel()
        for continuation in continuations.values {
            continuation.finish()
        }
        if let observerID = timelineObserverID {
            Task { @MainActor [timelineManager] in
                timelineManager.removeTimelineChangeObserver(id: observerID)
            }
        }
    }

    // MARK: - TimelineServiceProtocol: State Stream

    nonisolated var timelineStateStream: AsyncStream<TimelineState> {
        let subscriberID = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            Task {
                await self.registerContinuation(continuation, id: subscriberID)
            }
        }
    }

    private func registerContinuation(
        _ continuation: AsyncStream<TimelineState>.Continuation,
        id: UUID
    ) {
        continuations[id] = continuation

        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.handleStreamTermination(id: id)
            }
        }

        // Emit initial state
        Task {
            await self.emitState()
            if !self.continuations.isEmpty, self.observationTask == nil {
                self.startObservingTimelineManager()
            }
        }
    }

    /// Handles stream termination (cleanup)
    private func handleStreamTermination(id: UUID) {
        continuations.removeValue(forKey: id)
        if continuations.isEmpty {
            observationGeneration = nil
            observationTask?.cancel()
            observationTask = nil

            if let observerID = timelineObserverID {
                timelineObserverID = nil
                Task { @MainActor [timelineManager] in
                    timelineManager.removeTimelineChangeObserver(id: observerID)
                }
            }
        }
    }

    /// Starts observing TimelineManager for changes
    private func startObservingTimelineManager() {
        guard observationTask == nil else { return }
        let generation = UUID()
        observationGeneration = generation

        // Observe timeline changes via onTimelineChanged callback
        // Capture self strongly in the outer task since we need the actor to stay alive
        // while observing. The callback explicitly captures emitState to avoid Swift 6
        // concurrency warnings about capturing self across actor boundaries.
        observationTask = Task { [self] in
            let emitStateClosure: @Sendable () async -> Void = { [weak self] in
                await self?.emitState()
            }
            let observerID = await MainActor.run {
                self.timelineManager.addTimelineChangeObserver {
                    Task {
                        await emitStateClosure()
                    }
                }
            }
            await self.completeObserverRegistration(
                observerID,
                generation: generation,
                registrationWasCancelled: Task.isCancelled
            )
        }
    }

    private func completeObserverRegistration(
        _ observerID: UUID,
        generation: UUID,
        registrationWasCancelled: Bool
    ) async {
        guard !registrationWasCancelled,
              observationGeneration == generation,
              !continuations.isEmpty else {
            await MainActor.run {
                timelineManager.removeTimelineChangeObserver(id: observerID)
            }
            return
        }
        timelineObserverID = observerID
    }

    /// Emits current timeline state to subscribers
    private func emitState() async {
        let state = await MainActor.run {
            TimelineState(
                videoReels: timelineManager.timeline.videoReels,
                audioLanes: timelineManager.timeline.audioLanes,
                durationFrames: timelineManager.timeline.config.durationFrames,
                frameRate: timelineManager.timeline.config.frameRate,
                isDirty: timelineManager.hasChanges,
                config: timelineManager.timeline.config
            )
        }
        for continuation in continuations.values {
            continuation.yield(state)
        }
    }

    // MARK: - TimelineServiceProtocol: Video Reel Operations

    /// Adds a video reel to the timeline at the specified frame position.
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
    func addVideoReel(_ reel: VideoReel, at frame: Int) async throws {
        // Validate frame position
        guard frame >= 0 else {
            throw TimelineError.invalidFramePosition(frame: frame)
        }

        // Check for overlap
        let overlaps = await checkReelOverlap(
            startFrame: frame,
            durationFrames: reel.durationFrames,
            excludingReelId: nil
        )
        if overlaps {
            // Find the conflicting reel
            let conflictingReel = await MainActor.run {
                timelineManager.timeline.videoReels.first { existingReel in
                    let existingStart = existingReel.timelineStartFrame
                    let existingEnd = existingStart + existingReel.durationFrames
                    let newEnd = frame + reel.durationFrames
                    return (frame < existingEnd && newEnd > existingStart)
                }
            }
            if let conflictingReel = conflictingReel {
                throw TimelineError.reelOverlap(frame: frame, existingReelId: conflictingReel.id)
            }
        }

        // Add reel via TimelineManager (automatically runs on MainActor)
        _ = try await timelineManager.addVideoReel(
            from: reel.sourceURL,
            at: frame
        )

        // Emit updated state
        await emitState()
    }

    /// Removes a video reel from the timeline by ID.
    ///
    /// If the reel does not exist, this operation is a no-op.
    ///
    /// - Parameter id: UUID of the reel to remove
    /// - Note: Thread-safe, can be called from any actor
    func removeVideoReel(id: UUID) async {
        await MainActor.run {
            timelineManager.removeVideoReel(id: id)
        }
        await emitState()
    }

    /// Reorders video reels (for drag-drop operations).
    ///
    /// Moves a reel from one position to another in the timeline order.
    /// This does NOT change the reel's start frame, only its z-order/layering.
    ///
    /// - Parameters:
    ///   - fromIndex: Current index in the reels array
    ///   - toIndex: Target index in the reels array
    /// - Throws: `TimelineError.invalidFramePosition` if indices are out of bounds
    /// - Note: Thread-safe, can be called from any actor
    func reorderVideoReels(fromIndex: Int, toIndex: Int) async throws {
        let reelsCount = await MainActor.run {
            timelineManager.timeline.videoReels.count
        }

        guard fromIndex >= 0, fromIndex < reelsCount,
              toIndex >= 0, toIndex < reelsCount else {
            throw TimelineError.invalidFramePosition(frame: fromIndex)
        }

        await MainActor.run {
            var reels = timelineManager.timeline.videoReels
            let reel = reels.remove(at: fromIndex)
            reels.insert(reel, at: toIndex)
            timelineManager.timeline.videoReels = reels
        }

        await emitState()
    }

    /// Updates a video reel's properties.
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
    func updateVideoReel(id: UUID, reel: VideoReel) async throws {
        // Check if reel exists
        let exists = await MainActor.run {
            timelineManager.timeline.videoReels.contains(where: { $0.id == id })
        }
        guard exists else {
            throw TimelineError.reelNotFound(reelId: id)
        }

        // Check for overlap with other reels (excluding this one)
        let overlaps = await checkReelOverlap(
            startFrame: reel.timelineStartFrame,
            durationFrames: reel.durationFrames,
            excludingReelId: id
        )
        if overlaps {
            let conflictingReel = await MainActor.run {
                timelineManager.timeline.videoReels.first { existingReel in
                    guard existingReel.id != id else { return false }
                    let existingStart = existingReel.timelineStartFrame
                    let existingEnd = existingStart + existingReel.durationFrames
                    let newStart = reel.timelineStartFrame
                    let newEnd = newStart + reel.durationFrames
                    return (newStart < existingEnd && newEnd > existingStart)
                }
            }
            if let conflictingReel = conflictingReel {
                throw TimelineError.reelOverlap(
                    frame: reel.timelineStartFrame,
                    existingReelId: conflictingReel.id
                )
            }
        }

        // Update reel
        await MainActor.run {
            if let index = timelineManager.timeline.videoReels.firstIndex(where: { $0.id == id }) {
                timelineManager.timeline.videoReels[index] = reel
            }
        }

        await emitState()
    }

    // MARK: - TimelineServiceProtocol: Audio Lane Operations

    /// Adds an audio clip to a lane.
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
    func addAudioClip(_ clip: AudioClip, toLane laneId: UUID) async throws {
        // Check if lane exists
        let laneExists = await MainActor.run {
            timelineManager.timeline.audioLanes.contains(where: { $0.id == laneId })
        }
        guard laneExists else {
            throw TimelineError.laneNotFound(laneId: laneId)
        }

        // Validate frame position
        guard clip.timelineStartFrame >= 0 else {
            throw TimelineError.invalidFramePosition(frame: clip.timelineStartFrame)
        }

        // Check for overlap
        let overlaps = try await checkClipOverlap(
            startFrame: clip.timelineStartFrame,
            durationFrames: clip.durationFrames,
            laneId: laneId,
            excludingClipId: nil
        )
        if overlaps {
            let conflictingClip = await MainActor.run {
                timelineManager.timeline.audioLanes
                    .first(where: { $0.id == laneId })?
                    .clips
                    .first { existingClip in
                        let existingStart = existingClip.timelineStartFrame
                        let existingEnd = existingStart + existingClip.durationFrames
                        let newStart = clip.timelineStartFrame
                        let newEnd = newStart + clip.durationFrames
                        return (newStart < existingEnd && newEnd > existingStart)
                    }
            }
            if let conflictingClip = conflictingClip {
                throw TimelineError.clipOverlap(
                    frame: clip.timelineStartFrame,
                    laneId: laneId,
                    existingClipId: conflictingClip.id
                )
            }
        }

        // Add clip via TimelineManager
        _ = try await timelineManager.addAudioClip(
            from: clip.sourceURL,
            toLane: laneId,
            at: clip.timelineStartFrame
        )

        await emitState()
    }

    /// Removes an audio clip from its lane by ID.
    ///
    /// If the clip does not exist, this operation is a no-op.
    ///
    /// - Parameter id: UUID of the clip to remove
    /// - Note: Thread-safe, can be called from any actor
    func removeAudioClip(id: UUID) async {
        // Find which lane contains this clip
        let laneId = await MainActor.run {
            timelineManager.timeline.audioLanes.first { lane in
                lane.clips.contains(where: { $0.id == id })
            }?.id
        }

        guard let laneId = laneId else {
            // Clip not found - no-op as per protocol
            return
        }

        await MainActor.run {
            timelineManager.removeAudioClip(clipId: id, fromLane: laneId)
        }
        await emitState()
    }

    /// Creates a new audio lane.
    ///
    /// Lanes are added at the end of the lane list.
    ///
    /// - Parameter name: Display name for the lane
    /// - Returns: The newly created lane with generated UUID
    /// - Note: Thread-safe, can be called from any actor
    func createAudioLane(name: String) async -> AudioLane {
        let lane = await MainActor.run {
            timelineManager.addAudioLane(name: name)
        }
        await emitState()
        return lane
    }

    /// Removes an audio lane by ID.
    ///
    /// All clips on the lane are also removed.
    ///
    /// - Parameter id: UUID of the lane to remove
    /// - Throws: `TimelineError.laneNotFound` if lane doesn't exist
    /// - Note: Thread-safe, can be called from any actor
    func removeAudioLane(id: UUID) async throws {
        let laneExists = await MainActor.run {
            timelineManager.timeline.audioLanes.contains(where: { $0.id == id })
        }
        guard laneExists else {
            throw TimelineError.laneNotFound(laneId: id)
        }

        await MainActor.run {
            timelineManager.removeAudioLane(id: id)
        }
        await emitState()
    }

    /// Updates audio lane properties (name, mute, solo, volume).
    ///
    /// - Parameters:
    ///   - id: UUID of the lane to update
    ///   - lane: New lane data
    /// - Throws: `TimelineError.laneNotFound` if lane doesn't exist
    /// - Note: Thread-safe, can be called from any actor
    func updateAudioLane(id: UUID, lane: AudioLane) async throws {
        let laneExists = await MainActor.run {
            timelineManager.timeline.audioLanes.contains(where: { $0.id == id })
        }
        guard laneExists else {
            throw TimelineError.laneNotFound(laneId: id)
        }

        await MainActor.run {
            // Update lane properties via TimelineManager methods
            timelineManager.renameAudioLane(id: id, name: lane.name)
            timelineManager.setLaneMuted(id: id, muted: lane.isMuted)
            timelineManager.setLaneSolo(id: id, solo: lane.isSolo)
            timelineManager.setLaneVolume(id: id, volume: lane.volume)
            timelineManager.setLaneOutputOffset(id: id, offset: lane.outputChannelOffset)
            if let deviceUID = lane.outputDeviceUID {
                timelineManager.setLaneOutputDevice(id: id, deviceUID: deviceUID)
            }
        }

        await emitState()
    }

    // MARK: - TimelineServiceProtocol: Configuration

    /// Updates timeline configuration (frame rate, start timecode, duration).
    ///
    /// Changing the frame rate may cause reels/clips to shift position if their
    /// timecode-based positions are recalculated.
    ///
    /// - Parameter config: New timeline configuration
    /// - Note: Thread-safe, can be called from any actor
    func updateConfiguration(_ config: TimelineConfig) async {
        await MainActor.run {
            timelineManager.updateConfig(config)
        }
        await emitState()
    }

    // MARK: - TimelineServiceProtocol: Queries

    /// Gets the current timeline state synchronously.
    ///
    /// This is a snapshot of the current state. For continuous updates,
    /// subscribe to `timelineStateStream` instead.
    ///
    /// - Returns: Current timeline state
    /// - Note: Thread-safe, can be called from any actor
    func getCurrentState() async -> TimelineState {
        await MainActor.run {
            TimelineState(
                videoReels: timelineManager.timeline.videoReels,
                audioLanes: timelineManager.timeline.audioLanes,
                durationFrames: timelineManager.timeline.config.durationFrames,
                frameRate: timelineManager.timeline.config.frameRate,
                isDirty: timelineManager.hasChanges,
                config: timelineManager.timeline.config
            )
        }
    }

    /// Checks if a reel overlaps with existing reels.
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
    ) async -> Bool {
        await MainActor.run {
            let endFrame = startFrame + durationFrames

            for reel in timelineManager.timeline.videoReels {
                // Skip the excluded reel
                if let excludingReelId = excludingReelId, reel.id == excludingReelId {
                    continue
                }

                let reelStart = reel.timelineStartFrame
                let reelEnd = reelStart + reel.durationFrames

                // Check for overlap
                if startFrame < reelEnd && endFrame > reelStart {
                    return true
                }
            }

            return false
        }
    }

    /// Checks if a clip overlaps with existing clips on a lane.
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
    ) async throws -> Bool {
        // Check if lane exists
        let laneExists = await MainActor.run {
            timelineManager.timeline.audioLanes.contains(where: { $0.id == laneId })
        }
        guard laneExists else {
            throw TimelineError.laneNotFound(laneId: laneId)
        }

        return await MainActor.run {
            guard let lane = timelineManager.timeline.audioLanes.first(where: { $0.id == laneId }) else {
                return false
            }

            let endFrame = startFrame + durationFrames

            for clip in lane.clips {
                // Skip the excluded clip
                if let excludingClipId = excludingClipId, clip.id == excludingClipId {
                    continue
                }

                let clipStart = clip.timelineStartFrame
                let clipEnd = clipStart + clip.durationFrames

                // Check for overlap
                if startFrame < clipEnd && endFrame > clipStart {
                    return true
                }
            }

            return false
        }
    }
}
