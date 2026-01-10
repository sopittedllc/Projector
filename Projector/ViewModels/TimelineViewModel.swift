//
//  TimelineViewModel.swift
//  Projector
//
//  ViewModel that bridges TimelineManager to SwiftUI Views.
//  Manages UI-specific timeline state and provides computed properties.
//

import Foundation
import SwiftUI
import Combine
import SwiftTimecodeCore

/// ViewModel for timeline UI state and interactions.
///
/// This class sits between `TimelineManager` (data layer) and SwiftUI Views,
/// managing UI-specific state like expansion, zoom level, and selection.
///
/// ## Architecture
///
/// ```
/// ┌─────────────────────────────────────────────────────────────────────────┐
/// │                    SwiftUI Views                                         │
/// │  MultiTrackTimelineView, TimelineAccordion, etc.                        │
/// │  - Use @ObservedObject var timelineVM: TimelineViewModel                │
/// └─────────────────────────────────────────────────────────────────────────┘
///                               │
///                               ▼
/// ┌─────────────────────────────────────────────────────────────────────────┐
/// │              TimelineViewModel (this file)                               │
/// │  - @MainActor for UI thread safety                                       │
/// │  - @Published UI state (expansion, zoom, selection)                      │
/// │  - Computed properties for display                                       │
/// │  - Actions that delegate to TimelineManager                              │
/// └─────────────────────────────────────────────────────────────────────────┘
///                               │
///                               ▼
/// ┌─────────────────────────────────────────────────────────────────────────┐
/// │              TimelineManager (Data Layer)                                │
/// │  - Timeline model (reels, lanes, clips)                                  │
/// │  - Persistence and sync                                                  │
/// └─────────────────────────────────────────────────────────────────────────┘
/// ```
///
/// ## Thread Safety
///
/// This ViewModel is confined to the main thread via `@MainActor`.
/// All state updates happen on the main thread for SwiftUI compatibility.
@MainActor
final class TimelineViewModel: ObservableObject {

    // MARK: - Dependencies

    /// The underlying timeline manager (data layer)
    let manager: TimelineManager

    // MARK: - UI State

    /// Whether the timeline accordion is expanded
    @Published var isExpanded: Bool = true

    /// Current zoom level (0.0 = fit, 1.0 = max zoom)
    @Published var zoomLevel: CGFloat = 0.0

    /// Height of the expanded timeline section
    @Published var expandedHeight: CGFloat = TimelineViewModel.defaultExpandedHeight

    /// Currently selected video reel ID, if any
    @Published var selectedReelId: UUID?

    /// Currently selected audio clip ID, if any
    @Published var selectedClipId: UUID?

    /// Currently selected audio lane ID, if any
    @Published var selectedLaneId: UUID?

    // MARK: - Constants

    /// Minimum zoom level (fit to view)
    let minZoom: CGFloat = 0.0

    /// Maximum zoom level
    let maxZoom: CGFloat = 1.0

    /// Default zoom level (fit to view)
    let defaultZoom: CGFloat = 0.0

    /// Zoom step for UI controls
    private let zoomStep: CGFloat = 0.1

    /// Height when timeline is collapsed (header only)
    let collapsedHeight: CGFloat = TimelineSectionLayout.collapsedHeight

    /// Minimum expanded height
    let minExpandedHeight: CGFloat = TimelineSectionLayout.minHeight

    /// Maximum expanded height
    let maxExpandedHeight: CGFloat = TimelineSectionLayout.maxHeight

    // MARK: - Combine

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    /// Default expanded height uses TimelineSectionLayout for consistency
    private static let defaultExpandedHeight: CGFloat = TimelineSectionLayout.defaultHeight

    /// Creates a new timeline view model.
    ///
    /// - Parameter manager: The timeline manager to bridge to the UI
    public init(manager: TimelineManager) {
        self.manager = manager
        setupObservers()
    }

    // MARK: - Computed Properties

    /// The underlying timeline model
    var timeline: Timeline {
        manager.timeline
    }

    /// Timeline configuration
    var config: TimelineConfig {
        manager.timeline.config
    }

    /// Current frame rate
    var frameRate: TimecodeFrameRate {
        config.frameRate
    }

    /// Duration in frames
    var durationFrames: Int {
        config.durationFrames
    }

    /// Whether the timeline has any content
    var hasContent: Bool {
        !manager.timeline.videoReels.isEmpty || manager.timeline.audioLanes.contains { !$0.clips.isEmpty }
    }

    /// Number of video reels
    var reelCount: Int {
        manager.timeline.videoReels.count
    }

    /// Number of audio lanes
    var laneCount: Int {
        manager.timeline.audioLanes.count
    }

    /// Total clip count across all lanes
    var totalClipCount: Int {
        manager.timeline.audioLanes.reduce(0) { $0 + $1.clips.count }
    }

    /// Formatted duration string (HH:MM:SS)
    var durationString: String {
        let totalSeconds = Double(durationFrames) / frameRate.fps
        let hours = Int(totalSeconds) / 3600
        let minutes = (Int(totalSeconds) % 3600) / 60
        let seconds = Int(totalSeconds) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    /// Formatted start timecode string
    var startTimecodeString: String {
        config.startTimecode.stringValue()
    }

    /// Formatted end timecode string
    var endTimecodeString: String {
        config.endTimecode.stringValue()
    }

    /// Current height based on expansion state
    var currentHeight: CGFloat {
        isExpanded ? expandedHeight : collapsedHeight
    }

    // MARK: - Actions

    /// Toggle timeline expansion
    func toggleExpansion() {
        isExpanded.toggle()
    }

    /// Expand the timeline if not already expanded
    func expandIfNeeded() {
        if !isExpanded {
            isExpanded = true
        }
    }

    /// Update the expanded height (clamped to min/max).
    func setExpandedHeight(_ height: CGFloat) {
        let clamped = min(maxExpandedHeight, max(minExpandedHeight, height))
        expandedHeight = clamped
    }

    /// Reset zoom to default level
    func resetZoom() {
        withAnimation(.easeInOut(duration: 0.15)) {
            zoomLevel = defaultZoom
        }
    }

    /// Zoom in by a step
    func zoomIn() {
        let newZoom = min(zoomLevel + zoomStep, maxZoom)
        withAnimation(.easeInOut(duration: 0.1)) {
            zoomLevel = newZoom
        }
    }

    /// Zoom out by a step
    func zoomOut() {
        let newZoom = max(zoomLevel - zoomStep, minZoom)
        withAnimation(.easeInOut(duration: 0.1)) {
            zoomLevel = newZoom
        }
    }

    /// Clear all selections
    func clearSelection() {
        selectedReelId = nil
        selectedClipId = nil
        selectedLaneId = nil
    }

    /// Select a video reel
    func selectReel(_ id: UUID?) {
        selectedReelId = id
        selectedClipId = nil
    }

    /// Select an audio clip
    func selectClip(_ id: UUID?, inLane laneId: UUID? = nil) {
        selectedClipId = id
        selectedLaneId = laneId
        selectedReelId = nil
    }

    // MARK: - Timeline Operations (Delegate to Manager)

    /// Add a new audio lane
        @discardableResult
    func addAudioLane(name: String? = nil) -> AudioLane {
        let laneName = name ?? "Audio \(laneCount + 1)"
        return manager.addAudioLane(name: laneName)
    }

    /// Remove a video reel
    func removeReel(id: UUID) {
        manager.removeVideoReel(id: id)
        if selectedReelId == id {
            selectedReelId = nil
        }
    }

    /// Remove an audio clip
    func removeClip(id: UUID, fromLane laneId: UUID) {
        manager.removeAudioClip(clipId: id, fromLane: laneId)
        if selectedClipId == id {
            selectedClipId = nil
            selectedLaneId = nil
        }
    }

    /// Update timeline bounds
    func setTimelineBounds(start: Timecode, end: Timecode) {
        manager.setTimelineBounds(start: start, end: end)
    }

    /// Update timeline configuration
    func updateConfig(_ config: TimelineConfig) {
        manager.updateConfig(config)
    }

    // MARK: - Private

    private func setupObservers() {
        // Auto-expand when content is added
        manager.$timeline
            .map { !$0.videoReels.isEmpty || $0.audioLanes.contains { !$0.clips.isEmpty } }
            .removeDuplicates()
            .filter { $0 } // Only when content exists
            .sink { [weak self] _ in
                self?.expandIfNeeded()
            }
            .store(in: &cancellables)
    }

    private func resizeToFitLanes() {
        let laneCount = manager.timeline.audioLanes.count
        let audioHeight = max(TimelineLayout.audioLaneHeight, CGFloat(laneCount) * (TimelineLayout.audioLaneHeight + 1))

        // Calculate content height: header + ruler + video track + audio lanes + footer
        let contentHeight = PanelLayout.headerHeight
            + TimelineLayout.rulerHeight
            + 1  // divider
            + TimelineLayout.videoTrackHeight
            + 1  // divider
            + audioHeight
            + PanelLayout.footerHeight

        let clamped = min(maxExpandedHeight, max(minExpandedHeight, contentHeight))
        if clamped > expandedHeight {
            expandedHeight = clamped
        }
    }
}
