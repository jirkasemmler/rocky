import XCTest

/// End-to-end against a running Rocky server. Skipped unless
/// `TEST_RUNNER_ROCKY_SERVER_URL` and `TEST_RUNNER_ROCKY_SERVER_TOKEN` (device token) are set.
@MainActor
final class ServerE2ETests: XCTestCase {
    private func expect(_ condition: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(condition, message, file: file, line: line)
    }

    func testConnectSyncCatalogAndUploadWorkout() throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["ROCKY_SERVER_URL"], let token = env["ROCKY_SERVER_TOKEN"] else {
            throw XCTSkip("ROCKY_SERVER_URL / ROCKY_SERVER_TOKEN not set")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()

        // Connect in Settings → Server.
        app.tabBars.buttons["Nastavení"].tap()
        let urlField = app.textFields["serverURL"]
        for _ in 0..<8 where !urlField.exists { app.swipeUp() }
        expect(urlField.exists, "server URL field")
        urlField.tap()
        urlField.typeText(url)
        let tokenField = app.textFields["serverToken"]
        tokenField.tap()
        tokenField.typeText(token + "\n") // also dismisses the keyboard
        app.buttons["Připojit"].tap()
        // In case iOS still offers to save the token as a password.
        let notNow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Not Now"]
        if notNow.waitForExistence(timeout: 2) { notNow.tap() }
        if app.buttons["Not Now"].exists { app.buttons["Not Now"].tap() }

        // Catalog from the server (revision ≥ 1) and a successful sync.
        let revision = app.descendants(matching: .any)["catalogRevision"]
        expect(revision.waitForExistence(timeout: 20), "catalog row")
        expect(app.staticTexts["revize 1"].exists || revision.label.contains("revize"), revision.label)
        expect(app.buttons["syncNow"].exists)
        if let screenshotDir = env["ROCKY_SCREENSHOT_DIR"] {
            try? XCUIScreen.main.screenshot().pngRepresentation
                .write(to: URL(fileURLWithPath: screenshotDir).appendingPathComponent("30-settings-server.png"))
        }

        // A short workout: start, end early, save → uploaded.
        app.tabBars.buttons["Dnes"].tap()
        let start = app.buttons["startToday"].exists ? app.buttons["startToday"] : app.buttons["startBonus"]
        expect(start.waitForExistence(timeout: 5))
        start.tap()
        if let screenshotDir = env["ROCKY_SCREENSHOT_DIR"] {
            sleep(1)
            try? XCUIScreen.main.screenshot().pngRepresentation
                .write(to: URL(fileURLWithPath: screenshotDir).appendingPathComponent("31-after-start-tap.png"))
        }
        let startWorkout = app.buttons["startWorkout"]
        for _ in 0..<6 where !startWorkout.exists { app.swipeUp() }
        expect(startWorkout.waitForExistence(timeout: 5), "preview start button")
        if let screenshotDir = env["ROCKY_SCREENSHOT_DIR"] {
            app.swipeDown(); app.swipeDown()
            sleep(1)
            try? XCUIScreen.main.screenshot().pngRepresentation
                .write(to: URL(fileURLWithPath: screenshotDir).appendingPathComponent("32-preview-from-server.png"))
            let squat = app.buttons["exercise-squat"]
            if squat.exists {
                squat.tap()
                sleep(1)
                try? XCUIScreen.main.screenshot().pngRepresentation
                    .write(to: URL(fileURLWithPath: screenshotDir).appendingPathComponent("33-exercise-detail.png"))
                app.navigationBars.buttons.firstMatch.tap()
            }
            for _ in 0..<6 where !startWorkout.isHittable { app.swipeUp() }
        }
        startWorkout.tap()
        expect(app.buttons["doneButton"].waitForExistence(timeout: 5))
        app.buttons["doneButton"].tap() // warm-up done
        app.buttons["endWorkout"].tap()
        app.buttons["Ukončit"].tap()
        expect(app.buttons["difficulty2"].waitForExistence(timeout: 5))
        app.buttons["difficulty2"].tap()
        let save = app.buttons["saveSession"]
        for _ in 0..<4 where !save.exists { app.swipeUp() }
        save.tap()

        // Wait for the debounced sync, then check Settings shows nothing pending.
        sleep(5)
        app.tabBars.buttons["Nastavení"].tap()
        let syncNow = app.buttons["syncNow"]
        for _ in 0..<8 where !syncNow.exists { app.swipeUp() }
        syncNow.tap()
        sleep(3)
        expect(!app.staticTexts["syncPending"].exists, "outbox should be empty after sync")
        let error = app.staticTexts["syncError"]
        expect(!error.exists, error.exists ? error.label : "")
    }
}
