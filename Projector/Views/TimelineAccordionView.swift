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

    /// Called when the report a bug button is pressed
    var onReportBugPressed: () -> Void

    /// Called when user wants to add a new audio lane
    var onAddAudioLane: () -> Void

    /// Called when mixed video/audio files are dropped on the timeline
    var onDropMixedMedia: (([URL], [URL], Int) -> Void)?

    /// Called when user wants to export a cue list from the MX lane
    var onExportCueList: () -> Void

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
        .onChangeWithPrevious(of: timelineManager.timeline.config.durationFrames) { oldValue, newValue in
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

            // Add Audio Lane button (styled to match Settings/Import)
            Button(action: onAddAudioLane) {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "plus")
                        .frame(width: 12, height: 12)
                    Text("Audio Lane")
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .buttonStyle(GlassActionButtonStyle(tint: AppColors.accentGreen))
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("Add a new audio lane")
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

            // Export Cue List button - only visible when MX lanes have clips
            if timelineManager.timeline.audioLanes.contains(where: { !$0.clips.isEmpty }) {
                Button(action: onExportCueList) {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "list.bullet.rectangle")
                            .frame(width: 12, height: 12)
                        Text("Export Cue List")
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .buttonStyle(GlassActionButtonStyle(tint: AppColors.accentBlue, help: "Export Cue List from MX lane"))
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("Export Cue List from MX lane")
            }

            do {
                // Everything numeric about the timeline in one row: what is
                // coming in, where the playhead is, and the bounds it runs
                // between.
                TimelineHeaderReadouts(
                    timelineManager: timelineManager,
                    midiSyncViewModel: midiSyncViewModel
                )

                // Current playhead position (editable)
                TimelinePositionControl(
                    timelineManager: timelineManager,
                    timelineViewModel: timelineViewModel,
                    playbackEngine: playbackEngine
                )

                TimelineTimecodeControls(timelineManager: timelineManager)

                Divider()
                    .frame(height: Spacing.xl)
                    .padding(.horizontal, Spacing.sm)

                zoomControls

                // Settings button - far right
                Button(action: onSettingsPressed) {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "gearshape")
                            .frame(width: 12, height: 12)
                        Text("Settings")
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .buttonStyle(GlassActionButtonStyle(tint: AppColors.accentBlue))
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("Timeline settings")

                // Report a Bug - far right, after Settings.
                //
                // Worded to match Settings, which costs this row about 67pt it
                // did not have to give. `TimelineSectionLayout.headerMinWidth`
                // carries that width so the window cannot be made narrow enough
                // to compress the readouts - if that constant is ever recomputed,
                // this button has to be in the measurement.
                Button(action: onReportBugPressed) {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "ladybug")
                            .frame(width: 12, height: 12)
                        Text("Report a Bug")
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .buttonStyle(GlassActionButtonStyle(tint: AppColors.accentPink))
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("Report a bug")
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

// MARK: - Timeline Position Control

/// Editable playhead position field for the timeline header.
///
/// Uses TransparentTextField (NSViewRepresentable) instead of SwiftUI TextField
/// because SwiftUI TextField has known focus issues in toolbar/header contexts
/// on macOS. See: https://developer.apple.com/forums/thread/765147
struct TimelinePositionControl: View {
    @ObservedObject var timelineManager: TimelineManager
    @ObservedObject var timelineViewModel: TimelineViewModel
    @ObservedObject var playbackEngine: PlaybackEngine

    @State private var editingPositionText = ""
    @State private var isHoveringPosition = false
    @State private var isPositionFocused = false
    @State private var showExtendConfirmation = false
    @State private var pendingSeekFrame: Int?
    /// Prevents double-apply when Return is pressed (fires both onSubmit and focus change)
    @State private var didApplyOnSubmit = false

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Text("Position:")
                .font(TransportTypography.label)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize()

            TransparentTextField(
                text: $editingPositionText,
                placeholder: "00:00:00:00",
                font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                onSubmit: {
                    didApplyOnSubmit = true
                    applyPosition()
                },
                onEscape: {
                    editingPositionText = playheadTimecodeString()
                },
                isFocused: $isPositionFocused
            )
            .frame(width: 78)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(
                Group {
                    if isPositionFocused {
                        // Editing state: dark inset background
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.black.opacity(0.4))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(Color.white.opacity(0.3), lineWidth: 1)
                            )
                    } else {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isHoveringPosition ? AppColors.surfaceLight : Color.clear)
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isPositionFocused ? Color.accentColor : (isHoveringPosition ? AppColors.borderMedium : AppColors.borderSubtle), lineWidth: isPositionFocused ? 2 : PanelLayout.borderWidth)
            )
            .accessibilityLabel("Playhead position")
        }
        .fixedSize()
        .onHover { hovering in
            withAnimation(AppAnimations.quick) {
                isHoveringPosition = hovering
            }
        }
        .help("Click to edit playhead position")
        .onChangeCompat(of: editingPositionText) { newValue in
            let formatted = formatTimecodeInput(newValue)
            if formatted != newValue {
                editingPositionText = formatted
            }
        }
        .onChangeWithPrevious(of: isPositionFocused) { wasFocused, isFocused in
            if !isFocused && wasFocused {
                // Don't apply again if we already applied via onSubmit (Return key)
                if !didApplyOnSubmit {
                    applyPosition()
                }
                didApplyOnSubmit = false
            }
        }
        // Follows the playhead the timeline actually draws. This watched
        // `timelineManager.currentFrame`, which only a manual seek ever writes,
        // so the field sat at the timeline start while the playhead moved.
        .onChangeCompat(of: playbackEngine.currentFrame) { frame in
            guard !isPositionFocused else { return }
            editingPositionText = timelineManager.timeline.config.timecode(at: frame).stringValue()
        }
        .onAppear {
            editingPositionText = timelineManager.timeline.config
                .timecode(at: playbackEngine.currentFrame).stringValue()
        }
        .alert("Extend Timeline?", isPresented: $showExtendConfirmation) {
            Button("Cancel", role: .cancel) {
                pendingSeekFrame = nil
                editingPositionText = playheadTimecodeString()
            }
            Button("Extend") {
                confirmExtendAndSeek()
            }
        } message: {
            Text("The position you entered is beyond the current timeline duration. Would you like to extend the timeline to include this position?")
        }
    }

    // MARK: - Helpers

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

    /// The timecode of the playhead the timeline is actually drawing.
    ///
    /// `timelineManager.currentFrame` is only ever written by a manual seek, so
    /// reading it here left the field showing the timeline start.
    private func playheadTimecodeString() -> String {
        timelineManager.timeline.config
            .timecode(at: playbackEngine.currentFrame).stringValue()
    }

    private func applyPosition() {
        guard let newTC = parseTimecode(editingPositionText) else {
            editingPositionText = playheadTimecodeString()
            isPositionFocused = false
            return
        }

        let config = timelineManager.timeline.config
        let startFrames = config.startTimecode.frameCount.wholeFrames
        let targetFrames = newTC.frameCount.wholeFrames
        let targetFrame = targetFrames - startFrames

        if targetFrame >= config.durationFrames {
            pendingSeekFrame = targetFrame
            showExtendConfirmation = true
        } else if targetFrame < 0 {
            editingPositionText = playheadTimecodeString()
        } else {
            // Use playbackEngine.seekToFrame which updates both playback and UI
            playbackEngine.seekToFrame(targetFrame)
            editingPositionText = newTC.stringValue()
        }
    }

    private func confirmExtendAndSeek() {
        guard let targetFrame = pendingSeekFrame else { return }

        let paddingFrames = Int(TimelineManager.defaultPaddingMinutes * 60.0 * timelineManager.timeline.config.frameRate.fps)
        timelineManager.extendTimeline(toEndFrame: targetFrame + paddingFrames)

        // Sync playbackEngine's timeline copy (Timeline is a struct, not a class)
        playbackEngine.timeline = timelineManager.timeline

        timelineViewModel.zoomLevel = timelineViewModel.minZoom

        playbackEngine.seekToFrame(targetFrame)

        // Compute the timecode from targetFrame (don't read timelineManager.currentTimecode
        // which is based on timelineManager.currentFrame, not playbackEngine.currentFrame)
        let targetTimecode = timelineManager.timeline.config.timecode(at: targetFrame)
        editingPositionText = targetTimecode.stringValue()
        pendingSeekFrame = nil
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
    @State private var isHoveringStartTC = false
    @State private var isStartTCFocused = false
    @State private var showStartTimecodeAlert = false
    @State private var startTimecodeAlertMessage = ""
    /// Prevents double-apply when Return is pressed
    @State private var didApplyOnSubmit = false

    var body: some View {
        HStack(spacing: Spacing.sm) {
            startTCControl
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

            TransparentTextField(
                text: $editingStartTCText,
                placeholder: "00:00:00:00",
                font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                onSubmit: {
                    didApplyOnSubmit = true
                    applyStartTimecode()
                },
                onEscape: {
                    editingStartTCText = timelineManager.timeline.config.startTimecode.stringValue()
                },
                isFocused: $isStartTCFocused
            )
            .frame(width: 78)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(
                Group {
                    if isStartTCFocused {
                        // Editing state: dark inset background
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.black.opacity(0.4))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(Color.white.opacity(0.3), lineWidth: 1)
                            )
                    } else {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isHoveringStartTC ? AppColors.surfaceLight : Color.clear)
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isStartTCFocused ? Color.accentColor : (isHoveringStartTC ? AppColors.borderMedium : AppColors.borderSubtle), lineWidth: isStartTCFocused ? 2 : PanelLayout.borderWidth)
            )
            .accessibilityLabel("Start timecode")
        }
        .fixedSize()
        .onHover { hovering in
            withAnimation(AppAnimations.quick) {
                isHoveringStartTC = hovering
            }
        }
        .help("Click to edit start timecode")
        .onChangeCompat(of: editingStartTCText) { newValue in
            let formatted = formatTimecodeInput(newValue)
            if formatted != newValue {
                editingStartTCText = formatted
            }
        }
        .onChangeWithPrevious(of: isStartTCFocused) { wasFocused, isFocused in
            if !isFocused && wasFocused {
                // Don't apply again if we already applied via onSubmit (Return key)
                if !didApplyOnSubmit {
                    applyStartTimecode()
                }
                didApplyOnSubmit = false
            }
        }
        .onChangeCompat(of: timelineManager.timeline.config.startTimecode) { newValue in
            if !isStartTCFocused {
                editingStartTCText = newValue.stringValue()
            }
        }
        .onAppear {
            editingStartTCText = timelineManager.timeline.config.startTimecode.stringValue()
        }
    }

    // MARK: - Helpers

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
        .onChangeCompat(of: frameRateMismatch) { mismatched in
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

// MARK: - Transparent TextField

/// A TextField that removes all macOS system styling (focus ring, background)
/// so parent views can apply custom styling without interference.
///
/// Uses NSViewRepresentable wrapping NSTextField directly, bypassing SwiftUI
/// TextField's known focus issues in toolbar/header contexts on macOS.
struct TransparentTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    var font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .medium)
    var alignment: NSTextAlignment = .left
    var onSubmit: (() -> Void)?
    var onEscape: (() -> Void)?

    @Binding var isFocused: Bool

    func makeNSView(context: Context) -> NSTextField {
        let textField = FocusableTextField()
        textField.delegate = context.coordinator
        textField.isBordered = false
        textField.drawsBackground = false
        textField.backgroundColor = .clear
        textField.focusRingType = .none
        textField.font = font
        textField.alignment = alignment
        textField.placeholderString = placeholder
        textField.cell?.sendsActionOnEndEditing = false

        // Set up action for Return key
        textField.target = context.coordinator
        textField.action = #selector(Coordinator.textFieldAction(_:))

        // Wire up callbacks
        textField.onFocusGained = { [weak coordinator = context.coordinator] in
            coordinator?.parent.isFocused = true
        }
        textField.onFocusLost = { [weak coordinator = context.coordinator] in
            coordinator?.parent.isFocused = false
        }
        textField.onReturn = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onSubmit?()
        }
        textField.onEscape = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onEscape?()
        }

        return textField
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.font = font
        nsView.alignment = alignment
        nsView.placeholderString = placeholder

        // Handle focus changes from SwiftUI
        DispatchQueue.main.async {
            if isFocused && nsView.window?.firstResponder != nsView.currentEditor() {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TransparentTextField

        init(_ parent: TransparentTextField) {
            self.parent = parent
        }

        /// Called when Return key is pressed (via target/action)
        @objc func textFieldAction(_ sender: NSTextField) {
            parent.onSubmit?()
            sender.window?.makeFirstResponder(nil)
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let textField = obj.object as? NSTextField else { return }
            parent.text = textField.stringValue
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            DispatchQueue.main.async {
                self.parent.isFocused = true
            }
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            DispatchQueue.main.async {
                self.parent.isFocused = false
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onEscape?()
                control.window?.makeFirstResponder(nil)
                return true
            }
            return false
        }
    }
}

// MARK: - Focusable TextField

/// Custom NSTextField subclass that properly handles first responder status.
///
/// Standard NSTextField can have issues with focus in SwiftUI contexts,
/// particularly in toolbars and headers. Overriding mouse events ensures
/// the field properly captures and retains focus.
private class FocusableTextField: NSTextField {
    /// Called when the field gains focus (becomes first responder)
    var onFocusGained: (() -> Void)?
    /// Called when the field loses focus (resigns first responder)
    var onFocusLost: (() -> Void)?
    /// Called when Return key is pressed
    var onReturn: (() -> Void)?
    /// Called when Escape key is pressed
    var onEscape: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        // Ensure we become first responder on mouse down
        if window?.firstResponder != self.currentEditor() {
            window?.makeFirstResponder(self)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            // Ensure the field editor is properly set up and select all text
            if let fieldEditor = window?.fieldEditor(true, for: self) as? NSTextView {
                fieldEditor.selectedRange = NSRange(location: 0, length: stringValue.count)
            }
            // Notify that we gained focus
            DispatchQueue.main.async { [weak self] in
                self?.onFocusGained?()
            }
        }
        return result
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)

        // Check if ended due to Return key
        if let movement = notification.userInfo?["NSTextMovement"] as? Int,
           movement == NSTextMovement.return.rawValue {
            DispatchQueue.main.async { [weak self] in
                self?.onReturn?()
            }
        }

        // Notify that we lost focus
        DispatchQueue.main.async { [weak self] in
            self?.onFocusLost?()
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
        window?.makeFirstResponder(nil)
    }
}
