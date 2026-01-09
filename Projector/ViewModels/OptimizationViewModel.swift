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


    /// IDs of items selected for optimization
    @Published public var selectedItemIds: Set<UUID> = []

    // MARK: - Dependencies

    private let service: MediaOptimizationServiceProtocol
    private let mediaLibrary: ProjectMediaLibrary
    private let timelineManager: TimelineManager?

    /// The project document (observed for fileURL changes after save)
    /// Note: Not weak because we need it to persist for the lifetime of the ViewModel
    private let projectDocument: ProjectDocument

    private var optimizationTask: Task<Void, Never>?

    // MARK: - Initialization

    /// Creates an optimization view model.
    ///
    /// - Parameters:
    ///   - service: The optimization service (actor)
    ///   - mediaLibrary: The project's media library
    ///   - projectDocument: The project document (used to get fileURL, which updates after save)
    ///   - timelineManager: Optional timeline manager for updating references
    init(
        service: MediaOptimizationServiceProtocol,
        mediaLibrary: ProjectMediaLibrary,
        projectDocument: ProjectDocument,
        timelineManager: TimelineManager? = nil
    ) {
        self.service = service
        self.mediaLibrary = mediaLibrary
        self.projectDocument = projectDocument
        self.timelineManager = timelineManager
    }

    /// The project file URL (nil if project not saved yet)
    /// Computed from projectDocument to reflect saves that happen while sheet is open
    var projectURL: URL? {
        projectDocument.fileURL
    }

    /// Whether the project has been saved (required for optimization)
    var isProjectSaved: Bool {
        projectURL != nil
    }

    /// The "Optimized Media" folder URL (sibling of the .projector file)
    /// Structure: ProjectFolder/Optimized Media/ (not inside .projector package)
    var optimizedMediaFolderURL: URL? {
        projectURL?.deletingLastPathComponent().appendingPathComponent("Optimized Media")
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

    /// Whether optimization can start (requires saved project and selected items)
    var canOptimize: Bool {
        state == .ready && !selectedItemsToOptimize.isEmpty && isProjectSaved
    }

    /// Reason why optimization cannot start
    var cannotOptimizeReason: String? {
        if !isProjectSaved {
            return "Save your project first to enable optimization"
        }
        if selectedItemsToOptimize.isEmpty {
            return "Select files to optimize"
        }
        return nil
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
        guard state == .idle || state == .ready || state.isError else {
            NSLog(">>> OptimizationViewModel.analyze: skipped - current state: \(state)")
            return
        }

        NSLog(">>> OptimizationViewModel.analyze: starting analysis")
        state = .analyzing
        analysisResult = .empty
        selectedItemIds = []

        Task {
            do {
                let items = mediaLibrary.items
                NSLog(">>> OptimizationViewModel.analyze: analyzing \(items.count) items")
                let result = try await service.analyzeProject(mediaItems: items)
                self.analysisResult = result
                // Auto-select all items that need optimization
                self.selectedItemIds = Set(result.itemsNeedingOptimization.map { $0.id })
                NSLog(">>> OptimizationViewModel.analyze: complete - \(result.itemsNeedingOptimization.count) items need optimization")
                self.state = .ready
            } catch {
                NSLog(">>> OptimizationViewModel.analyze: error - \(error.localizedDescription)")
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
        guard canOptimize else {
            NSLog(">>> OptimizationViewModel.startOptimization: cannot optimize - canOptimize=false")
            return
        }

        NSLog(">>> OptimizationViewModel.startOptimization: starting optimization")
        state = .optimizing
        progress = nil
        result = nil

        let itemsToOptimize = selectedItemsToOptimize
        NSLog(">>> OptimizationViewModel.startOptimization: \(itemsToOptimize.count) items to optimize")

        // Ensure we have a valid optimized media folder URL
        guard let optimizedFolderURL = optimizedMediaFolderURL else {
            NSLog(">>> OptimizationViewModel.startOptimization: cannot optimize - no optimizedMediaFolderURL")
            state = .error("Project must be saved before optimizing media")
            return
        }

        // Use HandBrake "Very Fast 720p30" equivalent settings
        let options = OptimizationOptions(
            optimizedMediaFolderURL: optimizedFolderURL,
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

                NSLog(">>> OptimizationViewModel.startOptimization: optimization complete - updating references")
                // Update media library and timeline references
                await updateReferences(from: result)

                NSLog(">>> OptimizationViewModel.startOptimization: setting state to complete - optimized: \(result.optimizedCount), failed: \(result.failedCount)")
                self.result = result
                self.state = .complete
            } catch is CancellationError {
                NSLog(">>> OptimizationViewModel.startOptimization: cancelled")
                self.state = .idle
            } catch let error as MediaOptimizationError {
                NSLog(">>> OptimizationViewModel.startOptimization: MediaOptimizationError - \(error.localizedDescription)")
                self.state = .error(error.localizedDescription)
            } catch {
                NSLog(">>> OptimizationViewModel.startOptimization: error - \(error.localizedDescription)")
                self.state = .error("Optimization failed: \(error.localizedDescription)")
            }
        }
    }

    /// Cancel the current optimization
    func cancel() {
        NSLog(">>> OptimizationViewModel.cancel: called")
        NSLog(">>> OptimizationViewModel.cancel: stack trace: \(Thread.callStackSymbols.prefix(10).joined(separator: "\n"))")
        optimizationTask?.cancel()
        optimizationTask = nil
        Task {
            await service.cancel()
        }
        state = .idle
    }

    /// Reset to initial state
    func reset() {
        NSLog(">>> OptimizationViewModel.reset: called")
        NSLog(">>> OptimizationViewModel.reset: stack trace: \(Thread.callStackSymbols.prefix(10).joined(separator: "\n"))")
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
