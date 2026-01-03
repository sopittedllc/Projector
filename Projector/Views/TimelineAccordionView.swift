//
//  TimelineAccordionView.swift
//  Projector
//
//  Extracted from ContentView - collapsible timeline accordion panel.
//

import SwiftUI
import Iconoir

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

    /// Video reel thumbnails indexed by reel ID
    let thumbnails: [UUID: ThumbnailStrip]

    // MARK: - Callbacks

    /// Called when video media is dropped on the timeline
    var onDropVideoMedia: ([URL]) -> Void

    /// Called when audio media is dropped on a lane (lane index, URLs)
    var onDropAudioMedia: (Int, [URL]) -> Void

    /// Called when user seeks to a frame
    var onSeek: (Int) -> Void

    /// Called when settings button is pressed
    var onSettingsPressed: () -> Void

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            accordionHeader

            // Content (only when expanded)
            if timelineViewModel.isExpanded {
                timelineContent
            }

            // Resize handle at the bottom (only when expanded)
            if timelineViewModel.isExpanded {
                AccordionResizeHandle(
                    height: $timelineViewModel.expandedHeight,
                    minHeight: timelineViewModel.minExpandedHeight,
                    maxHeight: timelineViewModel.maxExpandedHeight
                )
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
            thumbnails: thumbnails,
            onDropVideoMedia: onDropVideoMedia,
            onDropAudioMedia: onDropAudioMedia,
            onSeek: onSeek,
            onSettingsPressed: onSettingsPressed,
            showHeader: false,
            zoomLevel: $timelineViewModel.zoomLevel
        )
    }
}
