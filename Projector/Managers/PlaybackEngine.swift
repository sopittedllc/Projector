import Foundation
import AVFoundation
import Combine
import SwiftTimecodeCore
import AudioToolbox

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

    /// Audio engine for routed playback
    private let audioEngine = AVAudioEngine()

    /// Audio players for active clips
    private var audioPlayers: [UUID: AudioClipPlayback] = [:]

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

    /// Selected audio output device ID
    private var audioOutputDeviceID: AudioDeviceID?

    /// Output channel count for selected device
    private var audioOutputChannelCount: Int = 2

    /// Output sample rate for selected device
    private var audioOutputSampleRate: Double = 48000

    /// Cached output format
    private var audioOutputFormat: AVAudioFormat?

    /// Cached extracted audio files for video tracks
    private var extractedAudioCache: [AudioExtractionKey: URL] = [:]

    /// Pending audio extractions to prevent race conditions
    private var pendingExtractions: [AudioExtractionKey: Task<URL, Error>] = [:]

    /// Pending seek request (coalesced)
    private var pendingSeekFrame: Int?

    // MARK: - Constants

    /// Seconds before reel boundary to start preloading
    private let preloadThreshold: Double = 5.0

    private struct AudioExtractionKey: Hashable {
        let url: URL
        let trackIndex: Int
    }

    private struct ExportSessionBox: @unchecked Sendable {
        let session: AVAssetExportSession
    }

    private final class AudioClipPlayback {
        let clipId: UUID
        let player: AVAudioPlayerNode
        let rateConverter: AVAudioMixerNode
        let channelMapper: AVAudioUnit
        let audioFile: AVAudioFile
        let inputChannelCount: Int

        var outputMappingId: UUID?
        var outputChannelOffset: Int
        var outputChannelCount: Int
        var scheduledSourceTime: Double?

        init(
            clipId: UUID,
            player: AVAudioPlayerNode,
            rateConverter: AVAudioMixerNode,
            channelMapper: AVAudioUnit,
            audioFile: AVAudioFile,
            inputChannelCount: Int,
            outputMappingId: UUID?,
            outputChannelOffset: Int,
            outputChannelCount: Int
        ) {
            self.clipId = clipId
            self.player = player
            self.rateConverter = rateConverter
            self.channelMapper = channelMapper
            self.audioFile = audioFile
            self.inputChannelCount = inputChannelCount
            self.outputMappingId = outputMappingId
            self.outputChannelOffset = outputChannelOffset
            self.outputChannelCount = outputChannelCount
            self.scheduledSourceTime = nil
        }
    }

    // MARK: - Initialization

    init(timeline: Timeline = .empty) {
        self.timeline = timeline
        self.currentTimecode = timeline.config.startTimecode
        updateTimelineProperties()
        updateAudioOutputDeviceSettings()
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
        resetSeekState()

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
        resetSeekState()
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

    private func resetSeekState() {
        isSeeking = false
        pendingSeekFrame = nil
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
        updateAudioOutputDeviceSettings()
        reconfigureAudioEngineForOutputChange()
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
                if completed && resumeAfterSeek, self?.isPlaying == true {
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
        let totalClips = timeline.audioLanes.flatMap { $0.clips }.count

        NSLog(">>> startActiveAudioClips: frame=\(currentFrame), activeClips=\(activeClips.count), totalClips=\(totalClips), lanes=\(timeline.audioLanes.count)")

        guard !activeClips.isEmpty else {
            NSLog(">>> startActiveAudioClips: no active clips at current frame")
            return
        }

        for (lane, clip) in activeClips {
            NSLog(">>> startActiveAudioClips: loading clip \(clip.id) from lane \(lane.name)")
            if let playback = audioPlayers[clip.id] {
                syncAudioPlayer(playback, for: clip, lane: lane, shouldPlay: isPlaying)
            } else {
                loadAudioClip(clip, lane: lane)
            }
        }
    }

    /// Load an audio clip for playback
    private func loadAudioClip(_ clip: AudioClip, lane: AudioLane) {
        NSLog(">>> loadAudioClip: starting for clip \(clip.id), sourceType=\(clip.sourceType)")
        let clipSnapshot = clip
        let laneSnapshot = lane
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let sourceURL: URL
                if clipSnapshot.sourceType == .videoTrack {
                    NSLog(">>> loadAudioClip: extracting audio from video track")
                    sourceURL = try await self.getExtractedAudioURL(for: clipSnapshot)
                } else {
                    sourceURL = clipSnapshot.sourceURL
                }
                let audioFile = try AVAudioFile(forReading: sourceURL)
                let playback = try await self.buildAudioPlayback(for: clipSnapshot, lane: laneSnapshot, audioFile: audioFile)
                await MainActor.run {
                    self.audioPlayers[clipSnapshot.id] = playback
                    self.scheduleAudioPlayback(
                        playback,
                        clip: clipSnapshot,
                        lane: laneSnapshot,
                        shouldPlay: self.isPlaying
                    )
                }
            } catch {
                NSLog(">>> PlaybackEngine: Failed to load audio clip: \(error)")
            }
        }
    }

    /// Get or extract audio URL, coordinating concurrent requests
    private func getExtractedAudioURL(for clip: AudioClip) async throws -> URL {
        let key = AudioExtractionKey(
            url: clip.sourceURL,
            trackIndex: clip.sourceTrackIndex ?? 0
        )

        // Atomically check cache, pending task, or create new extraction
        let taskToAwait: Task<URL, Error> = await MainActor.run {
            // Check cache first
            if let cached = self.extractedAudioCache[key] {
                return Task { cached }
            }

            // Check for pending extraction
            if let pendingTask = self.pendingExtractions[key] {
                return pendingTask
            }

            // Create and register new extraction task
            let extractionTask = Task<URL, Error> {
                try await Self.extractAudioToTemporaryFile(for: clip, key: key)
            }
            self.pendingExtractions[key] = extractionTask
            return extractionTask
        }

        do {
            let extractedURL = try await taskToAwait.value
            await MainActor.run {
                self.extractedAudioCache[key] = extractedURL
                self.pendingExtractions.removeValue(forKey: key)
            }
            return extractedURL
        } catch {
            _ = await MainActor.run {
                self.pendingExtractions.removeValue(forKey: key)
            }
            throw error
        }
    }

    /// Stop all audio clips
    private func stopAllAudioClips() {
        for playback in audioPlayers.values {
            playback.player.stop()
        }
    }

    /// Sync audio clips to current position
    private func syncAudioClips() {
        // Get currently active clips
        let activeClips = timeline.activeAudioClips(at: currentFrame)
        let activeIds = Set(activeClips.map { $0.clip.id })

        // Remove clips that are no longer active
        for id in Array(audioPlayers.keys) {
            if !activeIds.contains(id) {
                removeAudioPlayback(id: id)
            }
        }

        // Seek active clips
        for (lane, clip) in activeClips {
            if let playback = audioPlayers[clip.id] {
                syncAudioPlayer(playback, for: clip, lane: lane, shouldPlay: isPlaying)
            } else {
                loadAudioClip(clip, lane: lane)
            }
        }
    }

    private func syncAudioPlayer(_ playback: AudioClipPlayback, for clip: AudioClip, lane: AudioLane, shouldPlay: Bool) {
        applyOutputMappingIfNeeded(playback, lane: lane)
        playback.player.volume = clip.volume * lane.volume
        guard let sourceTime = clip.sourceTime(at: currentFrame, masterFrameRate: frameRate) else { return }

        let currentSeconds: Double? = {
            guard let nodeTime = playback.player.lastRenderTime,
                  let playerTime = playback.player.playerTime(forNodeTime: nodeTime) else {
                return nil
            }
            let scheduledBase = playback.scheduledSourceTime ?? sourceTime
            return scheduledBase + (Double(playerTime.sampleTime) / playerTime.sampleRate)
        }()

        guard let currentSeconds else {
            scheduleAudioPlayback(playback, clip: clip, lane: lane, shouldPlay: shouldPlay)
            return
        }

        let drift = abs(currentSeconds - sourceTime)
        let driftThreshold = shouldPlay ? 0.2 : 0.01

        if isSeeking || drift > driftThreshold {
            scheduleAudioPlayback(playback, clip: clip, lane: lane, shouldPlay: shouldPlay)
        }

        if shouldPlay, !playback.player.isPlaying {
            ensureAudioEngineRunning()
            playback.player.play()
        } else if !shouldPlay, playback.player.isPlaying {
            playback.player.pause()
        }
    }

    private func scheduleAudioPlayback(
        _ playback: AudioClipPlayback,
        clip: AudioClip,
        lane: AudioLane,
        shouldPlay: Bool
    ) {
        guard let sourceTime = clip.sourceTime(at: currentFrame, masterFrameRate: frameRate) else { return }

        let file = playback.audioFile
        let sampleRate = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(sourceTime * sampleRate)
        let remainingSeconds = Double(max(0, clip.timelineEndFrame - currentFrame)) / frameRate.fps
        let maxFrames = AVAudioFramePosition(remainingSeconds * sampleRate)
        let availableFrames = max(0, file.length - startFrame)
        let frameCount = AVAudioFrameCount(min(Double(availableFrames), Double(maxFrames)))

        guard frameCount > 0 else { return }

        playback.player.stop()
        playback.player.volume = clip.volume * lane.volume
        playback.player.scheduleSegment(file, startingFrame: startFrame, frameCount: frameCount, at: nil)
        playback.scheduledSourceTime = sourceTime
        if shouldPlay {
            ensureAudioEngineRunning()
            playback.player.play()
        }
    }

    private func buildAudioPlayback(
        for clip: AudioClip,
        lane: AudioLane,
        audioFile: AVAudioFile
    ) async throws -> AudioClipPlayback {
        configureAudioEngineIfNeeded()

        let player = AVAudioPlayerNode()
        let rateConverter = AVAudioMixerNode()
        let channelMapper = try await makeChannelMapConverter()
        let inputFormat = audioFile.processingFormat

        // Determine the intermediate format after sample rate conversion
        // Use the output sample rate but keep the input channel count
        let intermediateFormat = AVAudioFormat(
            standardFormatWithSampleRate: audioOutputSampleRate,
            channels: inputFormat.channelCount
        ) ?? inputFormat

        // Determine the multi-channel output format for the channel mapper
        let outputChannels = AVAudioChannelCount(max(2, audioOutputChannelCount))
        let channelMapperOutputFormat = AVAudioFormat(
            standardFormatWithSampleRate: audioOutputSampleRate,
            channels: outputChannels
        ) ?? audioOutputFormat ?? intermediateFormat

        audioEngine.attach(player)
        audioEngine.attach(rateConverter)
        audioEngine.attach(channelMapper)

        // Debug: log format information
        NSLog(">>> Audio formats - Input: \(inputFormat.sampleRate)Hz/\(inputFormat.channelCount)ch, " +
              "Intermediate: \(intermediateFormat.sampleRate)Hz/\(intermediateFormat.channelCount)ch, " +
              "Output: \(channelMapperOutputFormat.sampleRate)Hz/\(channelMapperOutputFormat.channelCount)ch, " +
              "Engine output: \(audioOutputSampleRate)Hz/\(audioOutputChannelCount)ch")

        // Player -> RateConverter: mixer handles sample rate conversion automatically
        audioEngine.connect(player, to: rateConverter, format: inputFormat)

        // RateConverter -> ChannelMapper: intermediate format with correct sample rate
        audioEngine.connect(rateConverter, to: channelMapper, format: intermediateFormat)

        // ChannelMapper -> MainMixer: connect with intermediate format
        // The mixer node handles any remaining format conversion
        audioEngine.connect(channelMapper, to: audioEngine.mainMixerNode, format: intermediateFormat)

        let inputChannelCount = Int(inputFormat.channelCount)
        let playback = AudioClipPlayback(
            clipId: clip.id,
            player: player,
            rateConverter: rateConverter,
            channelMapper: channelMapper,
            audioFile: audioFile,
            inputChannelCount: inputChannelCount,
            outputMappingId: lane.outputMappingId,
            outputChannelOffset: lane.outputChannelOffset,
            outputChannelCount: lane.outputChannelCount
        )
        playback.channelMapper.auAudioUnit.channelMap = makeChannelMap(
            lane: lane,
            inputChannelCount: inputChannelCount
        )
        return playback
    }

    private func removeAudioPlayback(id: UUID) {
        guard let playback = audioPlayers[id] else { return }
        playback.player.stop()
        audioEngine.detach(playback.player)
        audioEngine.detach(playback.rateConverter)
        audioEngine.detach(playback.channelMapper)
        audioPlayers.removeValue(forKey: id)
    }

    private func applyOutputMappingIfNeeded(_ playback: AudioClipPlayback, lane: AudioLane) {
        let mappingChanged = playback.outputMappingId != lane.outputMappingId
            || playback.outputChannelOffset != lane.outputChannelOffset
            || playback.outputChannelCount != lane.outputChannelCount

        guard mappingChanged else { return }

        playback.outputMappingId = lane.outputMappingId
        playback.outputChannelOffset = lane.outputChannelOffset
        playback.outputChannelCount = lane.outputChannelCount

        playback.channelMapper.auAudioUnit.channelMap = makeChannelMap(
            lane: lane,
            inputChannelCount: playback.inputChannelCount
        )
    }

    private func makeChannelMap(lane: AudioLane, inputChannelCount: Int) -> [NSNumber]? {
        let needsCustomRouting = lane.outputChannelOffset != 0
            || (lane.outputChannelCount != 2 && lane.outputChannelCount != inputChannelCount)

        guard needsCustomRouting else { return nil }
        let outputChannels = max(1, audioOutputChannelCount)
        let outputStart = min(max(lane.outputChannelOffset, 0), max(0, outputChannels - 1))
        let channelsToMap = min(
            max(1, lane.outputChannelCount),
            inputChannelCount,
            outputChannels - outputStart
        )

        guard channelsToMap > 0 else { return nil }

        var map = Array(repeating: -1, count: outputChannels)
        for index in 0..<channelsToMap {
            map[outputStart + index] = index
        }
        return map.map { NSNumber(value: $0) }
    }

    private func makeChannelMapConverter() async throws -> AVAudioUnit {
        let description = AudioComponentDescription(
            componentType: kAudioUnitType_FormatConverter,
            componentSubType: kAudioUnitSubType_AUConverter,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        return try await AVAudioUnit.instantiate(with: description, options: [])
    }

    private func configureAudioEngineIfNeeded() {
        guard audioOutputFormat == nil else { return }
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        let outputNode = audioEngine.outputNode
        applyAudioOutputDevice()

        let outputNodeFormat = outputNode.inputFormat(forBus: 0)
        if outputNodeFormat.channelCount > 0 {
            audioOutputSampleRate = outputNodeFormat.sampleRate
        }

        let desiredChannelCount = max(audioOutputChannelCount, Int(outputNodeFormat.channelCount))
        if desiredChannelCount > Int(outputNodeFormat.channelCount) {
            audioOutputChannelCount = desiredChannelCount
            audioOutputFormat = makeOutputFormat()
        } else if outputNodeFormat.channelCount > 0 {
            audioOutputChannelCount = Int(outputNodeFormat.channelCount)
            audioOutputFormat = outputNodeFormat
        } else {
            audioOutputFormat = makeOutputFormat()
        }
        audioEngine.disconnectNodeOutput(audioEngine.mainMixerNode)
        audioEngine.connect(audioEngine.mainMixerNode, to: outputNode, format: audioOutputFormat)
    }

    private func ensureAudioEngineRunning() {
        configureAudioEngineIfNeeded()
        guard !audioEngine.isRunning else { return }

        do {
            try audioEngine.start()
            applyAudioOutputDevice()
            synchronizeOutputFormatIfNeeded()
        } catch {
            NSLog(">>> PlaybackEngine: Failed to start audio engine: \(error)")
        }
    }

    private func synchronizeOutputFormatIfNeeded() {
        guard audioPlayers.isEmpty else { return }
        let nodeFormat = audioEngine.outputNode.inputFormat(forBus: 0)
        guard nodeFormat.channelCount > 0 else { return }

        let needsUpdate = audioOutputFormat?.channelCount != nodeFormat.channelCount
            || audioOutputFormat?.sampleRate != nodeFormat.sampleRate
        guard needsUpdate else { return }

        audioEngine.stop()
        audioEngine.disconnectNodeOutput(audioEngine.mainMixerNode)
        audioOutputChannelCount = Int(nodeFormat.channelCount)
        audioOutputSampleRate = nodeFormat.sampleRate
        audioOutputFormat = nodeFormat
        audioEngine.connect(audioEngine.mainMixerNode, to: audioEngine.outputNode, format: nodeFormat)

        do {
            try audioEngine.start()
            applyAudioOutputDevice()
        } catch {
            NSLog(">>> PlaybackEngine: Failed to restart audio engine: \(error)")
        }
    }

    private func applyAudioOutputDevice() {
        guard let deviceID = audioOutputDeviceID else { return }
        guard let audioUnit = audioEngine.outputNode.audioUnit else { return }
        var outputDeviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &outputDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            NSLog(">>> PlaybackEngine: Failed to set output device: \(status)")
        }
    }

    private func makeOutputFormat() -> AVAudioFormat {
        let channels = max(1, audioOutputChannelCount)
        let sampleRate = max(8000, audioOutputSampleRate)
        return AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels))
            ?? AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    }

    private func updateAudioOutputDeviceSettings() {
        if let uid = audioOutputDeviceUID, let deviceID = deviceID(for: uid) {
            audioOutputDeviceID = deviceID
        } else {
            audioOutputDeviceID = defaultOutputDeviceID()
        }

        if let deviceID = audioOutputDeviceID {
            audioOutputChannelCount = max(1, outputChannelCount(for: deviceID))
            audioOutputSampleRate = outputSampleRate(for: deviceID) ?? audioOutputSampleRate
        } else {
            audioOutputChannelCount = 2
            audioOutputSampleRate = 48000
        }
    }

    private func reconfigureAudioEngineForOutputChange() {
        let wasPlaying = isPlaying
        stopAllAudioClips()
        audioEngine.stop()
        audioEngine.reset()
        audioOutputFormat = nil

        for id in Array(audioPlayers.keys) {
            removeAudioPlayback(id: id)
        }

        if wasPlaying {
            startActiveAudioClips()
        }
    }

    private static func extractAudioToTemporaryFile(for clip: AudioClip, key: AudioExtractionKey) async throws -> URL {
        let asset = AVAsset(url: clip.sourceURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard key.trackIndex < audioTracks.count else {
            throw PlaybackEngineError.noAudioTrack
        }

        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw PlaybackEngineError.audioExtractionFailed
        }

        let track = audioTracks[key.trackIndex]
        let duration = try await asset.load(.duration)
        try compositionTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: duration),
            of: track,
            at: .zero
        )

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw PlaybackEngineError.audioExtractionFailed
        }

        // Use a deterministic filename based on source URL and track index
        let keyHash = "\(key.url.absoluteString)-track\(key.trackIndex)".hashValue
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("projector-audio-\(abs(keyHash)).m4a")

        // Remove existing file if present
        if FileManager.default.fileExists(atPath: tempURL.path) {
            try FileManager.default.removeItem(at: tempURL)
        }

        if #available(macOS 15.0, *) {
            try await export.export(to: tempURL, as: .m4a)
        } else {
            export.outputURL = tempURL
            export.outputFileType = .m4a
            try await exportAudioLegacy(export)
        }

        return tempURL
    }

    private static func exportAudioLegacy(_ export: AVAssetExportSession) async throws {
        let box = ExportSessionBox(session: export)
        try await withCheckedThrowingContinuation { continuation in
            box.session.exportAsynchronously {
                switch box.session.status {
                case .completed:
                    continuation.resume(returning: ())
                case .failed:
                    continuation.resume(throwing: box.session.error ?? PlaybackEngineError.audioExtractionFailed)
                case .cancelled:
                    continuation.resume(throwing: PlaybackEngineError.audioExtractionFailed)
                case .unknown, .waiting, .exporting:
                    continuation.resume(throwing: PlaybackEngineError.audioExtractionFailed)
                @unknown default:
                    continuation.resume(throwing: PlaybackEngineError.audioExtractionFailed)
                }
            }
        }
    }

    private func deviceID(for uid: String) -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var propertySize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize
        )

        guard status == noErr, propertySize > 0 else { return nil }

        let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = Array(repeating: AudioDeviceID(0), count: deviceCount)

        let fetchStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &deviceIDs
        )

        guard fetchStatus == noErr else { return nil }

        for deviceID in deviceIDs {
            if uid == deviceUID(for: deviceID) {
                return deviceID
            }
        }
        return nil
    }

    private func deviceUID(for deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var propertySize = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
        var uid: Unmanaged<CFString>?
        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &propertySize, &uid)
        guard status == noErr, let uidValue = uid?.takeRetainedValue() else { return nil }
        return uidValue as String
    }

    private func defaultOutputDeviceID() -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &deviceID
        )
        return status == noErr ? deviceID : nil
    }

    private func outputChannelCount(for deviceID: AudioDeviceID) -> Int {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var propertySize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &propertySize)
        guard status == noErr, propertySize > 0 else { return 0 }

        let bufferListPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(propertySize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferListPointer.deallocate() }

        let result = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &propertySize, bufferListPointer)
        guard result == noErr else { return 0 }

        let audioBufferList = bufferListPointer.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private func outputSampleRate(for deviceID: AudioDeviceID) -> Double? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate = Float64(0)
        var propertySize = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &propertySize, &sampleRate)
        return status == noErr ? sampleRate : nil
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

            if wasPlaying, self.isPlaying {
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
    case noAudioTrack
    case audioExtractionFailed
    case audioUnitInstantiationFailed

    var errorDescription: String? {
        switch self {
        case .notPlayable:
            return "The video file cannot be played."
        case .reelNotFound:
            return "The video reel could not be found."
        case .seekFailed:
            return "Failed to seek to the specified position."
        case .noAudioTrack:
            return "No audio track was found."
        case .audioExtractionFailed:
            return "Failed to extract audio from the source."
        case .audioUnitInstantiationFailed:
            return "Failed to create audio routing unit."
        }
    }
}
