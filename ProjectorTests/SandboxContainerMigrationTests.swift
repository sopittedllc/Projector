//
//  SandboxContainerMigrationTests.swift
//  ProjectorTests
//

import XCTest
@testable import Projector

final class SandboxContainerMigrationTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var containerPlist: URL!

    override func setUp() {
        super.setUp()
        suiteName = "SandboxContainerMigrationTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        containerPlist = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(suiteName!).plist")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: containerPlist)
        super.tearDown()
    }

    private func writeContainer(_ settings: [String: Any]) {
        (settings as NSDictionary).write(to: containerPlist, atomically: true)
    }

    func testContainerSettingsReplaceStaleGlobalOnes() {
        defaults.set("Old Device", forKey: "selectedAudioOutput")
        writeContainer(["selectedAudioOutput": "Current Device", "hasCompletedWelcome": true])

        let copied = SandboxContainerMigration.migrateIfNeeded(defaults: defaults, containerPreferencesURL: containerPlist)

        XCTAssertEqual(copied, 2)
        XCTAssertEqual(defaults.string(forKey: "selectedAudioOutput"), "Current Device")
        XCTAssertTrue(defaults.bool(forKey: "hasCompletedWelcome"))
    }

    func testRunsOnlyOnce() {
        writeContainer(["selectedAudioOutput": "Current Device"])
        SandboxContainerMigration.migrateIfNeeded(defaults: defaults, containerPreferencesURL: containerPlist)

        // A change made after migrating must survive the next launch.
        defaults.set("Changed Later", forKey: "selectedAudioOutput")
        let copied = SandboxContainerMigration.migrateIfNeeded(defaults: defaults, containerPreferencesURL: containerPlist)

        XCTAssertEqual(copied, 0)
        XCTAssertEqual(defaults.string(forKey: "selectedAudioOutput"), "Changed Later")
    }

    func testMissingContainerMarksMigrationDone() {
        let copied = SandboxContainerMigration.migrateIfNeeded(defaults: defaults, containerPreferencesURL: containerPlist)

        XCTAssertEqual(copied, 0)
        XCTAssertTrue(defaults.bool(forKey: SandboxContainerMigration.completedKey))
    }
}
