//
//  TimelineAccordionView.swift
//  Projector
//
//  Extracted from ContentView - collapsible timeline accordion panel.
//

import SwiftUI
import Iconoir
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
        HStack {
            Spacer()
            Text("Double-click regions to set custom timecode")
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.6))
                .padding(.trailing, Spacing.md)
        }
        .frame(height: PanelLayout.footerHeight)
    }

    // MARK: - Accordion Header

    private var accordionHeader: some View {
        HStack(spacing: 6) {
            // Expand/collapse button
            Button(action: { timelineViewModel.toggleExpansion() }) {
                HStack(spacing: 6) {
                    Image(systemName: timelineViewModel.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 12)

                    Iconoir.videoCamera.asImage
                        .frame(width: 14, height: 14)
                        .foregroundColor(.secondary)

                    Text("Timeline")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            // Add Audio Lane button
            Button(action: onAddAudioLane) {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Audio Lane")
                }
            }
            .buttonStyle(GlassActionButtonStyle(tint: .accentColor))
            .help("Add a new audio lane")
        }
        .frame(height: PanelLayout.headerHeight)
        .padding(.horizontal, Spacing.md)
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
            .frame(height: 12)
            .contentShape(Rectangle())
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
