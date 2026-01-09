//
//  OptimizationViewModel.swift
//  Projector
//
//  ViewModel bridging OptimizationSheetView to MediaOptimizationService.
//

import Foundation
import Combine

// MARK: - OptimizationViewModel

/// ViewModel for the media optimization sheet.
///
/// Manages the optimization workflow:
/// 1. Analysis: Scan files and estimate savings
/// 2. Configuration: User chooses options
/// 3. Optimization: Transcode with progress reporting
/// 4. Verification: Show preserved frame rates and sample rates
@MainActor
final class OptimizationViewModel: ObservableObject {

    // MARK: - State

    /// Current state of the optimization workflow
    enum State: Equatable {
        case idle
        case analyzing
        case ready
        case optimizing
        case complete
        case error(String)
    }

    // MARK: - Published Properties

    /// Current workflow state
    @Published public private(set) var state: State = .idle

    /// Analysis results (available when state == .ready)
    @Published public private(set) var analysisResult: ProjectAnalysisResult = .empty

    /// Current optimization progress (available when state == .optimizing)
    @Published public private(set) var progress: OptimizationProgress?

    /// Optimization result (available when state == .complete)
    @Published public private(set) var result: OptimizationResult?

    /// Whether to replace originals (user toggle)
    @Published public var replaceOriginals: Bool = false

    /// IDs of items selected for optimization
    @Published public var selectedItemIds: Set<UUID> = []

    // MARK: - Dependencies

    private let service: MediaOptimizationServiceProtocol
    private let mediaLibrary: ProjectMediaLibrary
    private let timelineManager: TimelineManager?

    private var optimizationTask: Task<Void, Never>?

    // MARK: - Initialization

    /// Creates an optimization view model.
    ///
    /// - Parameters:
    ///   - service: The optimization service (actor)
    ///   - mediaLibrary: The project's media library
    ///   - timelineManager: Optional timeline manager for updating references
    init(
        service: MediaOptimizationServiceProtocol,
        mediaLibrary: ProjectMediaLibrary,
        timelineManager: TimelineManager? = nil
    ) {
        self.service = service
        self.mediaLibrary = mediaLibrary
        self.timelineManager = timelineManager
    }

    // MARK: - Computed Properties

    /// Formatted total original size
    var totalOriginalSizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: Int64(analysisResult.totalOriginalSize), countStyle: .file)
    }

    /// Formatted estimated optimized size
    var totalOptimizedSizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: Int64(analysisResult.estimatedOptimizedSize), countStyle: .file)
    }

    /// Formatted estimated savings
    var savingsFormatted: String {
        ByteCountFormatter.string(fromByteCount: Int64(analysisResult.estimatedSavings), countStyle: .file)
    }

    /// Savings percentage as string (e.g., "80%")
    var savingsPercentageFormatted: String {
        String(format: "%.0f%%", analysisResult.savingsPercentage * 100)
    }

    /// Number of items that need optimization
    var itemsNeedingOptimizationCount: Int {
        analysisResult.itemsNeedingOptimization.count
    }

    /// Items that are both selected and need optimization
    var selectedItemsToOptimize: [MediaAnalysisItem] {
        analysisResult.itemsNeedingOptimization.filter { selectedItemIds.contains($0.id) }
    }

    /// Number of selected items
    var selectedCount: Int {
        selectedItemsToOptimize.count
    }

    /// Whether all optimizable items are selected
    var allSelected: Bool {
        let optimizableIds = Set(analysisResult.itemsNeedingOptimization.map { $0.id })
        return !optimizableIds.isEmpty && optimizableIds.isSubset(of: selectedItemIds)
    }

    /// Total size of selected items
    var selectedTotalSize: UInt64 {
        selectedItemsToOptimize.reduce(0) { $0 + $1.originalSize }
    }

    /// Estimated size after optimization for selected items
    var selectedEstimatedSize: UInt64 {
        selectedItemsToOptimize.reduce(0) { $0 + $1.estimatedOptimizedSize }
    }

    /// Estimated savings for selected items
    var selectedSavings: UInt64 {
        guard selectedEstimatedSize < selectedTotalSize else { return 0 }
        return selectedTotalSize - selectedEstimatedSize
    }

    /// Formatted selected savings
    var selectedSavingsFormatted: String {
        ByteCountFormatter.string(fromByteCount: Int64(selectedSavings), countStyle: .file)
    }

    /// Whether optimization can start
    var canOptimize: Bool {
        state == .ready && !selectedItemsToOptimize.isEmpty
    }

    /// Current item being processed (for progress display)
    var currentItemName: String {
        progress?.currentItemName ?? ""
    }

    /// Current item progress (0.0 - 1.0)
    var currentItemProgress: Double {
        progress?.currentItemProgress ?? 0
    }

    /// Overall progress (0.0 - 1.0)
    var overallProgress: Double {
        progress?.overallProgress ?? 0
    }

    /// Progress text (e.g., "Optimizing: interview.mov (1 of 3)")
    var progressText: String {
        guard let p = progress else { return "" }
        return "Optimizing: \(p.currentItemName) (\(p.currentItemIndex + 1) of \(p.totalItems))"
    }

    // MARK: - Actions

    /// Start analyzing the project's media files
    func analyze() {
        guard state == .idle || state == .ready || state.isError else { return }

        state = .analyzing
        analysisResult = .empty
        selectedItemIds = []

        Task {
            do {
                let items = mediaLibrary.items
                let result = try await service.analyzeProject(mediaItems: items)
                self.analysisResult = result
                // Auto-select all items that need optimization
                self.selectedItemIds = Set(result.itemsNeedingOptimization.map { $0.id })
                self.state = .ready
            } catch {
                self.state = .error("Analysis failed: \(error.localizedDescription)")
            }
        }
    }

    /// Toggle selection for a specific item
    func toggleSelection(for itemId: UUID) {
        if selectedItemIds.contains(itemId) {
            selectedItemIds.remove(itemId)
        } else {
            selectedItemIds.insert(itemId)
        }
    }

    /// Check if an item is selected
    func isSelected(_ itemId: UUID) -> Bool {
        selectedItemIds.contains(itemId)
    }

    /// Select all optimizable items
    func selectAll() {
        selectedItemIds = Set(analysisResult.itemsNeedingOptimization.map { $0.id })
    }

    /// Deselect all items
    func deselectAll() {
        selectedItemIds = []
    }

    /// Start the optimization process
    func startOptimization() {
        guard canOptimize else { return }

        state = .optimizing
        progress = nil
        result = nil

        let itemsToOptimize = selectedItemsToOptimize
        // Use HandBrake "Very Fast 720p30" equivalent settings
        let options = OptimizationOptions(
            replaceOriginals: replaceOriginals,
            videoTargetWidth: 1280,
            videoTargetHeight: 720,
            videoBitrate: 2_000_000,       // HandBrake CRF 23 equivalent
            audioTargetBitrate: 160_000,   // HandBrake AAC stereo
            maxFrameRate: 30.0             // Cap at 30fps, preserve lower rates
        )

        optimizationTask = Task {
            do {
                let result = try await service.optimizeMedia(
                    items: itemsToOptimize,
                    options: options,
                    progressHandler: { [weak self] progress in
                        await MainActor.run {
                            self?.progress = progress
                        }
                    }
                )

                // Update media library and timeline references
                await updateReferences(from: result)

                self.result = result
                self.state = .complete
            } catch is CancellationError {
                self.state = .idle
            } catch let error as MediaOptimizationError {
                self.state = .error(error.localizedDescription)
            } catch {
                self.state = .error("Optimization failed: \(error.localizedDescription)")
            }
        }
    }

    /// Cancel the current optimization
    func cancel() {
        optimizationTask?.cancel()
        optimizationTask = nil
        Task {
            await service.cancel()
        }
        state = .idle
    }

    /// Reset to initial state
    func reset() {
        cancel()
        state = .idle
        analysisResult = .empty
        progress = nil
        result = nil
    }

    // MARK: - Private Helpers

    private func updateReferences(from result: OptimizationResult) async {
        // Update media library URLs
        for item in result.successfulItems {
            mediaLibrary.updateItemURL(
                id: item.mediaItemId,
                newURL: item.optimizedURL,
                newBookmark: try? item.optimizedURL.bookmarkData(options: .withSecurityScope)
            )
        }

        // Update timeline references if available
        guard let timelineManager = timelineManager else { return }

        for item in result.successfulItems {
            if item.isVideo {
                // Find and update video reels with matching source
                for reel in timelineManager.timeline.videoReels {
                    if reel.sourceURL == item.originalURL {
                        timelineManager.updateVideoReelURL(id: reel.id, newURL: item.optimizedURL)
                    }
                }
            } else {
                // Find and update audio clips with matching source
                for lane in timelineManager.timeline.audioLanes {
                    for clip in lane.clips {
                        if clip.sourceURL == item.originalURL {
                            timelineManager.updateAudioClipURL(clipId: clip.id, inLane: lane.id, newURL: item.optimizedURL)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - State Extension

extension OptimizationViewModel.State {
    var isError: Bool {
        if case .error = self { return true }
        return false
    }
}
