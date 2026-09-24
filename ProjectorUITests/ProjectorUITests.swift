import XCTest

final class ProjectorUITests: XCTestCase {
    private func waitUntilGone(_ element: XCUIElement) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter.wait(for: [gone], timeout: 5) == .completed
    }

    func testPlayerFullScreenAndPopOutAreSeparatePresentations() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        app.activate()
        let fullScreen = app.buttons["player-enter-full-screen"]
        XCTAssertTrue(fullScreen.waitForExistence(timeout: 10))
        let mainWindow = app.windows.containing(.button, identifier: "player-enter-full-screen").firstMatch
        let mainFrame = mainWindow.frame
        let presentation = app.windows["player-full-screen"]
        let popOut = app.windows["player-pop-out"]

        fullScreen.click()
        XCTAssertTrue(presentation.waitForExistence(timeout: 5))
        XCTAssertTrue(presentation.frame.contains(CGPoint(x: mainFrame.midX, y: mainFrame.midY)),
                      "Fullscreen must cover the display containing its source window")
        XCTAssertFalse(popOut.exists)
        let fullScreenShot = XCTAttachment(screenshot: presentation.screenshot())
        fullScreenShot.name = "Fullscreen before hovering controls"
        fullScreenShot.lifetime = .keepAlways
        add(fullScreenShot)
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(waitUntilGone(presentation))
        XCTAssertFalse(popOut.exists)
        XCTAssertEqual(mainWindow.frame, mainFrame)

        fullScreen.click()
        XCTAssertTrue(presentation.waitForExistence(timeout: 5))
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitUntilGone(presentation))
        XCTAssertFalse(popOut.exists)

        fullScreen.click()
        XCTAssertTrue(presentation.waitForExistence(timeout: 5))
        presentation.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.01)).hover()
        let hoverClose = presentation.buttons["player-full-screen-close"]
        XCTAssertTrue(hoverClose.waitForExistence(timeout: 5))
        let hoverShot = XCTAttachment(screenshot: presentation.screenshot())
        hoverShot.name = "Fullscreen with hover window controls"
        hoverShot.lifetime = .keepAlways
        add(hoverShot)
        hoverClose.click()
        XCTAssertTrue(waitUntilGone(presentation))
        XCTAssertFalse(popOut.exists)

        app.buttons["player-pop-out-button"].click()
        XCTAssertTrue(popOut.waitForExistence(timeout: 5))
        let popOutFrame = popOut.frame
        let popOutShot = XCTAttachment(screenshot: popOut.screenshot())
        popOutShot.name = "Resizable pop-out with standard title bar"
        popOutShot.lifetime = .keepAlways
        add(popOutShot)
        popOut.buttons[XCUIIdentifierFullScreenWindow].click()
        XCTAssertTrue(presentation.waitForExistence(timeout: 5))
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(waitUntilGone(presentation))
        XCTAssertFalse(popOut.exists)
        app.buttons["player-pop-out-button"].click()
        XCTAssertTrue(popOut.waitForExistence(timeout: 5))
        XCTAssertEqual(popOut.frame.size, popOutFrame.size)
        popOut.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(waitUntilGone(popOut))
        XCTAssertTrue(mainWindow.exists)
    }

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
