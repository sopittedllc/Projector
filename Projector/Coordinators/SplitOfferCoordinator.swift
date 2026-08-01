//
//  SplitOfferCoordinator.swift
//  Projector
//
//  Gathers hard-panned reels across an import so the user is asked once for the
//  whole drop instead of once per reel.
//

import Foundation

/// A reel that analysed as hard panned and could be split.
struct SplitCandidate: Identifiable, Sendable {
    /// The reel's id, which is also this candidate's identity.
    let id: UUID

    /// Name shown in the offer list.
    let displayName: String

    /// Lane currently holding the reel's video audio.
    let laneId: UUID

    /// That reel's clip on the lane - the one a split would move.
    let clipId: UUID

    /// Correlation between the channels, for ordering the least ambiguous first.
    let correlation: Float
}

/// Collects hard-panned reels found during an import and releases them together.
///
/// Reels are analysed on their own detached tasks, so without this each one
/// would restructure the timeline the moment its own analysis landed - lanes
/// appearing one pair at a time across a long import. Holding them until the
/// whole import has reported lets the split happen once, as a single change the
/// user can undo in one step.
///
/// ## How a batch is bounded
///
/// An import declares how many files it is about to bring in with `expect(_:)`,
/// and every one of those reports back through `finish(candidate:)` - passing
/// `nil` when the reel turned out not to be hard panned, or had no audio at all.
/// The batch is complete when the last one reports, which is when `finish`
/// returns the collected candidates.
///
/// Counting is what makes this exact. Waiting a fixed interval after the last
/// candidate would split a drop into two dialogs whenever one reel's extraction
/// ran long, which is routine when a short reel is dropped alongside a feature.
@MainActor
final class SplitOfferCoordinator: ObservableObject {

    // MARK: - State

    /// Imports still to report.
    private var outstanding = 0

    /// Hard-panned reels gathered so far.
    private var candidates: [SplitCandidate] = []

    // MARK: - Methods

    /// Declare how many files an import is about to bring in.
    ///
    /// Called before the import starts, so a batch cannot be considered complete
    /// part-way through: a reel whose extraction finishes before the next one
    /// begins would otherwise look like the end of the drop.
    ///
    /// - Parameter count: Number of files that will report back.
    func expect(_ count: Int) {
        guard count > 0 else { return }
        outstanding += count
    }

    /// Report one import's result.
    ///
    /// - Parameter candidate: The reel if it is hard panned, `nil` otherwise.
    /// - Returns: Every candidate in the batch once the last import reports,
    ///   ordered least ambiguous first; `nil` while the batch is still running,
    ///   and `nil` if the batch finished with nothing hard panned.
    func finish(candidate: SplitCandidate?) -> [SplitCandidate]? {
        if let candidate {
            candidates.append(candidate)
        }

        // A report with nothing outstanding means the count was never declared;
        // treat the candidate as its own batch rather than holding it forever.
        guard outstanding > 0 else {
            return releaseIfAny()
        }

        outstanding -= 1
        guard outstanding == 0 else { return nil }
        return releaseIfAny()
    }

    /// Drop everything gathered so far.
    ///
    /// Used when a project is closed mid-import, so offers for reels that are no
    /// longer on the timeline cannot surface against the next one.
    func reset() {
        outstanding = 0
        candidates = []
    }

    // MARK: - Helpers

    private func releaseIfAny() -> [SplitCandidate]? {
        defer { candidates = [] }
        guard !candidates.isEmpty else { return nil }
        // Strongest evidence first: the nearer correlation is to zero, the less
        // room there is to argue the reel is just a wide stereo mix.
        return candidates.sorted { abs($0.correlation) < abs($1.correlation) }
    }
}
