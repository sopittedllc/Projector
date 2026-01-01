import Foundation

/// Represents an individual audio track from a video file
struct AudioTrackInfo: Identifiable, Hashable {
    let id: UUID
    let trackIndex: Int
    let name: String
    let channelCount: Int
    let sampleRate: Double
    let duration: Double

    /// Output device UID for routing (nil = follows global device)
    var outputDeviceUID: String?

    /// Starting channel on the output device (0-indexed)
    var outputChannelOffset: Int

    /// Whether this track is muted
    var isMuted: Bool

    init(
        id: UUID = UUID(),
        trackIndex: Int,
        name: String,
        channelCount: Int,
        sampleRate: Double = 48000,
        duration: Double = 0,
        outputDeviceUID: String? = nil,
        outputChannelOffset: Int = 0,
        isMuted: Bool = false
    ) {
        self.id = id
        self.trackIndex = trackIndex
        self.name = name
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        self.duration = duration
        self.outputDeviceUID = outputDeviceUID
        self.outputChannelOffset = outputChannelOffset
        self.isMuted = isMuted
    }

    /// Display name for the track
    var displayName: String {
        if name.isEmpty {
            return "Audio \(trackIndex + 1)"
        }
        return name
    }

    /// Channel layout description (e.g., "Stereo", "5.1", "Mono")
    var channelLayoutName: String {
        switch channelCount {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(channelCount) ch"
        }
    }
}
