//
//  VitalControlsBar.swift
//  Projector
//
//  Extracted from ContentView - contains transport, timecode, zoom, and settings controls.
//

import SwiftUI
import SwiftTimecodeCore

/// The vital controls bar containing transport, timecode editing, zoom, and settings.
///
/// This view sits below the video player and provides:
/// - Start timecode and duration editing
/// - FPS display
/// - Transport controls (play, pause, step, stop)
/// - Zoom controls for the timeline
struct VitalControlsBar: View {
    // MARK: - Dependencies

    @ObservedObject var timelineManager: TimelineManager
    @ObservedObject var playbackEngine: PlaybackEngine
    @ObservedObject var timelineViewModel: TimelineViewModel

    // MARK: - Local State

    @State private var editingStartTCText = ""
    @State private var editingDurationText = ""
    @State private var isHoveringStartTC = false
    @State private var isHoveringDuration = false
    @State private var showStartTimecodeAlert = false
    @State private var startTimecodeAlertMessage = ""
    @State private var playPulseOpacity: Double = 1.0
    @FocusState private var isStartTCFocused: Bool
    @FocusState private var isDurationFocused: Bool

    /// Whether any timecode field is being edited (for overlay detection)
    var isEditingTimecode: Bool {
        isStartTCFocused || isDurationFocused
    }

    // MARK: - Body

    var body: some View {
        HStack(spacing: Spacing.md) {
            // Logo branding with app name (left side)
            HStack(spacing: Spacing.sm) {
                Image("TitlebarLogo")
                    .resizable()
                    .renderingMode(.template)
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 18)
                    .foregroundColor(.white.opacity(0.5))

                Text("Projector")
                    .font(Typography.subheading)
                    .foregroundColor(.white.opacity(0.5))
            }

            Spacer()

            // Right-aligned: TC controls (fixed size, don't shrink)
            HStack(spacing: Spacing.md) {
                startTCControl
                durationControl
                fpsControl
            }
            .fixedSize()

            // Play indicator (shows when playing)
            playIndicator
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .glassPanel()
        .alert("Invalid Start Timecode", isPresented: $showStartTimecodeAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(startTimecodeAlertMessage)
        }
    }

    // MARK: - Start Timecode Control

    private var startTCControl: some View {
        HStack(spacing: Spacing.xs) {
            Text("Start TC:")
                .font(Typography.label)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize()

            TextField("00:00:00:00", text: $editingStartTCText)
                .textFieldStyle(.plain)
                .font(Typography.mono)
                .foregroundColor(isHoveringStartTC || isStartTCFocused ? .primary : .secondary)
                .frame(width: 85)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isStartTCFocused ? AppColors.surfaceMedium : (isHoveringStartTC ? AppColors.surfaceLight : Color.clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isStartTCFocused ? Color.accentColor : (isHoveringStartTC ? AppColors.borderMedium : Color.clear), lineWidth: PanelLayout.borderWidth)
                )
                .focused($isStartTCFocused)
                .accessibilityLabel("Start timecode")
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
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .fixedSize()
        .glassControl(isHighlighted: isStartTCFocused || isHoveringStartTC)
        .onHover { hovering in
            withAnimation(AppAnimations.quick) {
                isHoveringStartTC = hovering
            }
        }
        .help("Click to edit start timecode")
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

    // MARK: - Duration Control

    private var durationControl: some View {
        HStack(spacing: Spacing.xs) {
            Text("Duration:")
                .font(Typography.label)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize()

            TextField("00:00:00:00", text: $editingDurationText)
                .textFieldStyle(.plain)
                .font(Typography.mono)
                .foregroundColor(isHoveringDuration || isDurationFocused ? .primary : .secondary)
                .frame(width: 85)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isDurationFocused ? AppColors.surfaceMedium : (isHoveringDuration ? AppColors.surfaceLight : Color.clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isDurationFocused ? Color.accentColor : (isHoveringDuration ? AppColors.borderMedium : Color.clear), lineWidth: PanelLayout.borderWidth)
                )
                .focused($isDurationFocused)
                .accessibilityLabel("Duration")
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
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .fixedSize()
        .glassControl(isHighlighted: isDurationFocused || isHoveringDuration)
        .onHover { hovering in
            withAnimation(AppAnimations.quick) {
                isHoveringDuration = hovering
            }
        }
        .help("Click to edit timeline duration")
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

    // MARK: - FPS Control

    private var fpsControl: some View {
        HStack(spacing: Spacing.xs) {
            Text("FPS:")
                .font(Typography.label)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize()

            Text(timelineManager.timeline.config.frameRate.displayName)
                .font(Typography.mono)
                .frame(width: 50)
                .foregroundColor(.primary)
                .lineLimit(1)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xs)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .fixedSize()
        .glassControl()
        .accessibilityLabel("Frame rate: \(timelineManager.timeline.config.frameRate.displayName) frames per second")
        .help("Frame rate is set by the video file")
    }

    // MARK: - Play Indicator

    /// A subtle pulsing play indicator that shows when playing
    private var playIndicator: some View {
        HStack(spacing: Spacing.sm) {
            // Invisible button for spacebar shortcut
            Button(action: { playbackEngine.togglePlayback() }) {
                EmptyView()
            }
            .keyboardShortcut(.space, modifiers: [])
            .frame(width: 0, height: 0)
            .opacity(0)

            // Play indicator (only visible when playing)
            if playbackEngine.isPlaying {
                Image(systemName: "play.fill")
                    .font(Typography.icon)
                    .foregroundColor(AppColors.accentGreen)
                    .opacity(playPulseOpacity)
                    .animation(
                        Animation.easeInOut(duration: 0.8)
                            .repeatForever(autoreverses: true),
                        value: playbackEngine.isPlaying
                    )
                    .onAppear {
                        playPulseOpacity = 0.4
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.sm)
                    .glassControl()
                    .help("Playing (Space to pause)")
            }
        }
    }

    // MARK: - Helper Functions

    private var durationTimecodeString: String {
        let config = timelineManager.timeline.config
        let durationTC = Timecode(.frames(config.durationFrames), at: config.frameRate, by: .clamping)
        return durationTC.stringValue()
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
        guard let newTC = parseTimecode(editingStartTCText) else {
            editingStartTCText = timelineManager.timeline.config.startTimecode.stringValue()
            isStartTCFocused = false
            return
        }

        let config = timelineManager.timeline.config

        // Check if the new start would be after any existing content
        let earliestContentFrame = findEarliestContentFrame()
        if let earliest = earliestContentFrame {
            // Calculate what timecode the earliest content would have with the new start
            let earliestAbsoluteFrame = config.startTimecode.frameCount.wholeFrames + earliest
            let newStartFrames = newTC.frameCount.wholeFrames

            // If new start is after the earliest content's absolute timecode, reject with message
            if newStartFrames > earliestAbsoluteFrame {
                let earliestTimecode = Timecode(.frames(earliestAbsoluteFrame), at: config.frameRate, by: .clamping)
                startTimecodeAlertMessage = "The start timecode \(newTC.stringValue()) is after the first content at \(earliestTimecode.stringValue()). Move or delete the content first."
                showStartTimecodeAlert = true
                editingStartTCText = config.startTimecode.stringValue()
                isStartTCFocused = false
                return
            }
        }

        // Maintain the same duration by adjusting end timecode
        let currentDuration = config.durationFrames
        let newEndFrames = newTC.frameCount.wholeFrames + currentDuration
        let newEnd = Timecode(.frames(newEndFrames), at: config.frameRate, by: .clamping)

        timelineManager.setTimelineBounds(start: newTC, end: newEnd)
        editingStartTCText = newTC.stringValue()
        isStartTCFocused = false
    }

    /// Find the earliest frame with content (video reels or audio clips)
    private func findEarliestContentFrame() -> Int? {
        var earliest: Int?

        // Check video reels
        for reel in timelineManager.timeline.videoReels {
            if earliest == nil || reel.timelineStartFrame < earliest! {
                earliest = reel.timelineStartFrame
            }
        }

        // Check audio clips across all lanes
        for lane in timelineManager.timeline.audioLanes {
            for clip in lane.clips {
                if earliest == nil || clip.timelineStartFrame < earliest! {
                    earliest = clip.timelineStartFrame
                }
            }
        }

        return earliest
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
