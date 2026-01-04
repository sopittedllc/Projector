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
            }
        }
        .frame(height: timelineViewModel.currentHeight, alignment: .top)
        .clipped()
        .background(
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow, alphaValue: 0.8)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
        .overlay(alignment: .bottom) {
            if timelineViewModel.isExpanded {
                timelineResizeHandle
            }
        }
    }

    // MARK: - Accordion Header

    private var accordionHeader: some View {
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

                Spacer()
            }
            .frame(height: 32)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Timeline Content

    private var timelineContent: some View {
        MultiTrackTimelineView(
            timelineManager: timelineManager,
            playbackEngine: playbackEngine,
            waveformCache: waveformCache,
            audioOutputManager: audioOutputManager,
            thumbnailCache: thumbnailCache,
            onDropVideoMedia: onDropVideoMedia,
            onDropAudioMedia: onDropAudioMedia,
            onSeek: onSeek,
            onSettingsPressed: onSettingsPressed,
            showHeader: false,
            zoomLevel: $timelineViewModel.zoomLevel
        )
    }

    private var timelineResizeHandle: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 10)
            .contentShape(Rectangle())
            .overlay {
                Rectangle()
                    .fill(isResizingTimeline ? Color.accentColor : Color.white.opacity(0.25))
                    .frame(height: 1)
            }
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
