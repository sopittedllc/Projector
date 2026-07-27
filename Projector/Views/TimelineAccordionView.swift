//
//  TimelineAccordionView.swift
//  Projector
//
//  Extracted from ContentView - collapsible timeline accordion panel.
//

import SwiftUI
import AppKit
import SwiftTimecodeCore

/// A collapsible accordion panel containing the multi-track timeline.
///
/// This view provides:
/// - Expandable/collapsible header with disclosure chevron
/// - Multi-track timeline with video reels and audio lanes
/// - Resizable height when expanded
struct TimelineAccordionView: View {
    // MARK: - Dependencies

    @ObservedObject var timelineManager: TimelineManager
    @ObservedObject var playbackEngine: PlaybackEngine
    @ObservedObject var waveformCache: WaveformCache
    @ObservedObject var audioOutputManager: AudioOutputManager
    @ObservedObject var timelineViewModel: TimelineViewModel
    @ObservedObject var mediaLibrary: ProjectMediaLibrary
    /// Live MIDI input state, for the incoming-timecode readout in the header.
    @ObservedObject var midiSyncViewModel: MIDISyncViewModel

    /// Video reel thumbnail cache
    @ObservedObject var thumbnailCache: ThumbnailCache

    // MARK: - Callbacks

    /// Called when video media is dropped on the timeline
    var onDropVideoMedia: ([URL], Int, Bool) -> Void

    /// Called when audio media is dropped on a lane (lane index, URLs)
    var onDropAudioMedia: (Int, [URL], Int, Bool) -> Void

    /// Called when user seeks to a frame
    var onSeek: (Int) -> Void

    /// Called when settings button is pressed
    var onSettingsPressed: () -> Void

    /// Called when user wants to add a new audio lane
    var onAddAudioLane: () -> Void

    /// Called when mixed video/audio files are dropped on the timeline
    var onDropMixedMedia: (([URL], [URL], Int) -> Void)?

    // MARK: - Section sizing

    /// Height the section authority has given this panel.
    ///
    /// Passed in rather than held: `SectionLayout` resolves it from the window's
    /// size, so a panel that kept its own height would be a second opinion on a
    /// question that already has an answer.
    ///
    /// The resize handle that used to live along this panel's bottom edge moved
    /// out to `ContentView`'s section splitter, in the gap above the panel. Under
    /// the section authority the window's height is fixed while dragging, so
    /// growing the timeline has to take the room from the top row - which means
    /// the edge that moves is the timeline's *top* edge. A handle on the bottom
    /// edge would have stayed still while the panel grew upward out from under
    /// the cursor.
    var height: CGFloat

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            accordionHeader

            do {
                // Bounded, not stretched. MultiTrackTimelineView's tracks
                // section fills whatever height it is given, so an unbounded
                // `maxHeight: .infinity` pulled the ruler and tracks apart and
                // pushed the tracks off the bottom. Telling it exactly what is
                // left after the header and footer keeps the footer - and
                // "+ Audio Lane" - on screen at any panel height, with the
                // lanes scrolling inside whatever remains.
                timelineContent
                    .frame(height: tracksHeight)

                timelineHint
            }
        }
        .frame(height: height, alignment: .top)
        .clipped()
        .glassPanel()
        // Refit the view whenever the timeline grows.
        //
        // Media dropped past the end extends the duration via
        // `extendTimeline(toEndFrame:)`, but the zoom level is a *fraction* of
        // that duration - so without this the newly added media lands outside
        // the visible span and the timeline appears not to have taken it. Only
        // fires on growth, so zooming in and working stays undisturbed.
        .onChange(of: timelineManager.timeline.config.durationFrames) { oldValue, newValue in
            guard newValue > oldValue else { return }
            withAnimation(AppAnimations.standard) {
                timelineViewModel.zoomLevel = timelineViewModel.minZoom
            }
        }
    }

    /// Height available to the tracks: the panel less its header and footer.
    ///
    /// Floored at zero so a mid-drag resize cannot hand the tracks a negative
    /// height.
    private var tracksHeight: CGFloat {
        max(0, height
            - PanelLayout.headerHeight
            - (PanelLayout.footerHeight + Spacing.md))
    }

    // MARK: - Timeline Hint

    private var timelineHint: some View {
        HStack(alignment: .center) {
            Text("Double-click regions to set custom timecode")
                .font(Typography.caption)
                .foregroundColor(AppColors.textTertiary)

            Spacer()

            // Add Audio Lane button (secondary action)
            Button(action: onAddAudioLane) {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "plus")
                        .font(Typography.iconSmall)
                    Text("Audio Lane")
                }
            }
            .buttonStyle(GlassTextButtonStyle())
            .accessibilityLabel("Add a new audio lane")
            .help("Add a new audio lane")
        }
        .frame(maxWidth: .infinity)
        .frame(height: PanelLayout.footerHeight + Spacing.md) // Include space for resize handle
        .padding(.horizontal, Spacing.md)
    }

    // MARK: - Accordion Header

    private var accordionHeader: some View {
        HStack(spacing: Spacing.sm) {
            // A title, not a control. The panel has a set height that shows the
            // Video File track and three lanes, with anything beyond scrolling
            // inside it - so there is nothing left for a disclosure to do.
            HStack(spacing: Spacing.sm) {
                Image(systemName: "video")
                    .font(Typography.icon)
                    .foregroundColor(.secondary)

                Text("Timeline")
                    .font(Typography.subheading)
                    .foregroundColor(.primary)
                    // Never wrap. Without this the title is the first thing
                    // SwiftUI compresses when the header runs out of room, and
                    // it breaks mid-word into "Tim/eli..." rather than letting
                    // the row report that it needs more width.
                    .lineLimit(1)
                    .fixedSize()
            }
            .accessibilityLabel("Timeline")

            Spacer()

            do {
                // Everything numeric about the timeline in one row: what is
                // coming in, where the playhead is, and the bounds it runs
                // between.
                TimelineHeaderReadouts(
                    timelineManager: timelineManager,
                    midiSyncViewModel: midiSyncViewModel
                )

                TimelineTimecodeControls(timelineManager: timelineManager)

                Divider()
                    .frame(height: Spacing.xl)
                    .padding(.horizontal, Spacing.sm)

                zoomControls
            }
        }
        .frame(height: PanelLayout.headerHeight)
        .padding(.horizontal, Spacing.md)
    }

    // MARK: - Zoom Controls

    // NOTE: zoom used to be gated on a `hasTimelineContent` check, so an empty
    // timeline could not be zoomed at all. That is exactly the case where zoom
    // matters most: an empty timeline spans the full 4-hour default duration,
    // where the playhead advances a fraction of a point per second. Following
    // MTC with no media loaded is a supported mode, so the view has to stay
    // navigable in it. The helper had no other callers and was removed with the
    // gate.

    private var zoomControls: some View {
        HStack(spacing: Spacing.xs) {
            Button(action: { timelineViewModel.zoomOut() }) {
                Image(systemName: "minus.magnifyingglass")
                    .font(Typography.bodySmall)
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .disabled(timelineViewModel.zoomLevel <= timelineViewModel.minZoom)
            .accessibilityLabel("Zoom out")
            .help("Zoom out")

            Slider(value: $timelineViewModel.zoomLevel, in: timelineViewModel.minZoom...timelineViewModel.maxZoom)
                .frame(width: 80)
                .controlSize(.mini)
                .accessibilityLabel("Timeline zoom level")

            Button(action: { timelineViewModel.zoomIn() }) {
                Image(systemName: "plus.magnifyingglass")
                    .font(Typography.bodySmall)
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .disabled(timelineViewModel.zoomLevel >= timelineViewModel.maxZoom)
            .accessibilityLabel("Zoom in")
            .help("Zoom in")
        }
        .padding(.trailing, Spacing.xs)
    }

    // MARK: - Timeline Content

    private var timelineContent: some View {
        MultiTrackTimelineView(
            timelineManager: timelineManager,
            playbackEngine: playbackEngine,
            waveformCache: waveformCache,
            audioOutputManager: audioOutputManager,
            thumbnailCache: thumbnailCache,
            mediaLibrary: mediaLibrary,
            onDropVideoMedia: onDropVideoMedia,
            onDropAudioMedia: onDropAudioMedia,
            onDropMixedMedia: onDropMixedMedia,
            onSeek: onSeek,
            onSettingsPressed: onSettingsPressed,
            showHeader: false,
            zoomLevel: $timelineViewModel.zoomLevel
        )
    }
}

// MARK: - Timeline Timecode Controls

/// Start-timecode and duration fields for the timeline header.
///
/// Moved out of `VitalControlsBar`: these two define the timeline's *bounds*,
/// which is timeline configuration rather than transport state, so they belong
/// beside the zoom tools that also act on the timeline. The transport bar keeps
/// what changes during playback - position, incoming MIDI, run state.
///
/// Self-contained by design. All the editing state (focus, hover, in-progress
/// text, the out-of-range alert) is owned here rather than passed in, so the
/// move did not leave `VitalControlsBar` holding state for a control it no
/// longer shows.
struct TimelineTimecodeControls: View {
    @ObservedObject var timelineManager: TimelineManager

    @State private var editingStartTCText = ""
    @State private var editingDurationText = ""
    @State private var isHoveringStartTC = false
    @State private var isHoveringDuration = false
    @State private var showStartTimecodeAlert = false
    @State private var startTimecodeAlertMessage = ""
    @FocusState private var isStartTCFocused: Bool
    @FocusState private var isDurationFocused: Bool

    var body: some View {
        HStack(spacing: Spacing.sm) {
            startTCControl
            durationControl
        }
        .fixedSize()
        .alert("Invalid Start Timecode", isPresented: $showStartTimecodeAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(startTimecodeAlertMessage)
        }
    }

    // MARK: - Start Timecode

    private var startTCControl: some View {
        HStack(spacing: Spacing.xs) {
            Text("Start TC:")
                .font(TransportTypography.label)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize()

            TextField("00:00:00:00", text: $editingStartTCText)
                .textFieldStyle(.plain)
                .font(TransportTypography.value)
                .foregroundColor(isHoveringStartTC || isStartTCFocused ? .primary : .secondary)
                .frame(width: 78)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isStartTCFocused ? AppColors.surfaceMedium : (isHoveringStartTC ? AppColors.surfaceLight : Color.clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isStartTCFocused ? Color.accentColor : (isHoveringStartTC ? AppColors.borderMedium : AppColors.borderSubtle), lineWidth: PanelLayout.borderWidth)
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
                    isStartTCFocused = false
                }
                .onExitCommand {
                    editingStartTCText = timelineManager.timeline.config.startTimecode.stringValue()
                    isStartTCFocused = false
                }
        }
        .fixedSize()
        .onHover { hovering in
            withAnimation(AppAnimations.quick) {
                isHoveringStartTC = hovering
            }
        }
        .help("Click to edit start timecode")
        .onChange(of: isStartTCFocused) { wasFocused, isFocused in
            if !isFocused && wasFocused {
                applyStartTimecode()   // save on blur
            }
        }
        .onChange(of: timelineManager.timeline.config.startTimecode) { _, newValue in
            if !isStartTCFocused {
                editingStartTCText = newValue.stringValue()
            }
        }
        .onAppear {
            editingStartTCText = timelineManager.timeline.config.startTimecode.stringValue()
            DispatchQueue.main.async {
                isStartTCFocused = false
            }
        }
    }

    // MARK: - Duration

    private var durationControl: some View {
        HStack(spacing: Spacing.xs) {
            Text("Duration:")
                .font(TransportTypography.label)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize()

            TextField("00:00:00:00", text: $editingDurationText)
                .textFieldStyle(.plain)
                .font(TransportTypography.value)
                .foregroundColor(isHoveringDuration || isDurationFocused ? .primary : .secondary)
                .frame(width: 78)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isDurationFocused ? AppColors.surfaceMedium : (isHoveringDuration ? AppColors.surfaceLight : Color.clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isDurationFocused ? Color.accentColor : (isHoveringDuration ? AppColors.borderMedium : AppColors.borderSubtle), lineWidth: PanelLayout.borderWidth)
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
                    isDurationFocused = false
                }
                .onExitCommand {
                    editingDurationText = durationTimecodeString
                    isDurationFocused = false
                }
        }
        .fixedSize()
        .onHover { hovering in
            withAnimation(AppAnimations.quick) {
                isHoveringDuration = hovering
            }
        }
        .help("Click to edit timeline duration")
        .onChange(of: isDurationFocused) { wasFocused, isFocused in
            if !isFocused && wasFocused {
                applyDuration()   // save on blur
            }
        }
        // Media dropped past the end extends the timeline, so the field has to
        // follow the config rather than only what was last typed.
        .onChange(of: timelineManager.timeline.config.durationFrames) { _, _ in
            if !isDurationFocused {
                editingDurationText = durationTimecodeString
            }
        }
        .onAppear {
            editingDurationText = durationTimecodeString
        }
    }

    // MARK: - Helpers

    private var durationTimecodeString: String {
        let config = timelineManager.timeline.config
        return Timecode(.frames(config.durationFrames), at: config.frameRate, by: .clamping).stringValue()
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

        // Refuse a start that would fall after existing content: the content's
        // timecode is derived from the start, so this would silently renumber it.
        if let earliest = findEarliestContentFrame() {
            let earliestAbsoluteFrame = config.startTimecode.frameCount.wholeFrames + earliest
            if newTC.frameCount.wholeFrames > earliestAbsoluteFrame {
                let earliestTimecode = Timecode(.frames(earliestAbsoluteFrame), at: config.frameRate, by: .clamping)
                startTimecodeAlertMessage = "The start timecode \(newTC.stringValue()) is after the first content at \(earliestTimecode.stringValue()). Move or delete the content first."
                showStartTimecodeAlert = true
                editingStartTCText = config.startTimecode.stringValue()
                isStartTCFocused = false
                return
            }
        }

        // Move the end with the start, so duration is preserved.
        let newEndFrames = newTC.frameCount.wholeFrames + config.durationFrames
        let newEnd = Timecode(.frames(newEndFrames), at: config.frameRate, by: .clamping)

        timelineManager.setTimelineBounds(start: newTC, end: newEnd)
        editingStartTCText = newTC.stringValue()
        isStartTCFocused = false
    }

    /// Earliest frame holding content, across video reels and audio clips.
    private func findEarliestContentFrame() -> Int? {
        var earliest: Int?
        for reel in timelineManager.timeline.videoReels {
            if earliest == nil || reel.timelineStartFrame < earliest! {
                earliest = reel.timelineStartFrame
            }
        }
        for lane in timelineManager.timeline.audioLanes {
            for clip in lane.clips where earliest == nil || clip.timelineStartFrame < earliest! {
                earliest = clip.timelineStartFrame
            }
        }
        return earliest
    }

    private func applyDuration() {
        if let durationTC = parseTimecode(editingDurationText) {
            let config = timelineManager.timeline.config
            let newEndFrames = config.startTimecode.frameCount.wholeFrames + durationTC.frameCount.wholeFrames
            let newEnd = Timecode(.frames(newEndFrames), at: config.frameRate, by: .clamping)
            timelineManager.setTimelineBounds(start: config.startTimecode, end: newEnd)
        }
        editingDurationText = durationTimecodeString
        isDurationFocused = false
    }

    private func parseTimecode(_ string: String) -> Timecode? {
        let digits = string.filter { $0.isNumber }
        let padded = String(repeating: "0", count: max(0, 8 - digits.count)) + digits
        let trimmed = String(padded.suffix(8))
        guard trimmed.count == 8 else { return nil }

        return Timecode(
            .components(
                h: Int(trimmed.prefix(2)) ?? 0,
                m: Int(trimmed.dropFirst(2).prefix(2)) ?? 0,
                s: Int(trimmed.dropFirst(4).prefix(2)) ?? 0,
                f: Int(trimmed.dropFirst(6).prefix(2)) ?? 0
            ),
            at: timelineManager.timeline.config.frameRate,
            by: .clamping
        )
    }
}

// MARK: - Header Field Styling

private extension View {
    /// Resting appearance of an editable timecode field, for read-only values.
    ///
    /// Matches `TimelineTimecodeControls`' `TextField` exactly - same corner
    /// radius, same subtle border - so the status readouts sit beside Start TC
    /// and Duration as one row of like components. They deliberately never take
    /// the hover or focus treatment: these values are reported, not edited, and
    /// lighting up under the cursor would advertise an affordance that is not
    /// there.
    func headerFieldBox() -> some View {
        self
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(AppColors.borderSubtle, lineWidth: PanelLayout.borderWidth)
            )
    }
}

// MARK: - Timeline Header Readouts

/// Incoming MIDI, styled as a header field.
///
/// The playhead position readout that used to sit beside this was removed: the
/// timecode overlay on the picture reports position now, in a much larger
/// readout, and its placement is configurable in Settings.
///
/// Frame rate used to sit here too, but it describes the *media* rather than
/// the timeline, so it moved onto the video overlay where it travels with the
/// picture. The incoming MTC rate is still validated against it - see
/// `frameRateMismatch`, which reads the project rate directly.
struct TimelineHeaderReadouts: View {
    @ObservedObject var timelineManager: TimelineManager
    @ObservedObject var midiSyncViewModel: MIDISyncViewModel

    /// Opacity driver for the frame-rate-mismatch flash.
    @State private var mismatchFlash: Double = 1.0

    var body: some View {
        HStack(spacing: Spacing.sm) {
            midiReadout
        }
        .fixedSize()
    }

    // MARK: - Incoming MIDI

    /// Incoming timecode, its rate, and what kind of MIDI is arriving.
    ///
    /// Condensed to a single line to match the other header fields. The former
    /// two-line layout was the tallest thing in the transport bar and would have
    /// forced this row taller than every field beside it. The status text keeps
    /// its own colour, and the full explanation stays in the tooltip.
    private var midiReadout: some View {
        HStack(spacing: Spacing.xs) {
            Text("MTC IN:")
                .font(TransportTypography.label)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize()

            HStack(spacing: Spacing.xs) {
                Circle()
                    .fill(signalColor)
                    .frame(width: 6, height: 6)
                    .opacity(frameRateMismatch ? mismatchFlash : 1.0)

                Text(readoutPrimary)
                    .font(TransportTypography.value)
                    .foregroundColor(midiSyncViewModel.incomingSignal == .timecode ? .primary : .secondary)
                    .lineLimit(1)

                Text(readoutStatus)
                    .font(frameRateMismatch ? TransportTypography.captionStrong : TransportTypography.caption)
                    .foregroundColor(frameRateMismatch ? AppColors.accentPink : .secondary.opacity(0.8))
                    .opacity(frameRateMismatch ? mismatchFlash : 1.0)
                    .lineLimit(1)
            }
            .headerFieldBox()
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(AppColors.accentPink.opacity(frameRateMismatch ? 0.8 : 0), lineWidth: PanelLayout.borderWidth)
                    .opacity(frameRateMismatch ? mismatchFlash : 0)
            )
        }
        .help(readoutTooltip)
        .accessibilityLabel(readoutTooltip)
        // Drive the flash only while mismatched, and settle to fully opaque when
        // resolved so the readout doesn't freeze mid-fade.
        .onChange(of: frameRateMismatch) { _, mismatched in
            if mismatched {
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                    mismatchFlash = 0.25
                }
            } else {
                withAnimation(.easeInOut(duration: 0.2)) {
                    mismatchFlash = 1.0
                }
            }
        }
        .onAppear {
            if frameRateMismatch {
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                    mismatchFlash = 0.25
                }
            }
        }
    }

    // MARK: - Derived State

    /// Whether the incoming MTC rate disagrees with the project rate.
    ///
    /// A hard fault, not a warning: MTC positions are expressed in the sender's
    /// frame rate, so a 25 fps stream read as 24 fps lands the playhead on the
    /// wrong frame and drifts further every second. Sync can appear "locked"
    /// while playback sits somewhere else entirely.
    private var frameRateMismatch: Bool {
        guard midiSyncViewModel.incomingSignal == .timecode,
              let incoming = midiSyncViewModel.incomingFrameRate else { return false }
        return incoming != timelineManager.timeline.config.frameRate
    }

    /// Timecode when locked, otherwise dashes - a stale number would read as a
    /// live feed.
    private var readoutPrimary: String {
        if midiSyncViewModel.incomingSignal == .timecode,
           let tc = midiSyncViewModel.mtcTimecode {
            return tc.stringValue()
        }
        return "--:--:--:--"
    }

    /// Short status suffix. The long-form explanation lives in the tooltip.
    private var readoutStatus: String {
        switch midiSyncViewModel.incomingSignal {
        case .timecode:
            let rate = midiSyncViewModel.incomingFrameRate?.stringValue ?? "?"
            guard frameRateMismatch else { return rate }
            return "\(rate) ≠ \(timelineManager.timeline.config.frameRate.stringValue)"
        // Beat clock and other traffic both mean "MIDI is arriving but it is
        // not timecode" - the dot colour and the tooltip carry the difference,
        // and under an "MTC IN" label a "CLOCK" reading just reads as wrong.
        case .beatClock, .other: return "NO TC"
        case .none:              return "NONE"
        }
    }

    private var signalColor: Color {
        switch midiSyncViewModel.incomingSignal {
        case .timecode:
            // Red, not amber: a rate mismatch silently puts the playhead on the
            // wrong frame, which is worse than no sync at all because it looks
            // like it's working.
            return frameRateMismatch ? AppColors.accentPink : .green
        case .beatClock, .other:
            return .orange
        case .none:
            return .secondary.opacity(0.4)
        }
    }

    private var readoutTooltip: String {
        switch midiSyncViewModel.incomingSignal {
        case .timecode:
            let rate = midiSyncViewModel.incomingFrameRate?.stringValue ?? "unknown"
            let project = timelineManager.timeline.config.frameRate.stringValue
            if let incoming = midiSyncViewModel.incomingFrameRate,
               incoming.stringValue != project {
                return "FRAME RATE MISMATCH: incoming MTC is \(rate) but this project is \(project). MTC positions are expressed in the sender's rate, so the playhead will land on the wrong frame and drift. Change the project rate to \(rate), or set the sender to \(project)."
            }
            return "Receiving MTC at \(rate) on \(midiSyncViewModel.selectedInputName ?? "the selected input")"
        case .beatClock:
            return "Receiving MIDI Beat Clock, which carries tempo but not position - it cannot drive timecode sync. Send MIDI Time Code (MTC) instead."
        case .other:
            return "Receiving MIDI, but no timecode. Check that the sender is transmitting MTC."
        case .none:
            return "No MIDI arriving on \(midiSyncViewModel.selectedInputName ?? "the selected input")"
        }
    }
}
