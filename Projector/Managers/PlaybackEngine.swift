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

        if isInGap {
            // In a gap - still advance time but show black
            isPlaying = true
            startGapPlayback()
        } else {
            currentPlayer?.play()
            isPlaying = true
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

        // Check if we need to switch reels
        if let reel = timeline.videoReel(at: clampedFrame) {
            if reel.id != currentReelId {
                // Need to switch to different reel
                Task {
                    try? await loadReel(reel)
                    seekWithinReel(reel, timelineFrame: clampedFrame)
                }
            } else {
                // Same reel, just seek within it
                seekWithinReel(reel, timelineFrame: clampedFrame)
            }
            isInGap = false
            activeReel = reel
        } else {
            // In a gap - show black
            isInGap = true
            activeReel = nil
            currentPlayer?.pause()
        }

        // Update audio clips
        syncAudioClips()
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

            // If we were playing, continue playing
            if isPlaying {
                if isInGap {
                    startGapPlayback()
                } else {
                    currentPlayer?.play()
                }
            }
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

    /// Seek within a reel to a specific timeline frame
    private func seekWithinReel(_ reel: VideoReel, timelineFrame: Int) {
        guard let sourceTime = reel.sourceTime(at: timelineFrame),
              let player = currentPlayer else { return }

        isSeeking = true
        let time = CMTime(seconds: sourceTime, preferredTimescale: 600)

        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] completed in
            Task { @MainActor in
                self?.isSeeking = false
                if completed && self?.isPlaying == true {
                    self?.currentPlayer?.play()
                }
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
                seekWithinReel(reel, timelineFrame: currentFrame)
                if isPlaying {
                    currentPlayer?.play()
                }
            }
        }

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
            }
        }
    }

    /// Load an audio clip for playback
    private func loadAudioClip(_ clip: AudioClip, lane: AudioLane) {
        let asset: AVAsset

        if clip.sourceType == .videoTrack, let cached = assetCache.values.first(where: { _ in true }) {
            // For video audio, use cached asset if available
            asset = cached
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
                if let sourceTime = clip.sourceTime(at: currentFrame, masterFrameRate: frameRate) {
                    let time = CMTime(seconds: sourceTime, preferredTimescale: 600)
                    player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
                }
            } else {
                loadAudioClip(clip, lane: lane)
            }
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

    /// Update timeline properties when timeline changes
    private func updateTimelineProperties() {
        durationFrames = timeline.config.durationFrames
        hasContent = !timeline.videoReels.isEmpty || !timeline.audioLanes.isEmpty
        currentTimecode = timeline.config.timecode(at: currentFrame)
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
