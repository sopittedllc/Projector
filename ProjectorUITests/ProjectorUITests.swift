import XCTest

final class ProjectorUITests: XCTestCase {
    func testWaveformRendersAndSurvivesZoom() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()

        app.activate()

        let window = app.windows.firstMatch
        guard window.waitForExistence(timeout: 10) else {
            throw XCTSkip("UI automation window not found. Enable Accessibility permissions for Xcode/ProjectorUITests-Runner.")
        }

        let status = window.staticTexts["ui-test-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline && !status.label.hasPrefix("clip-added") {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(status.label.hasPrefix("clip-added"), "UI test status: \(status.label)")

        let clipCount = window.staticTexts["ui-test-clip-count"]
        XCTAssertTrue(clipCount.waitForExistence(timeout: 5))
        XCTAssertTrue((Int(clipCount.label) ?? 0) > 0, "UI test clip count: \(clipCount.label)")

        let clip = window.descendants(matching: .any)
            .matching(identifier: "audio-clip")
            .firstMatch
        XCTAssertTrue(clip.waitForExistence(timeout: 15))

        let waveform = window.descendants(matching: .any)
            .matching(identifier: "audio-waveform")
            .firstMatch
        let loading = window.descendants(matching: .any)
            .matching(identifier: "audio-waveform-loading")
            .firstMatch
        let waveformVisible = waveform.waitForExistence(timeout: 10)
        let loadingVisible = loading.waitForExistence(timeout: 2)
        XCTAssertTrue(waveformVisible || loadingVisible)

        let zoomIn = window.buttons["Zoom in"]
        XCTAssertTrue(zoomIn.waitForExistence(timeout: 5))
        zoomIn.click()

        XCTAssertTrue(clip.waitForExistence(timeout: 5))
    }
}
