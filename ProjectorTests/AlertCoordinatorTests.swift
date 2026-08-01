//
//  AlertCoordinatorTests.swift
//  ProjectorTests
//
//  Tests that raising an alert while one is already on screen queues it rather
//  than destroying it. A batch import raises one question per reel, and they
//  used to overwrite each other.
//

import XCTest
import SwiftUI
@testable import Projector

@MainActor
final class AlertCoordinatorTests: XCTestCase {

    /// Lets the coordinator's deferred hand-off to the next alert run.
    private func settle() async {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    // MARK: - Queueing

    func testFirstAlertPresentsImmediately() {
        let coordinator = AlertCoordinator()

        coordinator.show(.error("first"))

        XCTAssertEqual(coordinator.activeAlert?.id, "error")
    }

    func testSecondAlertDoesNotReplaceTheFirst() {
        let coordinator = AlertCoordinator()

        coordinator.show(.error("first"))
        coordinator.show(.duplicateMedia("second"))

        // The user is still reading the first one.
        XCTAssertEqual(coordinator.activeAlert?.id, "error")
    }

    func testDismissingPresentsTheQueuedAlert() async {
        let coordinator = AlertCoordinator()

        coordinator.show(.error("first"))
        coordinator.show(.duplicateMedia("second"))
        coordinator.dismiss()
        await settle()

        XCTAssertEqual(coordinator.activeAlert?.id, "duplicateMedia")
    }

    func testEveryQueuedAlertIsEventuallyShown() async {
        let coordinator = AlertCoordinator()
        let reels = ["R1", "R2", "R3", "R4", "R5", "R6"]

        // Six alerts raised close together, as a batch import can produce.
        for reel in reels {
            coordinator.show(.error(reel))
        }

        var seen = 0
        while coordinator.activeAlert != nil {
            seen += 1
            coordinator.dismiss()
            await settle()
        }

        XCTAssertEqual(seen, reels.count)
    }

    func testQueueDrainsInOrderRaised() async {
        let coordinator = AlertCoordinator()

        coordinator.show(.error("first"))
        coordinator.show(.duplicateMedia("second"))
        coordinator.show(.videoAlreadyInTimeline("third"))

        var order: [String] = []
        while let active = coordinator.activeAlert {
            order.append(active.id)
            coordinator.dismiss()
            await settle()
        }

        XCTAssertEqual(order, ["error", "duplicateMedia", "videoAlreadyInTimeline"])
    }

    // MARK: - Empty Queue

    func testDismissingTheOnlyAlertLeavesNothingPresenting() async {
        let coordinator = AlertCoordinator()

        coordinator.show(.error("only"))
        coordinator.dismiss()
        await settle()

        XCTAssertNil(coordinator.activeAlert)
    }

    func testDismissingWithNothingPresentingIsHarmless() async {
        let coordinator = AlertCoordinator()

        coordinator.dismiss()
        await settle()

        XCTAssertNil(coordinator.activeAlert)
    }

    // MARK: - Sheets

    func testASheetRaisedBehindAnAlertIsQueuedNotDropped() async {
        let coordinator = AlertCoordinator()

        coordinator.show(.error("busy"))
        coordinator.show(.saveProject(content: AnyView(EmptyView())))
        coordinator.dismiss()
        await settle()

        XCTAssertEqual(coordinator.activeAlert?.id, "saveProject")
    }

    func testSheetCasesAreClassifiedAsSheets() {
        XCTAssertTrue(AlertCoordinator.AlertType.saveProject(content: AnyView(EmptyView())).isSheet)
        XCTAssertTrue(AlertCoordinator.AlertType.settings(content: AnyView(EmptyView())).isSheet)
        XCTAssertFalse(AlertCoordinator.AlertType.error("x").isSheet)
        XCTAssertFalse(AlertCoordinator.AlertType.duplicateMedia("x").isSheet)
    }
}
