//
//  TimelineAccordionView.swift
//  Projector
//
//  Extracted from ContentView - collapsible timeline accordion panel.
//

import SwiftUI
import AppKit

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

    @State private var isResizingTimeline = false
    @State private var isHoveringTimelineResize = false
    @State private var timelineDragStartHeight: CGFloat = 0
    @State private var timelineDragStartLocationY: CGFloat = 0
    @State private var didPushResizeCursorForDrag = false

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            accordionHeader

            // Content (only when expanded)
            if timelineViewModel.isExpanded {
                timelineContent

                // Hint text
                timelineHint
            }
        }
        .frame(height: timelineViewModel.currentHeight, alignment: .top)
        .clipped()
        .glassPanel()
        .overlay(alignment: .bottom) {
            if timelineViewModel.isExpanded {
                timelineResizeHandle
            }
        }
    }

    // MARK: - Timeline Hint

    private var timelineHint: some View {
        HStack(alignment: .center) {
            Text("Double-click regions to set custom timecode")
                .font(Typography.caption)
                .foregroundColor(AppColors.textTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .frame(height: PanelLayout.footerHeight + Spacing.md) // Include space for resize handle
        .padding(.horizontal, Spacing.md)
    }

    // MARK: - Accordion Header

    private var accordionHeader: some View {
        HStack(spacing: Spacing.sm) {
            // Expand/collapse button
            Button(action: { timelineViewModel.toggleExpansion() }) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: timelineViewModel.isExpanded ? "chevron.down" : "chevron.right")
                        .font(Typography.iconSmall)
                        .foregroundColor(.secondary)
                        .frame(width: Spacing.md)

                    Image(systemName: "video")
                        .font(Typography.icon)
                        .foregroundColor(.secondary)

                    Text("Timeline")
                        .font(Typography.subheading)
                        .foregroundColor(.primary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Timeline section, \(timelineViewModel.isExpanded ? "expanded" : "collapsed")")
            .accessibilityHint("Double-tap to \(timelineViewModel.isExpanded ? "collapse" : "expand")")

            Spacer()

            // Add Audio Lane button
            Button(action: onAddAudioLane) {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "plus")
                        .font(Typography.iconSmall)
                    Text("Audio Lane")
                }
            }
            .buttonStyle(GlassActionButtonStyle(tint: .accentColor))
            .accessibilityLabel("Add a new audio lane")
            .help("Add a new audio lane")

            // Zoom controls
            if timelineViewModel.isExpanded {
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

    private var hasTimelineContent: Bool {
        !timelineManager.timeline.videoReels.isEmpty || timelineManager.timeline.audioLanes.contains { !$0.clips.isEmpty }
    }

    private var zoomControls: some View {
        HStack(spacing: Spacing.xs) {
            Button(action: { timelineViewModel.zoomOut() }) {
                Image(systemName: "minus.magnifyingglass")
                    .font(Typography.bodySmall)
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .disabled(!hasTimelineContent || timelineViewModel.zoomLevel <= timelineViewModel.minZoom)
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
            .disabled(!hasTimelineContent || timelineViewModel.zoomLevel >= timelineViewModel.maxZoom)
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

    private var timelineResizeHandle: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: Spacing.md)
            .contentShape(Rectangle())
            .overlay {
                // Only show indicator line when actively resizing (panel border is visible otherwise)
                if isResizingTimeline {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(height: 2)
                }
            }
            .accessibilityLabel("Resize timeline")
            .onHover { hovering in
                guard !isResizingTimeline else { return }
                if hovering, !isHoveringTimelineResize {
                    NSCursor.resizeUpDown.push()
                    isHoveringTimelineResize = true
                } else if !hovering, isHoveringTimelineResize {
                    NSCursor.pop()
                    isHoveringTimelineResize = false
                }
            }
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        if !isResizingTimeline {
                            timelineDragStartHeight = timelineViewModel.expandedHeight
                            timelineDragStartLocationY = value.startLocation.y
                            isResizingTimeline = true
                            if !isHoveringTimelineResize {
                                NSCursor.resizeUpDown.push()
                                didPushResizeCursorForDrag = true
                            } else {
                                didPushResizeCursorForDrag = false
                            }
                        }
                        let delta = value.location.y - timelineDragStartLocationY
                        timelineViewModel.setExpandedHeight(timelineDragStartHeight + delta)
                    }
                    .onEnded { _ in
                        isResizingTimeline = false
                        if didPushResizeCursorForDrag {
                            NSCursor.pop()
                        }
                        didPushResizeCursorForDrag = false
                    }
            )
    }
}
