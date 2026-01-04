//
//  VitalControlsBar.swift
//  Projector
//
//  Extracted from ContentView - contains transport, timecode, zoom, and settings controls.
//

import SwiftUI
import SwiftTimecodeCore
import Iconoir

/// The vital controls bar containing transport, timecode editing, zoom, and settings.
///
/// This view sits below the video player and provides:
/// - Start timecode and duration editing
/// - FPS display
/// - Transport controls (play, pause, step, stop)
/// - Zoom controls for the timeline
/// - Settings button
struct VitalControlsBar: View {
    // MARK: - Dependencies

    @ObservedObject var timelineManager: TimelineManager
    @ObservedObject var playbackEngine: PlaybackEngine
    @ObservedObject var timelineViewModel: TimelineViewModel

    // MARK: - Callbacks

    var onSettingsPressed: () -> Void

    // MARK: - Local State

    @State private var editingStartTCText = ""
    @State private var editingDurationText = ""
    @State private var isHoveringStartTC = false
    @State private var isHoveringDuration = false
    @FocusState private var isStartTCFocused: Bool
    @FocusState private var isDurationFocused: Bool

    /// Whether any timecode field is being edited (for overlay detection)
    var isEditingTimecode: Bool {
        isStartTCFocused || isDurationFocused
    }

    // MARK: - Body

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                startTCControl
                durationControl
                fpsControl
            }
            .layoutPriority(1)

            Spacer(minLength: 12)

            transportControls
                .layoutPriority(0)

            Spacer(minLength: 12)

            HStack(spacing: 12) {
                zoomControls

                Button(action: onSettingsPressed) {
                    Iconoir.settings.asImage
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
            }
            .layoutPriority(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow, alphaValue: 0.8)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - Start Timecode Control

    private var startTCControl: some View {
        HStack(spacing: 4) {
            Text("Start TC:")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)

            TextField("00:00:00:00", text: $editingStartTCText)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .frame(width: 85)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isStartTCFocused ? Color.white.opacity(0.12) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isStartTCFocused ? Color.accentColor : Color.clear, lineWidth: 1)
                )
                .focused($isStartTCFocused)
                .onChange(of: editingStartTCText) { _, newValue in
                    let formatted = formatTimecodeInput(newValue)
                    if formatted != newValue {
                        editingStartTCText = formatted
                    }
                }
                .onSubmit {
                    applyStartTimecode()
                }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(startTCBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        )
        .onHover { hovering in
            isHoveringStartTC = hovering
        }
        .onChange(of: isStartTCFocused) { wasFocused, isFocused in
            if wasFocused && !isFocused {
                editingStartTCText = timelineManager.timeline.config.startTimecode.stringValue()
            }
        }
        .onAppear {
            editingStartTCText = timelineManager.timeline.config.startTimecode.stringValue()
            DispatchQueue.main.async {
                isStartTCFocused = false
            }
        }
    }

    private var startTCBackground: Color {
        if isStartTCFocused {
            return Color(nsColor: .controlBackgroundColor)
        } else if isHoveringStartTC {
            return Color.white.opacity(0.1)
        } else {
            return Color(nsColor: .controlBackgroundColor)
        }
    }

    // MARK: - Duration Control

    private var durationControl: some View {
        HStack(spacing: 4) {
            Text("Duration:")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)

            TextField("00:00:00:00", text: $editingDurationText)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .frame(width: 85)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isDurationFocused ? Color.white.opacity(0.12) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isDurationFocused ? Color.accentColor : Color.clear, lineWidth: 1)
                )
                .focused($isDurationFocused)
                .onChange(of: editingDurationText) { _, newValue in
                    let formatted = formatTimecodeInput(newValue)
                    if formatted != newValue {
                        editingDurationText = formatted
                    }
                }
                .onSubmit {
                    applyDuration()
                }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(durationBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        )
        .onHover { hovering in
            isHoveringDuration = hovering
        }
        .onChange(of: isDurationFocused) { wasFocused, isFocused in
            if wasFocused && !isFocused {
                editingDurationText = durationTimecodeString
            }
        }
        .onChange(of: timelineManager.timeline.config.durationFrames) { _, _ in
            if !isDurationFocused {
                editingDurationText = durationTimecodeString
            }
        }
        .onAppear {
            editingDurationText = durationTimecodeString
        }
    }

    private var durationBackground: Color {
        if isDurationFocused {
            return Color(nsColor: .controlBackgroundColor)
        } else if isHoveringDuration {
            return Color.white.opacity(0.1)
        } else {
            return Color(nsColor: .controlBackgroundColor)
        }
    }

    // MARK: - FPS Control

    private var fpsControl: some View {
        HStack(spacing: 4) {
            Text("FPS:")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)

            Text(timelineManager.timeline.config.frameRate.displayName)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .frame(minWidth: 45)
                .foregroundColor(.primary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        )
        .help("Frame rate is set by the video file")
    }

    // MARK: - Transport Controls

    private var transportControls: some View {
        HStack(spacing: 8) {
            // Play/Pause toggle
            Button(action: { playbackEngine.togglePlayback() }) {
                (playbackEngine.isPlaying ? Iconoir.pauseSolid.asImage : Iconoir.playSolid.asImage)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .disabled(!playbackEngine.hasContent)
            .keyboardShortcut(.space, modifiers: [])
            .help(playbackEngine.isPlaying ? "Pause" : "Play")

            // Stop (return to start)
            Button(action: { playbackEngine.stop() }) {
                Image(systemName: "backward.end")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)
            .disabled(!playbackEngine.hasContent)
            .help("Stop and Return to Start")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.thinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: - Zoom Controls

    private var zoomControls: some View {
        HStack(spacing: 4) {
            Button(action: { timelineViewModel.zoomOut() }) {
                Image(systemName: "minus.magnifyingglass")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .disabled(!hasTimelineContent || timelineViewModel.zoomLevel <= timelineViewModel.minZoom)
            .accessibilityIdentifier("zoom-out")

            Slider(value: $timelineViewModel.zoomLevel, in: timelineViewModel.minZoom...timelineViewModel.maxZoom)
                .frame(width: 80)
                .controlSize(.mini)
                .disabled(!hasTimelineContent)
                .simultaneousGesture(
                    TapGesture(count: 2)
                        .onEnded { _ in timelineViewModel.resetZoom() }
                )
                .accessibilityIdentifier("zoom-slider")

            Button(action: { timelineViewModel.zoomIn() }) {
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .disabled(!hasTimelineContent || timelineViewModel.zoomLevel >= timelineViewModel.maxZoom)
            .accessibilityIdentifier("zoom-in")
        }
    }

    // MARK: - Helper Functions

    private var durationTimecodeString: String {
        let config = timelineManager.timeline.config
        let durationTC = Timecode(.frames(config.durationFrames), at: config.frameRate, by: .clamping)
        return durationTC.stringValue()
    }

    private var hasTimelineContent: Bool {
        !timelineManager.timeline.videoReels.isEmpty || timelineManager.timeline.audioLanes.contains { !$0.clips.isEmpty }
    }

    /// Cancel any active timecode editing and reset to stored values
    func cancelEditing() {
        if isStartTCFocused {
            editingStartTCText = timelineManager.timeline.config.startTimecode.stringValue()
            isStartTCFocused = false
        }
        if isDurationFocused {
            editingDurationText = durationTimecodeString
            isDurationFocused = false
        }
    }

    private func formatTimecodeInput(_ input: String) -> String {
        let digits = input.filter { $0.isNumber }
        let limited = String(digits.prefix(8))
        var result = ""
        for (index, char) in limited.enumerated() {
            if index > 0 && index % 2 == 0 {
                result += ":"
            }
            result.append(char)
        }
        return result
    }

    private func applyStartTimecode() {
        if let newTC = parseTimecode(editingStartTCText) {
            timelineManager.setTimelineBounds(start: newTC, end: timelineManager.timeline.config.endTimecode)
            editingStartTCText = newTC.stringValue()
        } else {
            editingStartTCText = timelineManager.timeline.config.startTimecode.stringValue()
        }
        isStartTCFocused = false
    }

    private func applyDuration() {
        if let durationTC = parseTimecode(editingDurationText) {
            let durationFrames = durationTC.frameCount.wholeFrames
            let config = timelineManager.timeline.config
            let newEndFrames = config.startTimecode.frameCount.wholeFrames + durationFrames
            let newEnd = Timecode(.frames(newEndFrames), at: config.frameRate, by: .clamping)
            timelineManager.setTimelineBounds(start: config.startTimecode, end: newEnd)
            editingDurationText = durationTimecodeString
        } else {
            editingDurationText = durationTimecodeString
        }
        isDurationFocused = false
    }

    private func parseTimecode(_ string: String) -> Timecode? {
        let digits = string.filter { $0.isNumber }
        let padded = String(repeating: "0", count: max(0, 8 - digits.count)) + digits
        let trimmed = String(padded.suffix(8))
        guard trimmed.count == 8 else { return nil }

        let h = Int(trimmed.prefix(2)) ?? 0
        let m = Int(trimmed.dropFirst(2).prefix(2)) ?? 0
        let s = Int(trimmed.dropFirst(4).prefix(2)) ?? 0
        let f = Int(trimmed.dropFirst(6).prefix(2)) ?? 0

        return Timecode(
            .components(h: h, m: m, s: s, f: f),
            at: timelineManager.timeline.config.frameRate,
            by: .clamping
        )
    }

}
