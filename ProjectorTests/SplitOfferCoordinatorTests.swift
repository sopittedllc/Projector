//
//  SplitOfferCoordinatorTests.swift
//  ProjectorTests
//
//  Tests that an import's split offers are released once, as one batch, and
//  that a batch cannot be left open by a file that never imported.
//

import XCTest
@testable import Projector

@MainActor
final class SplitOfferCoordinatorTests: XCTestCase {

    private func candidate(_ name: String, correlation: Float = 0) -> SplitCandidate {
        SplitCandidate(
            id: UUID(), displayName: name,
            laneId: UUID(), clipId: UUID(), correlation: correlation
        )
    }

    // MARK: - Batching

    func testBatchIsHeldUntilEveryFileReports() {
        let coordinator = SplitOfferCoordinator()
        coordinator.expect(3)

        XCTAssertNil(coordinator.finish(candidate: candidate("R1")))
        XCTAssertNil(coordinator.finish(candidate: candidate("R2")))

        let released = coordinator.finish(candidate: candidate("R3"))
        XCTAssertEqual(released?.count, 3)
    }

    func testFilesThatAreNotHardPannedStillCloseTheBatch() {
        let coordinator = SplitOfferCoordinator()
        coordinator.expect(3)

        XCTAssertNil(coordinator.finish(candidate: candidate("R1")))
        XCTAssertNil(coordinator.finish(candidate: nil))

        let released = coordinator.finish(candidate: nil)
        XCTAssertEqual(released?.map(\.displayName), ["R1"])
    }

    func testABatchWithNothingToOfferReleasesNothing() {
        let coordinator = SplitOfferCoordinator()
        coordinator.expect(2)

        XCTAssertNil(coordinator.finish(candidate: nil))
        XCTAssertNil(coordinator.finish(candidate: nil),
                     "an import where nothing was hard panned must not raise a dialog")
    }

    func testCandidatesAreOrderedLeastAmbiguousFirst() {
        let coordinator = SplitOfferCoordinator()
        coordinator.expect(3)

        _ = coordinator.finish(candidate: candidate("loose", correlation: 0.18))
        _ = coordinator.finish(candidate: candidate("tight", correlation: -0.001))
        let released = coordinator.finish(candidate: candidate("middling", correlation: 0.05))

        XCTAssertEqual(released?.map(\.displayName), ["tight", "middling", "loose"])
    }

    // MARK: - Single Imports

    func testAReportWithNoDeclaredBatchStandsAlone() {
        let coordinator = SplitOfferCoordinator()

        // A single-file import never declares a count.
        let released = coordinator.finish(candidate: candidate("R1"))

        XCTAssertEqual(released?.count, 1)
    }

    // MARK: - Reuse

    func testASecondImportStartsACleanBatch() {
        let coordinator = SplitOfferCoordinator()
        coordinator.expect(1)
        _ = coordinator.finish(candidate: candidate("first"))

        coordinator.expect(1)
        let second = coordinator.finish(candidate: candidate("second"))

        XCTAssertEqual(second?.map(\.displayName), ["second"],
                       "the previous import's reels must not reappear")
    }

    func testResetDropsEverythingGathered() {
        let coordinator = SplitOfferCoordinator()
        coordinator.expect(2)
        _ = coordinator.finish(candidate: candidate("R1"))

        coordinator.reset()

        XCTAssertNil(coordinator.finish(candidate: nil),
                     "a reset batch must not release the reels it had collected")
    }
}
