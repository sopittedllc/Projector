import SwiftUI
import SwiftTimecodeCore

/// Main timeline container with scrubber and waveform visualization
struct TimelineView: View {
    @ObservedObject var playerManager: VideoPlayerManager
    @ObservedObject var waveformGenerator: WaveformGenerator
    @Binding var audioTracks: [AudioTrackInfo]
    let onTrackMuteChanged: (Int, Bool) -> Void

    @State private var isDragging = false
    @State private var isExpanded = true

    /// Minimum height when collapsed
    private let collapsedHeight: CGFloat = 40
    /// Height per waveform track
    private let trackHeight: CGFloat = 80
    /// Track header width - must match AudioTrackWaveformView
    private let trackHeaderWidth: CGFloat = 120

    var body: some View {
        VStack(spacing: 0) {
            // Header with ruler and scrubber
            headerSection

            if isExpanded && playerManager.hasVideo {
                Divider()

                // Waveform tracks area
                waveformSection
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Header Section

    private var headerSection: some View {
        VStack(spacing: 4) {
            // Timeline ruler - aligned with waveform
            HStack(spacing: 0) {
                // Empty space to match track header
                Color.clear
                    .frame(width: trackHeaderWidth)

                // Ruler aligned with waveform area
                TimelineRulerView(
                    duration: playerManager.duration,
                    frameRate: playerManager.frameRate,
                    currentTime: playerManager.currentTime
                )

                // Empty space to match track footer
                Color.clear
                    .frame(width: trackHeaderWidth)
            }
            .padding(.top, 8)

            // Scrubber bar - aligned with waveform
            HStack(spacing: 0) {
                // Current timecode in header area
                Text(playerManager.currentTimecode.stringValue())
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.primary)
                    .frame(width: trackHeaderWidth, alignment: .leading)
                    .padding(.leading, 8)

                // Scrubber aligned with waveform area
                ScrubberView(
                    playerManager: playerManager,
                    isDragging: $isDragging
                )

                // End timecode in footer area
                Text(formatDuration())
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: trackHeaderWidth, alignment: .trailing)
                    .padding(.trailing, 8)
            }
            .padding(.bottom, 8)
        }
    }

    // MARK: - Waveform Section

    @ViewBuilder
    private var waveformSection: some View {
        if audioTracks.isEmpty {
            // No audio tracks placeholder
            VStack {
                Text("No audio tracks")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
            .frame(height: 60)
            .padding(.top, 8)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(audioTracks.enumerated()), id: \.element.id) { index, track in
                    AudioTrackWaveformView(
                        track: track,
                        waveformData: waveformGenerator.waveforms[track.trackIndex],
                        currentTime: playerManager.currentTime,
                        duration: playerManager.duration,
                        onMuteTap: {
                            let newMuteState = !track.isMuted
                            audioTracks[index].isMuted = newMuteState
                            onTrackMuteChanged(track.trackIndex, newMuteState)
                        },
                        onRoutingTap: {
                            // Handle routing tap - will be implemented in Sprint 4
                        }
                    )
                    .frame(height: trackHeight)

                    if track.id != audioTracks.last?.id {
                        Divider()
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    // MARK: - Helpers

    private func formatDuration() -> String {
        guard playerManager.duration > 0 else { return "00:00:00:00" }

        let frameCount = Int(playerManager.duration * playerManager.frameRate.fps)
        if let tc = try? Timecode(
            .frames(playerManager.timecodeOffset.frameCount.wholeFrames + frameCount),
            at: playerManager.frameRate
        ) {
            return tc.stringValue()
        }
        return "00:00:00:00"
    }
}

// MARK: - Timecode Extension

extension Timecode {
    /// Returns the timecode as a formatted string HH:MM:SS:FF
    func stringValue() -> String {
        let h = components.hours
        let m = components.minutes
        let s = components.seconds
        let f = components.frames

        return String(format: "%02d:%02d:%02d:%02d", h, m, s, f)
    }
}

#Preview {
    struct PreviewWrapper: View {
        @State var tracks: [AudioTrackInfo] = []

        var body: some View {
            TimelineView(
                playerManager: VideoPlayerManager(),
                waveformGenerator: WaveformGenerator(),
                audioTracks: $tracks,
                onTrackMuteChanged: { _, _ in }
            )
            .frame(height: 200)
        }
    }
    return PreviewWrapper()
}
