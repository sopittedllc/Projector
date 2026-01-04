import Foundation
import AVFoundation
import Combine
import SwiftTimecodeCore

/// Multi-reel playback engine with timeline support
/// Manages seamless video reel switching and multiple audio clip playback
@MainActor
final class PlaybackEngine: ObservableObject {
    // MARK: - Published Properties

    /// Primary video player (current reel)
    @Published private(set) var currentPlayer: AVPlayer?

    /// Whether playback is active
    @Published private(set) var isPlaying = false

    /// Current position on the master timeline (in frames)
    @Published private(set) var currentFrame: Int = 0

    /// Current timecode based on timeline position
    @Published private(set) var currentTimecode: Timecode

    /// Duration of the timeline in frames
    @Published private(set) var durationFrames: Int = 0

    /// Whether video is currently in a gap (no reel at current position)
    @Published private(set) var isInGap = false

    /// Active video reel at current position (nil if in gap)
    @Published private(set) var activeReel: VideoReel?

    /// Has any content loaded
    @Published private(set) var hasContent = false

    // MARK: - Timeline Reference

    /// The timeline being played back
    var timeline: Timeline {
        didSet {
            updateTimelineProperties()
        }
    }

    /// Convenience: frame rate from timeline config
    var frameRate: TimecodeFrameRate {
        timeline.config.frameRate
    }

    /// Convenience: current time in seconds
    var currentTime: Double {
        Double(currentFrame) / frameRate.fps
    }

    /// Convenience: duration in seconds
    var duration: Double {
        Double(durationFrames) / frameRate.fps
    }

    // MARK: - Private Properties

    /// Secondary video player for preloading next reel
    private var preloadPlayer: AVPlayer?

    /// Asset cache for loaded video files
    private var assetCache: [UUID: AVAsset] = [:]

    /// Audio players for active clips
    private var audioPlayers: [UUID: AVPlayer] = [:]

    /// Time observer for periodic updates
    private var timeObserver: Any?

    /// Display link for frame-accurate updates
    private var displayLink: CVDisplayLink?

    /// Current reel ID being played
    private var currentReelId: UUID?

    /// ID of reel being preloaded
    private var preloadingReelId: UUID?

    /// Playback rate (1.0 = normal)
    private var playbackRate: Float = 1.0

    /// Whether we're currently seeking
    private var isSeeking = false

    /// Selected audio output device UID
    private var audioOutputDeviceUID: String?

    /// Pending seek request (coalesced)
    private var pendingSeekFrame: Int?

    // MARK: - Constants

    /// Seconds before reel boundary to start preloading
    private let preloadThreshold: Double = 5.0

    // MARK: - Initialization

    init(timeline: Timeline = .empty) {
        self.timeline = timeline
        self.currentTimecode = timeline.config.startTimecode
        updateTimelineProperties()
    }

    // MARK: - Public Methods

    /// Load a video reel and prepare for playback
    func loadReel(_ reel: VideoReel) async throws {
        // Get or create asset
        let asset = try await getAsset(for: reel)

        // Check playability
        let isPlayable = try await asset.load(.isPlayable)
        guard isPlayable else {
            throw PlaybackEngineError.notPlayable
        }

        // Create player
        let playerItem = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: playerItem)
        player.automaticallyWaitsToMinimizeStalling = false
        player.isMuted = true

        // Cache asset
        assetCache[reel.id] = asset

        // Update current player
        removeTimeObserver()
        currentPlayer?.pause()
        currentPlayer = player
        currentReelId = reel.id
        activeReel = reel
        isInGap = false
        hasContent = true

        setupTimeObserver()
    }

    /// Start playback
    func play() {
        guard hasContent else { return }

        if let reel = timeline.videoReel(at: currentFrame) {
            isInGap = false
            activeReel = reel
            isPlaying = true

            if currentPlayer == nil || currentReelId != reel.id {
                Task {
                    try? await loadReel(reel)
                    seekWithinReel(reel, timelineFrame: currentFrame, resumeAfterSeek: true) {}
                }
            } else {
                currentPlayer?.play()
            }
        } else {
            // No video reel at this frame - advance time in a gap
            isInGap = true
            activeReel = nil
            isPlaying = true
            currentPlayer?.pause()
            startGapPlayback()
        }

        // Start audio clips
        startActiveAudioClips()
    }

    /// Pause playback
    func pause() {
        currentPlayer?.pause()
        isPlaying = false
        stopGapPlayback()
        stopAllAudioClips()
    }

    /// Toggle play/pause
    func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    /// Stop playback and return to start
    func stop() {
        pause()
        seekToFrame(0)
    }

    /// Seek to a specific timeline frame
    func seekToFrame(_ frame: Int) {
        let clampedFrame = max(0, min(frame, durationFrames - 1))
        currentFrame = clampedFrame
        updateCurrentTimecode()
        pendingSeekFrame = clampedFrame
        performPendingSeekIfNeeded()
    }

    /// Seek to a specific timecode
    func seekToTimecode(_ timecode: Timecode) {
        let frame = timeline.config.frame(for: timecode)
        seekToFrame(frame)
    }

    /// Seek to MTC timecode (for external sync)
    func seekToMTC(_ timecode: Timecode) {
        // Only seek if timecode is within timeline bounds
        let frame = timeline.config.frame(for: timecode)
        if timeline.config.isValidFrame(frame) {
            seekToFrame(frame)
        }
    }

    /// Step forward by one frame
    func stepForward() {
        seekToFrame(currentFrame + 1)
    }

    /// Step backward by one frame
    func stepBackward() {
        seekToFrame(currentFrame - 1)
    }

    /// Set the audio output device
    func setAudioOutputDevice(_ deviceUID: String?) {
        audioOutputDeviceUID = deviceUID
        currentPlayer?.audioOutputDeviceUniqueID = deviceUID
        preloadPlayer?.audioOutputDeviceUniqueID = deviceUID

        for player in audioPlayers.values {
            player.audioOutputDeviceUniqueID = deviceUID
        }
    }

    // MARK: - Private Methods - Video

    /// Get or load asset for a reel
    private func getAsset(for reel: VideoReel) async throws -> AVAsset {
        if let cached = assetCache[reel.id] {
            return cached
        }

        let asset = AVAsset(url: reel.sourceURL)
        assetCache[reel.id] = asset
        return asset
    }

    private func seekWithinReel(
        _ reel: VideoReel,
        timelineFrame: Int,
        resumeAfterSeek: Bool,
        completion: @escaping () -> Void
    ) {
        guard let sourceTime = reel.sourceTime(at: timelineFrame),
              let player = currentPlayer else {
            completion()
            return
        }

        let time = CMTime(seconds: sourceTime, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] completed in
            Task { @MainActor in
                if completed && resumeAfterSeek {
                    self?.currentPlayer?.play()
                }
                completion()
            }
        }
    }

    /// Check if we need to preload the next reel
    private func checkPreload() {
        guard let currentReel = activeReel else { return }

        // Calculate time until end of current reel
        let framesUntilEnd = currentReel.timelineEndFrame - currentFrame
        let secondsUntilEnd = Double(framesUntilEnd) / frameRate.fps

        if secondsUntilEnd <= preloadThreshold {
            // Find next reel
            if let nextReel = timeline.sortedVideoReels.first(where: {
                $0.timelineStartFrame >= currentReel.timelineEndFrame
            }), nextReel.id != preloadingReelId {
                preloadReel(nextReel)
            }
        }
    }

    /// Preload a reel for seamless transition
    private func preloadReel(_ reel: VideoReel) {
        preloadingReelId = reel.id

        Task {
            do {
                let asset = try await getAsset(for: reel)
                let isPlayable = try await asset.load(.isPlayable)

                guard isPlayable else { return }

                let playerItem = AVPlayerItem(asset: asset)
                let player = AVPlayer(playerItem: playerItem)
                player.automaticallyWaitsToMinimizeStalling = false
                player.isMuted = true

                await MainActor.run {
                    self.preloadPlayer = player
                }
            } catch {
                NSLog(">>> PlaybackEngine: Failed to preload reel: \(error)")
            }
        }
    }

    /// Switch to the preloaded player
    private func switchToPreloadedPlayer(_ reel: VideoReel) {
        guard let preload = preloadPlayer, preloadingReelId == reel.id else { return }

        // Pause current
        currentPlayer?.pause()
        removeTimeObserver()

        // Swap players
        currentPlayer = preload
        currentReelId = reel.id
        activeReel = reel
        preloadPlayer = nil
        preloadingReelId = nil

        setupTimeObserver()

        // Start playback if we were playing
        if isPlaying {
            currentPlayer?.play()
        }
    }

    // MARK: - Private Methods - Gap Handling

    /// Timer for advancing time during gaps
    private var gapTimer: Timer?

    /// Start advancing time during a gap
    private func startGapPlayback() {
        stopGapPlayback()

        // Create timer that fires at frame rate
        let interval = 1.0 / frameRate.fps
        gapTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.advanceFrameInGap()
            }
        }
    }

    /// Stop gap playback timer
    private func stopGapPlayback() {
        gapTimer?.invalidate()
        gapTimer = nil
    }

    /// Advance one frame during gap playback
    private func advanceFrameInGap() {
        guard isPlaying, isInGap else {
            stopGapPlayback()
            return
        }

        currentFrame += 1
        updateCurrentTimecode()

        // Check if we've exited the gap
        if let reel = timeline.videoReel(at: currentFrame) {
            isInGap = false
            stopGapPlayback()

            // Load and play the reel
            Task {
                try? await loadReel(reel)
                seekWithinReel(reel, timelineFrame: currentFrame, resumeAfterSeek: isPlaying) {}
            }
        }

        // Sync audio clips while advancing without video
        syncAudioClips()

        // Check if we've reached the end
        if currentFrame >= durationFrames {
            pause()
        }
    }

    // MARK: - Private Methods - Audio

    /// Start playing active audio clips at current position
    private func startActiveAudioClips() {
        let activeClips = timeline.activeAudioClips(at: currentFrame)

        for (lane, clip) in activeClips {
            if audioPlayers[clip.id] == nil {
                loadAudioClip(clip, lane: lane)
            } else if let player = audioPlayers[clip.id] {
                syncAudioPlayer(player, for: clip, shouldPlay: isPlaying)
            }
        }
    }

    /// Load an audio clip for playback
    private func loadAudioClip(_ clip: AudioClip, lane: AudioLane) {
        let asset: AVAsset

        if clip.sourceType == .videoTrack {
            if let cached = assetCache.values.first(where: { asset in
                guard let urlAsset = asset as? AVURLAsset else { return false }
                return urlAsset.url == clip.sourceURL
            }) {
                asset = cached
            } else {
                asset = AVAsset(url: clip.sourceURL)
            }
        } else {
            asset = AVAsset(url: clip.sourceURL)
        }

        Task {
            do {
                let tracks = try await asset.load(.tracks)
                let audioTracks = tracks.filter { $0.mediaType == .audio }

                guard let trackIndex = clip.sourceTrackIndex ?? (audioTracks.isEmpty ? nil : 0),
                      trackIndex < audioTracks.count else { return }

                let playerItem = AVPlayerItem(asset: asset)
                let player = AVPlayer(playerItem: playerItem)
                player.automaticallyWaitsToMinimizeStalling = false
                player.audioOutputDeviceUniqueID = self.audioOutputDeviceUID

                // Apply volume
                let volume = clip.volume * lane.volume
                player.volume = volume

                await MainActor.run {
                    self.audioPlayers[clip.id] = player

                    // Seek to correct position
                    if let sourceTime = clip.sourceTime(at: self.currentFrame, masterFrameRate: self.frameRate) {
                        let time = CMTime(seconds: sourceTime, preferredTimescale: 600)
                        let shouldPlay = self.isPlaying
                        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { completed in
                            if completed && shouldPlay {
                                player.play()
                            }
                        }
                    }
                }
            } catch {
                NSLog(">>> PlaybackEngine: Failed to load audio clip: \(error)")
            }
        }
    }

    /// Stop all audio clips
    private func stopAllAudioClips() {
        for player in audioPlayers.values {
            player.pause()
        }
    }

    /// Sync audio clips to current position
    private func syncAudioClips() {
        // Get currently active clips
        let activeClips = timeline.activeAudioClips(at: currentFrame)
        let activeIds = Set(activeClips.map { $0.clip.id })

        // Remove clips that are no longer active
        for id in audioPlayers.keys {
            if !activeIds.contains(id) {
                audioPlayers[id]?.pause()
                audioPlayers.removeValue(forKey: id)
            }
        }

        // Seek active clips
        for (lane, clip) in activeClips {
            if let player = audioPlayers[clip.id] {
                syncAudioPlayer(player, for: clip, shouldPlay: isPlaying)
            } else {
                loadAudioClip(clip, lane: lane)
            }
        }
    }

    private func syncAudioPlayer(_ player: AVPlayer, for clip: AudioClip, shouldPlay: Bool) {
        guard let sourceTime = clip.sourceTime(at: currentFrame, masterFrameRate: frameRate) else { return }
        let time = CMTime(seconds: sourceTime, preferredTimescale: 600)
        let currentSeconds = CMTimeGetSeconds(player.currentTime())
        let drift = abs(currentSeconds - sourceTime)
        let driftThreshold = shouldPlay ? 0.2 : 0.01

        if isSeeking || drift > driftThreshold {
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        }

        if shouldPlay, player.timeControlStatus != .playing {
            player.play()
        }
    }

    // MARK: - Private Methods - Time Observation

    /// Setup time observer for current player
    private func setupTimeObserver() {
        guard let player = currentPlayer else { return }

        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)

        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.handleTimeUpdate()
            }
        }
    }

    /// Remove time observer
    private func removeTimeObserver() {
        if let observer = timeObserver {
            currentPlayer?.removeTimeObserver(observer)
            timeObserver = nil
        }
    }

    /// Handle periodic time update
    private func handleTimeUpdate() {
        guard !isSeeking, let reel = activeReel, let player = currentPlayer else { return }

        let playerTime = CMTimeGetSeconds(player.currentTime())

        // Convert player time back to timeline frame
        let sourceFrame = Int(playerTime * reel.sourceFrameRate.fps)
        let timelineFrame = (sourceFrame - reel.sourceStartFrame) + reel.timelineStartFrame

        if timelineFrame != currentFrame {
            currentFrame = max(0, timelineFrame)
            updateCurrentTimecode()

            // Check for reel boundary
            if currentFrame >= reel.timelineEndFrame {
                handleReelEnd()
            }

            // Check for preload
            checkPreload()

            // Sync audio
            syncAudioClips()
        }
    }

    /// Handle reaching end of current reel
    private func handleReelEnd() {
        guard let currentReel = activeReel else { return }

        // Check if there's a next reel
        if let nextReel = timeline.sortedVideoReels.first(where: {
            $0.timelineStartFrame == currentReel.timelineEndFrame
        }) {
            // Seamless transition to next reel
            if preloadingReelId == nextReel.id, preloadPlayer != nil {
                switchToPreloadedPlayer(nextReel)
            } else {
                // Need to load the next reel
                Task {
                    try? await loadReel(nextReel)
                    if isPlaying {
                        currentPlayer?.play()
                    }
                }
            }
        } else {
            // Entering a gap
            isInGap = true
            activeReel = nil
            currentPlayer?.pause()

            if isPlaying {
                startGapPlayback()
            }
        }
    }

    /// Update current timecode from frame
    private func updateCurrentTimecode() {
        currentTimecode = timeline.config.timecode(at: currentFrame)
    }

    private func performPendingSeekIfNeeded() {
        guard !isSeeking, let targetFrame = pendingSeekFrame else { return }
        pendingSeekFrame = nil

        let wasPlaying = isPlaying
        if wasPlaying {
            currentPlayer?.pause()
            stopGapPlayback()
            stopAllAudioClips()
        }

        isSeeking = true

        performSeek(to: targetFrame) { [weak self] in
            guard let self else { return }
            self.isSeeking = false

            if self.pendingSeekFrame != nil {
                self.performPendingSeekIfNeeded()
                return
            }

            if wasPlaying {
                if self.isInGap {
                    self.startGapPlayback()
                } else {
                    self.currentPlayer?.play()
                }
            }

            self.syncAudioClips()
        }
    }

    private func performSeek(to frame: Int, completion: @escaping () -> Void) {
        if let reel = timeline.videoReel(at: frame) {
            isInGap = false
            activeReel = reel

            if reel.id != currentReelId {
                Task { [weak self] in
                    guard let self else { return }
                    try? await self.loadReel(reel)
                    self.seekWithinReel(reel, timelineFrame: frame, resumeAfterSeek: false, completion: completion)
                }
            } else {
                seekWithinReel(reel, timelineFrame: frame, resumeAfterSeek: false, completion: completion)
            }
        } else {
            isInGap = true
            activeReel = nil
            currentPlayer?.pause()
            completion()
        }
    }

    /// Update timeline properties when timeline changes
    private func updateTimelineProperties() {
        durationFrames = timeline.config.durationFrames
        hasContent = !timeline.videoReels.isEmpty || timeline.audioLanes.contains { !$0.clips.isEmpty }
        currentTimecode = timeline.config.timecode(at: currentFrame)
        isInGap = timeline.videoReel(at: currentFrame) == nil
        if isInGap && timeline.videoReels.isEmpty {
            activeReel = nil
        }
    }

    // MARK: - Cleanup

    deinit {
        gapTimer?.invalidate()
    }
}

// MARK: - Errors

enum PlaybackEngineError: LocalizedError {
    case notPlayable
    case reelNotFound
    case seekFailed

    var errorDescription: String? {
        switch self {
        case .notPlayable:
            return "The video file cannot be played."
        case .reelNotFound:
            return "The video reel could not be found."
        case .seekFailed:
            return "Failed to seek to the specified position."
        }
    }
}
