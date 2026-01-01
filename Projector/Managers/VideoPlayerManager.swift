import Foundation
import AVFoundation
import Combine
import SwiftTimecodeCore

/// Manages video playback with frame-accurate seeking and timecode tracking
@MainActor
final class VideoPlayerManager: ObservableObject {
    // MARK: - Published Properties

    @Published private(set) var player: AVPlayer?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var currentTimecode: Timecode
    @Published private(set) var frameRate: TimecodeFrameRate = .fps24
    @Published private(set) var hasVideo = false
    @Published private(set) var videoTitle: String = ""

    /// Timecode offset (start TC of the video)
    @Published var timecodeOffset: Timecode

    // MARK: - Private Properties

    private var timeObserver: Any?
    private var playerItemObserver: AnyCancellable?
    private var statusObserver: AnyCancellable?
    private var asset: AVAsset?

    // MARK: - Initialization

    init() {
        // Initialize with zero timecode at default frame rate
        self.currentTimecode = Timecode(.components(h: 0, m: 0, s: 0, f: 0), at: .fps24, by: .clamping)
        self.timecodeOffset = Timecode(.components(h: 0, m: 0, s: 0, f: 0), at: .fps24, by: .clamping)
    }

    // MARK: - Public Methods

    /// Load a video file from URL
    func loadVideo(from url: URL) async throws {
        // Clean up previous player
        removeTimeObserver()
        player?.pause()

        // Create asset and load properties
        let asset = AVAsset(url: url)
        self.asset = asset

        // Load required properties asynchronously
        let isPlayable = try await asset.load(.isPlayable)
        guard isPlayable else {
            throw VideoPlayerError.notPlayable
        }

        // Load tracks to detect frame rate
        let tracks = try await asset.load(.tracks)
        if let videoTrack = tracks.first(where: { $0.mediaType == .video }) {
            let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
            self.frameRate = TimecodeFrameRate.detect(from: nominalFrameRate)
        }

        // Load duration
        let durationTime = try await asset.load(.duration)
        self.duration = CMTimeGetSeconds(durationTime)

        // Create player
        let playerItem = AVPlayerItem(asset: asset)
        let newPlayer = AVPlayer(playerItem: playerItem)

        // Disable automatic waiting to minimize latency
        newPlayer.automaticallyWaitsToMinimizeStalling = false

        self.player = newPlayer
        self.hasVideo = true
        self.videoTitle = url.deletingPathExtension().lastPathComponent
        self.currentTime = 0

        // Try to read embedded timecode from video file (multiple methods)
        var startTimecode: Timecode?

        // Method 1: Check for dedicated timecode track
        if let timecodeTrack = tracks.first(where: { $0.mediaType == .timecode }) {
            startTimecode = await readEmbeddedTimecode(from: timecodeTrack, asset: asset)
        }

        // Method 2: Check QuickTime/ProRes metadata for start timecode
        if startTimecode == nil {
            startTimecode = await readTimecodeFromMetadata(asset: asset)
        }

        // Use embedded timecode if found, otherwise start at 00:00:00:00
        if let tc = startTimecode {
            self.timecodeOffset = tc
            print("Using embedded timecode: \(tc.stringValue())")
        } else {
            self.timecodeOffset = Timecode(.components(h: 0, m: 0, s: 0, f: 0), at: frameRate, by: .clamping)
            print("No embedded timecode found, starting at 00:00:00:00")
        }
        self.currentTimecode = timecodeOffset

        // Setup time observer for timecode updates
        setupTimeObserver()

        // Observe player status
        observePlayerStatus()
    }

    /// Read timecode from asset metadata (QuickTime, ProRes, etc.)
    private func readTimecodeFromMetadata(asset: AVAsset) async -> Timecode? {
        do {
            // Load all metadata
            let metadata = try await asset.load(.metadata)

            // Check for QuickTime timecode metadata
            for item in metadata {
                // Look for timecode-related keys
                if let key = item.key as? String {
                    print("Metadata key: \(key)")
                }

                // Check for common timecode identifiers
                if let identifier = item.identifier {
                    let idString = identifier.rawValue

                    // QuickTime timecode metadata
                    if idString.contains("timecode") || idString.contains("mdta") {
                        if let value = try? await item.load(.value) {
                            print("Found timecode metadata: \(idString) = \(value)")

                            // Try to parse as timecode string
                            if let tcString = value as? String,
                               let tc = try? Timecode(.string(tcString), at: frameRate) {
                                return tc
                            }

                            // Try to parse as frame number
                            if let frameNum = value as? Int,
                               let tc = try? Timecode(.frames(frameNum), at: frameRate) {
                                return tc
                            }
                        }
                    }
                }
            }

            // Also check format descriptions for video track
            let tracks = try await asset.load(.tracks)
            if let videoTrack = tracks.first(where: { $0.mediaType == .video }) {
                let formatDescriptions = try await videoTrack.load(.formatDescriptions)

                for formatDesc in formatDescriptions {
                    // Check for timecode in format description extensions
                    if let extensions = CMFormatDescriptionGetExtensions(formatDesc) as? [String: Any] {
                        print("Format extensions: \(extensions.keys)")

                        // Look for start timecode in extensions
                        if let tcInfo = extensions["com.apple.quicktime.timecode"] as? [String: Any],
                           let startTC = tcInfo["startTimecode"] as? Int {
                            if let tc = try? Timecode(.frames(startTC), at: frameRate) {
                                print("Found timecode in format extensions: \(tc.stringValue())")
                                return tc
                            }
                        }
                    }
                }
            }

        } catch {
            print("Failed to read metadata: \(error)")
        }

        return nil
    }

    /// Read embedded timecode from a timecode track
    private func readEmbeddedTimecode(from track: AVAssetTrack, asset: AVAsset) async -> Timecode? {
        do {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(output)

            guard reader.startReading() else { return nil }

            // Read the first timecode sample
            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                reader.cancelReading()
                return nil
            }

            // Verify we have a format description
            guard CMSampleBufferGetFormatDescription(sampleBuffer) != nil else {
                reader.cancelReading()
                return nil
            }

            // Extract timecode from sample data
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                reader.cancelReading()
                return nil
            }

            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &length,
                dataPointerOut: &dataPointer
            )

            guard let data = dataPointer, length >= 4 else {
                reader.cancelReading()
                return nil
            }

            // Read frame number from timecode sample (big-endian 32-bit integer)
            let frameNumber = data.withMemoryRebound(to: UInt32.self, capacity: 1) {
                Int(CFSwapInt32BigToHost($0.pointee))
            }

            reader.cancelReading()

            // Convert frame number to Timecode
            if let timecode = try? Timecode(.frames(frameNumber), at: frameRate) {
                print("Embedded timecode found: \(timecode.stringValue())")
                return timecode
            }
        } catch {
            print("Failed to read embedded timecode: \(error)")
        }

        return nil
    }

    /// Play the video
    func play() {
        player?.play()
        isPlaying = true
    }

    /// Pause the video
    func pause() {
        player?.pause()
        isPlaying = false
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
        seek(to: timecodeOffset)
    }

    /// Seek to a specific timecode
    func seek(to timecode: Timecode) {
        // Calculate the difference in frames between target and offset
        let targetFrames = timecode.frameCount.wholeFrames
        let offsetFrames = timecodeOffset.frameCount.wholeFrames
        let frameOffset = targetFrames - offsetFrames

        // Convert frames to seconds
        let targetSeconds = Double(max(0, frameOffset)) / frameRate.fps
        seek(toSeconds: targetSeconds)
    }

    /// Seek to a specific time in seconds with frame accuracy
    func seek(toSeconds seconds: Double) {
        guard let player = player else { return }

        let targetTime = CMTime(seconds: max(0, min(seconds, duration)), preferredTimescale: 600)

        // Frame-accurate seeking with zero tolerance
        player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] completed in
            if completed {
                Task { @MainActor in
                    self?.updateCurrentTime()
                }
            }
        }
    }

    /// Seek to a specific frame number (relative to video start)
    func seek(toFrame frame: Int) {
        let seconds = Double(frame) / frameRate.fps
        seek(toSeconds: seconds)
    }

    /// Step forward by one frame
    func stepForward() {
        guard let player = player else { return }
        player.currentItem?.step(byCount: 1)
        updateCurrentTime()
    }

    /// Step backward by one frame
    func stepBackward() {
        guard let player = player else { return }
        player.currentItem?.step(byCount: -1)
        updateCurrentTime()
    }

    /// Set the audio output device
    func setAudioOutputDevice(_ deviceUID: String?) {
        player?.audioOutputDeviceUniqueID = deviceUID
    }

    /// Set mute state for a specific audio track
    func setTrackMuted(_ trackIndex: Int, muted: Bool) {
        guard let playerItem = player?.currentItem,
              let asset = asset else { return }

        Task {
            do {
                let tracks = try await asset.load(.tracks)
                let audioTracks = tracks.filter { $0.mediaType == .audio }

                // Build audio mix with current mute states
                let audioMix = AVMutableAudioMix()
                var inputParameters: [AVMutableAudioMixInputParameters] = []

                for (index, track) in audioTracks.enumerated() {
                    let params = AVMutableAudioMixInputParameters(track: track)

                    if index == trackIndex {
                        // Set volume based on mute state
                        params.setVolume(muted ? 0.0 : 1.0, at: .zero)
                    }

                    inputParameters.append(params)
                }

                audioMix.inputParameters = inputParameters
                playerItem.audioMix = audioMix
            } catch {
                print("Failed to set track mute state: \(error)")
            }
        }
    }

    /// Update audio mix with multiple track mute states
    func updateAudioMix(mutedTracks: Set<Int>) {
        guard let playerItem = player?.currentItem,
              let asset = asset else { return }

        Task {
            do {
                let tracks = try await asset.load(.tracks)
                let audioTracks = tracks.filter { $0.mediaType == .audio }

                let audioMix = AVMutableAudioMix()
                var inputParameters: [AVMutableAudioMixInputParameters] = []

                for (index, track) in audioTracks.enumerated() {
                    let params = AVMutableAudioMixInputParameters(track: track)
                    let isMuted = mutedTracks.contains(index)
                    params.setVolume(isMuted ? 0.0 : 1.0, at: .zero)
                    inputParameters.append(params)
                }

                audioMix.inputParameters = inputParameters
                playerItem.audioMix = audioMix
            } catch {
                print("Failed to update audio mix: \(error)")
            }
        }
    }

    /// Get the timecode offset in seconds
    var timecodeOffsetSeconds: Double {
        Double(timecodeOffset.frameCount.wholeFrames) / frameRate.fps
    }

    /// Adjust the timecode offset by a given number of seconds
    func adjustTimecodeOffset(by seconds: Double) {
        let currentFrames = timecodeOffset.frameCount.wholeFrames
        let adjustmentFrames = Int(seconds * frameRate.fps)
        let newFrames = currentFrames + adjustmentFrames

        if let newOffset = try? Timecode(.frames(max(0, newFrames)), at: frameRate) {
            timecodeOffset = newOffset
            updateTimecode()
        }
    }

    /// Set the timecode offset directly
    func setTimecodeOffset(_ timecode: Timecode) {
        timecodeOffset = timecode
        updateTimecode()
    }

    /// Seek to timecode received from MTC
    func seekToMTC(_ timecode: Timecode) {
        // Only seek if the timecode is within our video range
        let offsetSeconds = timecodeToSeconds(timecode)
        if offsetSeconds >= 0 && offsetSeconds <= duration {
            seek(toSeconds: offsetSeconds)
        }
    }

    /// Convert a timecode to seconds relative to video start
    func timecodeToSeconds(_ timecode: Timecode) -> Double {
        let targetFrames = timecode.frameCount.wholeFrames
        let offsetFrames = timecodeOffset.frameCount.wholeFrames
        let frameOffset = targetFrames - offsetFrames
        return Double(frameOffset) / frameRate.fps
    }

    // MARK: - Private Methods

    private func setupTimeObserver() {
        guard let player = player else { return }

        // Update at approximately frame rate (every ~41ms for 24fps)
        let interval = CMTime(seconds: 1.0 / 24.0, preferredTimescale: 600)

        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                self?.handleTimeUpdate(time)
            }
        }
    }

    private func removeTimeObserver() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
    }

    private func handleTimeUpdate(_ time: CMTime) {
        currentTime = CMTimeGetSeconds(time)
        updateTimecode()
    }

    private func updateCurrentTime() {
        guard let player = player else { return }
        currentTime = CMTimeGetSeconds(player.currentTime())
        updateTimecode()
    }

    private func updateTimecode() {
        // Calculate current frame from elapsed time
        let currentFrame = Int(currentTime * frameRate.fps)

        // Add current frame to offset timecode
        if let newTimecode = try? Timecode(
            .frames(timecodeOffset.frameCount.wholeFrames + currentFrame),
            at: frameRate
        ) {
            currentTimecode = newTimecode
        }
    }

    private func observePlayerStatus() {
        guard let player = player else { return }

        statusObserver = player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.isPlaying = (status == .playing)
            }
    }
}

// MARK: - TimecodeFrameRate Extension

extension TimecodeFrameRate {
    /// Returns the frames per second as a Double
    var fps: Double {
        switch self {
        case .fps23_976: return 24000.0 / 1001.0
        case .fps24: return 24.0
        case .fps24_98: return 25000.0 / 1001.0
        case .fps25: return 25.0
        case .fps29_97: return 30000.0 / 1001.0
        case .fps29_97d: return 30000.0 / 1001.0
        case .fps30: return 30.0
        case .fps30d: return 30.0
        case .fps47_952: return 48000.0 / 1001.0
        case .fps48: return 48.0
        case .fps50: return 50.0
        case .fps59_94: return 60000.0 / 1001.0
        case .fps59_94d: return 60000.0 / 1001.0
        case .fps60: return 60.0
        case .fps60d: return 60.0
        case .fps90: return 90.0
        case .fps95_904: return 96000.0 / 1001.0
        case .fps96: return 96.0
        case .fps100: return 100.0
        case .fps119_88: return 120000.0 / 1001.0
        case .fps119_88d: return 120000.0 / 1001.0
        case .fps120: return 120.0
        case .fps120d: return 120.0
        @unknown default: return 24.0
        }
    }

    /// A display name for the frame rate
    var displayName: String {
        switch self {
        case .fps23_976: return "23.976"
        case .fps24: return "24"
        case .fps24_98: return "24.98"
        case .fps25: return "25"
        case .fps29_97: return "29.97"
        case .fps29_97d: return "29.97 DF"
        case .fps30: return "30"
        case .fps30d: return "30 DF"
        case .fps47_952: return "47.952"
        case .fps48: return "48"
        case .fps50: return "50"
        case .fps59_94: return "59.94"
        case .fps59_94d: return "59.94 DF"
        case .fps60: return "60"
        case .fps60d: return "60 DF"
        case .fps90: return "90"
        case .fps95_904: return "95.904"
        case .fps96: return "96"
        case .fps100: return "100"
        case .fps119_88: return "119.88"
        case .fps119_88d: return "119.88 DF"
        case .fps120: return "120"
        case .fps120d: return "120 DF"
        @unknown default: return "Unknown"
        }
    }

    /// Detect frame rate from nominal FPS value
    static func detect(from nominalFPS: Float) -> TimecodeFrameRate {
        let fps = Double(nominalFPS)

        // Match to nearest standard frame rate
        switch fps {
        case 23.0...24.0:
            // Check if it's 23.976 or 24
            return abs(fps - 23.976) < abs(fps - 24.0) ? .fps23_976 : .fps24
        case 24.5...25.5:
            return .fps25
        case 29.0...30.5:
            // Could be 29.97 or 30
            return abs(fps - 29.97) < abs(fps - 30.0) ? .fps29_97 : .fps30
        case 47.0...48.5:
            return abs(fps - 47.952) < abs(fps - 48.0) ? .fps47_952 : .fps48
        case 49.0...50.5:
            return .fps50
        case 59.0...60.5:
            return abs(fps - 59.94) < abs(fps - 60.0) ? .fps59_94 : .fps60
        default:
            return .fps24
        }
    }
}

// MARK: - Errors

enum VideoPlayerError: LocalizedError {
    case notPlayable
    case loadFailed

    var errorDescription: String? {
        switch self {
        case .notPlayable:
            return "The video file cannot be played."
        case .loadFailed:
            return "Failed to load the video file."
        }
    }
}
