import SwiftUI
import Iconoir

/// Individual audio track row with waveform visualization
struct AudioTrackWaveformView: View {
    let track: AudioTrackInfo
    let waveformData: WaveformData?
    let currentTime: Double
    let duration: Double
    let onMuteTap: () -> Void
    let onRoutingTap: () -> Void

    /// Track header/footer width - must match TimelineView
    private let headerWidth: CGFloat = 120

    var body: some View {
        HStack(spacing: 0) {
            // Track header (left side)
            trackHeader
                .frame(width: headerWidth)

            Divider()

            // Waveform area (center)
            waveformArea

            Divider()

            // Track footer (right side) - mirrors left side width
            trackFooter
                .frame(width: headerWidth)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Track Header

    private var trackHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                // Track name
                Text(track.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .foregroundColor(.primary)

                Spacer()

                // Mute button
                Button(action: onMuteTap) {
                    (track.isMuted ? Iconoir.soundOff.asImage : Iconoir.soundHigh.asImage)
                        .frame(width: 14, height: 14)
                        .foregroundColor(track.isMuted ? .red : .secondary)
                }
                .buttonStyle(.plain)
                .help(track.isMuted ? "Unmute track" : "Mute track")
            }

            // Channel layout
            Text(track.channelLayoutName)
                .font(.system(size: 10))
                .foregroundColor(.secondary)

            Spacer()

            // Output routing
            VStack(alignment: .leading, spacing: 2) {
                Text("Audio Destination")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)

                Button(action: onRoutingTap) {
                    HStack(spacing: 4) {
                        Text(outputLabel)
                            .font(.system(size: 9))
                        Iconoir.navArrowDown.asImage
                            .frame(width: 10, height: 10)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
    }

    private var outputLabel: String {
        let start = track.outputChannelOffset + 1
        let end = start + track.channelCount - 1
        if start == end {
            return "Ch \(start)"
        }
        return "Ch \(start)-\(end)"
    }

    // MARK: - Waveform Area

    private var waveformArea: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background
                Rectangle()
                    .fill(Color.black.opacity(0.05))

                // Waveform
                if let data = waveformData, !data.samples.isEmpty {
                    WaveformShape(samples: data.samples)
                        .stroke(trackColor, lineWidth: 1)
                } else {
                    // Loading or no waveform placeholder
                    waveformPlaceholder
                }

                // Playhead line
                playheadLine(in: geometry)
            }
        }
    }

    private var waveformPlaceholder: some View {
        HStack {
            Spacer()
            if waveformData == nil {
                ProgressView()
                    .scaleEffect(0.6)
                Text("Generating waveform...")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else {
                Text("No audio data")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }

    private func playheadLine(in geometry: GeometryProxy) -> some View {
        let offset: CGFloat
        if duration > 0 {
            offset = CGFloat(currentTime / duration) * geometry.size.width
        } else {
            offset = 0
        }

        return Rectangle()
            .fill(Color.accentColor)
            .frame(width: 1)
            .offset(x: offset)
    }

    private var trackColor: Color {
        // Assign different colors to different tracks
        let colors: [Color] = [
            .blue,
            .green,
            .orange,
            .purple,
            .pink,
            .cyan,
            .mint,
            .indigo
        ]
        return colors[track.trackIndex % colors.count]
    }

    // MARK: - Track Footer

    private var trackFooter: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Spacer()


            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
    }
}

#Preview {
    VStack(spacing: 0) {
        AudioTrackWaveformView(
            track: AudioTrackInfo(
                trackIndex: 0,
                name: "Audio 1",
                channelCount: 2
            ),
            waveformData: WaveformData(
                trackIndex: 0,
                samples: (0..<500).map { _ in Float.random(in: 0...0.8) },
                duration: 120
            ),
            currentTime: 30,
            duration: 120,
            onMuteTap: {},
            onRoutingTap: {}
        )
        .frame(height: 60)

        Divider()

        AudioTrackWaveformView(
            track: AudioTrackInfo(
                trackIndex: 1,
                name: "Audio 2",
                channelCount: 2,
                outputChannelOffset: 2,
                isMuted: true
            ),
            waveformData: nil,
            currentTime: 30,
            duration: 120,
            onMuteTap: {},
            onRoutingTap: {}
        )
        .frame(height: 60)
    }
    .frame(width: 600)
}
