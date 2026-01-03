import SwiftUI
import UniformTypeIdentifiers
import SwiftTimecodeCore
import AVFoundation
import Iconoir

/// Audio lane container showing clips and lane controls
struct AudioLaneView: View {
    let lane: AudioLane
    let laneIndex: Int
    let activeClipIds: Set<UUID>
    let waveformCache: WaveformCache
    let pixelsPerFrame: CGFloat
    let frameRate: TimecodeFrameRate
    let scrollOffset: CGFloat
    let timelineDurationFrames: Int
    let showWaveforms: Bool
    let clipInteractionsEnabled: Bool
    let availableAudioDevices: [AudioDevice]
    let onMuteToggle: () -> Void
    let onSoloToggle: () -> Void
    let onVolumeChange: (Float) -> Void
    let onOutputDeviceChange: (String?) -> Void
    let onDropMedia: ([URL], Int, Bool) -> Void
    let onClipSelected: (UUID?) -> Void
    let onClipDoubleClick: (AudioClip) -> Void
    let onLaneRename: (String) -> Void

    @State private var selectedClipId: UUID?
    @State private var isDropTargeted = false
    @State private var dropPreviewFrame: Int?
    @State private var dropPreviewDurationFrames: Int?
    @State private var isLoadingDropPreview = false
    @State private var isExpanded = true
    @State private var isEditingName = false
    @State private var editedName = ""
    @FocusState private var isNameFieldFocused: Bool

    /// Track header width - wider to accommodate output selector
    private let headerWidth: CGFloat = 120  // TODO: Use TimelineLayout.headerWidth after adding to Xcode project
    /// Track height for audio clips
    private let trackHeight: CGFloat = 60  // TODO: Use TimelineLayout.audioLaneHeight after adding to Xcode project

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
                    // Lane name (editable on double-click)
                    if isEditingName {
                        TextField("", text: $editedName)
                            .font(.system(size: 10, weight: .medium))
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.center)
                            .focused($isNameFieldFocused)
                            .onSubmit {
                                commitNameEdit()
                            }
                            .onExitCommand {
                                cancelNameEdit()
                            }
                            .frame(maxWidth: headerWidth - 12)
                    } else {
                        // Use Button instead of onTapGesture to avoid ScrollView latency (GP-003)
                        Button(action: {}) {
                            Text(lane.name)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(
                            TapGesture(count: 2)
                                .onEnded { _ in
                                    startNameEdit()
                                }
                        )
                    }

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

    private func startNameEdit() {
        editedName = lane.name
        isEditingName = true
        // Delay focus to ensure TextField is rendered
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            isNameFieldFocused = true
        }
    }

    private func commitNameEdit() {
        let trimmed = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != lane.name {
            onLaneRename(trimmed)
        }
        isEditingName = false
    }

    private func cancelNameEdit() {
        isEditingName = false
    }

    private var outputDevicePicker: some View {
        Menu {
            Button {
                onOutputDeviceChange(nil)
            } label: {
                HStack {
                    Text("System Default")
                    if lane.outputDeviceUID == nil {
                        Spacer()
                        Image(systemName: "checkmark")
                    }
                }
            }
            Divider()
            ForEach(availableAudioDevices) { device in
                Button {
                    onOutputDeviceChange(device.uid)
                } label: {
                    HStack {
                        Text(device.name)
                        if lane.outputDeviceUID == device.uid {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(outputDeviceName)
                    .font(.system(size: 9))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(0.8))
            )
        }
        .buttonStyle(.plain)
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
                clipsContent

                if let previewFrame = dropPreviewFrame {
                    dropPreviewOverlay(frame: previewFrame, height: geometry.size.height, width: geometry.size.width)
                }

                // Drop target overlay
                if isDropTargeted {
                    dropTargetOverlay
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity) // Ensure ZStack fills available space
            .onDrop(of: [UTType.fileURL], delegate: AudioLaneDropDelegate(
                isTargeted: $isDropTargeted,
                pixelsPerFrame: pixelsPerFrame,
                scrollOffset: scrollOffset,
                durationFrames: timelineDurationFrames,
                dropHandler: { providers, location in
                    handleDrop(providers: providers, at: location)
                },
                updateHandler: { location in
                    updateDropPreview(location: location)
                },
                enterHandler: { providers, location in
                    beginDropPreview(with: providers, at: location)
                },
                exitHandler: {
                    clearDropPreview()
                }
            ))
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
            .stroke(Color.orange, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
            .background(Color.orange.opacity(0.1))
            .padding(2)
    }

    private func dropPreviewOverlay(frame: Int, height: CGFloat, width: CGFloat) -> some View {
        let durationFrames = dropPreviewDurationFrames ?? Int(frameRate.fps)
        let rawWidth = CGFloat(durationFrames) * pixelsPerFrame
        let clampedWidth = min(max(12, rawWidth), width)
        let xOffset = CGFloat(frame) * pixelsPerFrame - scrollOffset

        return RoundedRectangle(cornerRadius: 4)
            .stroke(Color.orange, lineWidth: 2)
            .background(Color.orange.opacity(0.1))
            .frame(width: clampedWidth, height: max(6, height - 6))
            .offset(x: xOffset)
            .padding(.vertical, 3)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var clipsContent: some View {
        ForEach(lane.clips) { clip in
            AudioClipView(
                clip: clip,
                lane: lane,
                isActive: activeClipIds.contains(clip.id),
                pixelsPerFrame: pixelsPerFrame,
                frameRate: frameRate,
                isSelected: selectedClipId == clip.id,
                waveformCache: waveformCache,
                showWaveform: showWaveforms,
                interactionsEnabled: clipInteractionsEnabled,
                onSelect: {
                    selectedClipId = clip.id
                    onClipSelected(clip.id)
                },
                onDoubleClick: {
                    onClipDoubleClick(clip)
                }
            )
            .offset(x: CGFloat(clip.timelineStartFrame) * pixelsPerFrame - scrollOffset)
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

    private func handleDrop(providers: [NSItemProvider], at location: CGPoint) -> Bool {
        var urls: [URL] = []

        let group = DispatchGroup()
        let targetFrame = dropFrame(for: location)
        let isInternalDrag = isInternalMediaDrag(providers)

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
                onDropMedia(mediaURLs, targetFrame, isInternalDrag)
            }
        }
        clearDropPreview()

        return true
    }

    private func isInternalMediaDrag(_ providers: [NSItemProvider]) -> Bool {
        providers.contains { provider in
            provider.hasItemConformingToTypeIdentifier(UTType.projectorMediaItem.identifier)
        }
    }

    private func dropFrame(for location: CGPoint) -> Int {
        let x = max(0, location.x + scrollOffset)
        let rawFrame = Int(x / max(pixelsPerFrame, 0.001))
        return max(0, min(rawFrame, max(0, timelineDurationFrames - 1)))
    }

    private func updateDropPreview(location: CGPoint) {
        dropPreviewFrame = dropFrame(for: location)
    }

    private func beginDropPreview(with providers: [NSItemProvider], at location: CGPoint) {
        updateDropPreview(location: location)
        if dropPreviewDurationFrames != nil || isLoadingDropPreview {
            return
        }
        isLoadingDropPreview = true

        loadFirstURL(from: providers) { url in
            guard let url = url else {
                isLoadingDropPreview = false
                return
            }
            Task {
                let asset = AVAsset(url: url)
                do {
                    let duration = try await asset.load(.duration)
                    let frames = max(1, Int(duration.seconds * frameRate.fps))
                    dropPreviewDurationFrames = frames
                } catch {
                    dropPreviewDurationFrames = nil
                }
                isLoadingDropPreview = false
            }
        }
    }

    private func clearDropPreview() {
        dropPreviewFrame = nil
        dropPreviewDurationFrames = nil
        isLoadingDropPreview = false
    }

    private func loadFirstURL(from providers: [NSItemProvider], completion: @escaping (URL?) -> Void) {
        guard let provider = providers.first else {
            completion(nil)
            return
        }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            if let data = item as? Data,
               let url = URL(dataRepresentation: data, relativeTo: nil) {
                completion(url)
            } else if let url = item as? URL {
                completion(url)
            } else {
                completion(nil)
            }
        }
    }

    private func isMediaFile(_ url: URL) -> Bool {
        let videoExtensions = ["mov", "mp4", "m4v", "avi", "mkv", "mxf"]
        let audioExtensions = ["wav", "aif", "aiff", "mp3", "m4a", "flac", "ogg"]
        let ext = url.pathExtension.lowercased()
        return videoExtensions.contains(ext) || audioExtensions.contains(ext)
    }
}

private struct AudioLaneDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    let pixelsPerFrame: CGFloat
    let scrollOffset: CGFloat
    let durationFrames: Int
    let dropHandler: ([NSItemProvider], CGPoint) -> Bool
    let updateHandler: (CGPoint) -> Void
    let enterHandler: ([NSItemProvider], CGPoint) -> Void
    let exitHandler: () -> Void

    func validateDrop(info: DropInfo) -> Bool {
        !info.itemProviders(for: [UTType.fileURL]).isEmpty
    }

    func dropEntered(info: DropInfo) {
        isTargeted = true
        let providers = info.itemProviders(for: [UTType.fileURL])
        enterHandler(providers, info.location)
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
        exitHandler()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateHandler(info.location)
        return DropProposal(operation: .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        exitHandler()
        let providers = info.itemProviders(for: [UTType.fileURL])
        return dropHandler(providers, info.location)
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
                frameRate: .fps24,
                scrollOffset: 0,
                timelineDurationFrames: 10000,
                showWaveforms: true,
                clipInteractionsEnabled: true,
                availableAudioDevices: [],
                onMuteToggle: {},
                onSoloToggle: {},
                onVolumeChange: { _ in },
                onOutputDeviceChange: { _ in },
                onDropMedia: { _, _, _ in },
                onClipSelected: { _ in },
                onClipDoubleClick: { _ in },
                onLaneRename: { _ in }
            )
            .frame(width: 800)
            .background(Color(white: 0.15))
        }
    }

    return PreviewWrapper()
}
