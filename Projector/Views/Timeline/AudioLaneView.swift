import SwiftUI
import UniformTypeIdentifiers
import Iconoir

/// Audio lane container showing clips and lane controls
struct AudioLaneView: View {
    let lane: AudioLane
    let laneIndex: Int
    let activeClipIds: Set<UUID>
    let waveformCache: WaveformCache
    let pixelsPerFrame: CGFloat
    let scrollOffset: CGFloat
    let availableAudioDevices: [AudioDevice]
    let onMuteToggle: () -> Void
    let onSoloToggle: () -> Void
    let onVolumeChange: (Float) -> Void
    let onOutputDeviceChange: (String?) -> Void
    let onDropMedia: ([URL]) -> Void
    let onClipSelected: (UUID?) -> Void
    let onClipDoubleClick: (AudioClip) -> Void

    @State private var selectedClipId: UUID?
    @State private var isDropTargeted = false
    @State private var isExpanded = true

    /// Track header width - wider to accommodate output selector
    private let headerWidth: CGFloat = 120
    /// Track height for audio clips
    private let trackHeight: CGFloat = 60

    var body: some View {
        HStack(spacing: 0) {
            // Lane header
            laneHeader

            // Clips area
            clipsArea
        }
        .frame(height: trackHeight)
        .background(laneBackground)
    }

    // MARK: - Lane Background

    private var laneBackground: some View {
        Color(nsColor: .controlBackgroundColor)
            .opacity(lane.isMuted ? 0.7 : 1.0)
    }

    // MARK: - Lane Header

    private var laneHeader: some View {
        Color.clear
            .frame(width: headerWidth, height: trackHeight)
            .overlay(
                VStack(spacing: 4) {
                    // Lane name
                    Text(lane.name)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    // Output device dropdown (compact)
                    outputDevicePicker

                    // Mute/Solo controls
                    HStack(spacing: 6) {
                        Button(action: onMuteToggle) {
                            Text("M")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(lane.isMuted ? .red : .secondary)
                        }
                        .buttonStyle(.plain)

                        Button(action: onSoloToggle) {
                            Text("S")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(lane.isSolo ? .yellow : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 6)
            )
    }

    private var outputDevicePicker: some View {
        Menu {
            Button("System Default") {
                onOutputDeviceChange(nil)
            }
            Divider()
            ForEach(availableAudioDevices) { device in
                Button(device.name) {
                    onOutputDeviceChange(device.uid)
                }
            }
        } label: {
            Text(outputDeviceName)
                .font(.system(size: 8))
                .lineLimit(1)
                .foregroundColor(.secondary)
                .frame(maxWidth: 100)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    /// Get display name for current output device
    private var outputDeviceName: String {
        if let uid = lane.outputDeviceUID,
           let device = availableAudioDevices.first(where: { $0.uid == uid }) {
            // Truncate long names
            let name = device.name
            return name.count > 12 ? String(name.prefix(10)) + "…" : name
        }
        return "Default"
    }

    // MARK: - Clips Area

    private var clipsArea: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background with drop zone
                dropZoneBackground

                // Clips
                clipsContent(in: geometry)

                // Drop target overlay
                if isDropTargeted {
                    dropTargetOverlay
                }
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    private var dropZoneBackground: some View {
        DustyBackground()
            .overlay(
                Group {
                    if lane.clips.isEmpty {
                        emptyDropPrompt
                    }
                }
            )
    }

    private var emptyDropPrompt: some View {
        HStack(spacing: 4) {
            Iconoir.musicDoubleNote.asImage
                .frame(width: 14, height: 14)
                .foregroundColor(.secondary.opacity(0.5))

            Text("Drop audio files")
                .font(.system(size: 9))
                .foregroundColor(.secondary.opacity(0.5))
        }
    }

    private var dropTargetOverlay: some View {
        RoundedRectangle(cornerRadius: 4)
            .stroke(laneColor, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
            .background(laneColor.opacity(0.1))
            .padding(2)
    }

    @ViewBuilder
    private func clipsContent(in geometry: GeometryProxy) -> some View {
        ForEach(lane.clips) { clip in
            let xOffset = CGFloat(clip.timelineStartFrame) * pixelsPerFrame - scrollOffset

            AudioClipView(
                clip: clip,
                lane: lane,
                isActive: activeClipIds.contains(clip.id),
                pixelsPerFrame: pixelsPerFrame,
                waveformData: waveformCache.waveform(for: clip),
                isSelected: selectedClipId == clip.id,
                onSelect: {
                    selectedClipId = clip.id
                    onClipSelected(clip.id)
                },
                onDoubleClick: {
                    onClipDoubleClick(clip)
                }
            )
            .offset(x: xOffset)
        }
    }

    private var channelCount: Int {
        // Assume stereo for now; could be derived from clips
        2
    }

    private var laneColor: Color {
        let colors: [Color] = [
            .blue, .green, .orange, .purple, .pink, .cyan, .mint, .indigo
        ]
        return colors[laneIndex % colors.count]
    }

    // MARK: - Drop Handling

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var urls: [URL] = []

        let group = DispatchGroup()

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                defer { group.leave() }

                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    urls.append(url)
                } else if let url = item as? URL {
                    urls.append(url)
                }
            }
        }

        group.notify(queue: .main) {
            let mediaURLs = urls.filter { isMediaFile($0) }
            if !mediaURLs.isEmpty {
                onDropMedia(mediaURLs)
            }
        }

        return true
    }

    private func isMediaFile(_ url: URL) -> Bool {
        let videoExtensions = ["mov", "mp4", "m4v", "avi", "mkv", "mxf"]
        let audioExtensions = ["wav", "aif", "aiff", "mp3", "m4a", "flac", "ogg"]
        let ext = url.pathExtension.lowercased()
        return videoExtensions.contains(ext) || audioExtensions.contains(ext)
    }
}

#Preview {
    struct PreviewWrapper: View {
        @StateObject var waveformCache = WaveformCache()

        var lane: AudioLane {
            var l = AudioLane(name: "Audio 1")
            l.clips = [
                AudioClip(
                    sourceURL: URL(fileURLWithPath: "/audio1.wav"),
                    timelineStartFrame: 0,
                    durationFrames: 2400,
                    sourceStartFrame: 0,
                    sourceType: .audioFile
                ),
                AudioClip(
                    sourceURL: URL(fileURLWithPath: "/audio2.wav"),
                    timelineStartFrame: 3000,
                    durationFrames: 1800,
                    sourceStartFrame: 0,
                    sourceType: .audioFile
                )
            ]
            return l
        }

        var body: some View {
            AudioLaneView(
                lane: lane,
                laneIndex: 0,
                activeClipIds: Set([lane.clips.first!.id]),
                waveformCache: waveformCache,
                pixelsPerFrame: 0.5,
                scrollOffset: 0,
                availableAudioDevices: [],
                onMuteToggle: {},
                onSoloToggle: {},
                onVolumeChange: { _ in },
                onOutputDeviceChange: { _ in },
                onDropMedia: { _ in },
                onClipSelected: { _ in },
                onClipDoubleClick: { _ in }
            )
            .frame(width: 800)
            .background(Color(white: 0.15))
        }
    }

    return PreviewWrapper()
}
