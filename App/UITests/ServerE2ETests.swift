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
        let tokenField = app.secureTextFields["serverToken"]
        tokenField.tap()
        tokenField.typeText(token)
        app.buttons["Připojit"].tap()

        // Catalog from the server (revision ≥ 1) and a successful sync.
        let revision = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'revize'")).firstMatch
        expect(revision.waitForExistence(timeout: 20), "catalog revision from the server")
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
        let startWorkout = app.buttons["startWorkout"]
        for _ in 0..<6 where !startWorkout.exists { app.swipeUp() }
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
        let pending = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Čeká na odeslání'")).firstMatch
        expect(!pending.exists, "outbox should be empty after sync")
        let error = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'selhala' OR label CONTAINS 'odmítl'")).firstMatch
        expect(!error.exists, error.exists ? error.label : "")
    }
}
