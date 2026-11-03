import XCTest

/// Walks every iPhone screen and saves screenshots for manual review. Skipped unless run with
/// `TEST_RUNNER_ROCKY_SCREENSHOT_DIR=/some/dir xcodebuild test -only-testing:RockyUITests/ScreenshotTour`.
@MainActor
final class ScreenshotTour: XCTestCase {
    private var dir: URL!
    private var app: XCUIApplication!

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["ROCKY_SCREENSHOT_DIR"] else {
            throw XCTSkip("ROCKY_SCREENSHOT_DIR not set")
        }
        dir = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func shot(_ name: String) {
        sleep(1)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: dir.appendingPathComponent(name + ".png"))
    }

    private func launch(_ extra: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = ["-uiTesting"] + extra
        app.launch()
    }

    func testTourFreshPlan() {
        launch()
        _ = app.navigationBars["Rocky"].waitForExistence(timeout: 5)
        shot("01-home")
        app.swipeUp(); shot("02-home-scrolled"); app.swipeDown()
        (app.buttons["startToday"].exists ? app.buttons["startToday"] : app.buttons["startBonus"]).tap()
        shot("03-preview")
        app.swipeUp(); app.swipeUp(); shot("04-preview-bottom")
        app.buttons["startWorkout"].tap()
        _ = app.staticTexts["phaseTitle"].waitForExistence(timeout: 5)
        shot("05-running-warmup")
        app.buttons["skipButton"].tap(); shot("06-running-exercise")
        app.buttons["skipButton"].tap(); shot("07-running-rest")
        app.buttons["pauseButton"].tap(); shot("08-running-paused")
        app.buttons["pauseButton"].tap()
        app.buttons["Checklist"].tap(); sleep(1); shot("09-checklist")
        app.buttons["Hotovo"].tap()
        app.buttons["endWorkout"].tap(); shot("10-end-confirm")
        app.buttons["Ukončit"].tap()
        _ = app.buttons["difficulty4"].waitForExistence(timeout: 5)
        app.buttons["difficulty4"].tap()
        shot("11-summary")
        app.swipeUp(); shot("12-summary-bottom")
        app.buttons["saveSession"].tap()
        _ = app.navigationBars["Rocky"].waitForExistence(timeout: 5)
        shot("13-home-after-save")
        app.tabBars.buttons["Historie"].tap(); shot("14-history")
        app.cells.element(boundBy: app.cells.count - 1).tap(); shot("15-session-detail")
        app.tabBars.buttons["Nastavení"].tap(); shot("16-settings")
        app.swipeUp(); shot("17-settings-2")
        app.swipeUp(); shot("18-settings-3")
        app.swipeUp(); shot("19-settings-4")
    }

    func testTourDebt() {
        launch(["-uiTestingPlanStartDaysAgo", "8"])
        _ = app.navigationBars["Rocky"].waitForExistence(timeout: 5)
        shot("20-home-long-debt")
        app.buttons["postpone"].tap(); shot("21-postpone-menu")
        app.buttons["Cestování"].firstMatch.exists ? () : ()
        app.tap() // dismiss menu
        app.buttons["startToday"].tap(); shot("22-preview-catchup")
    }

    func testTourShortDebt() {
        // Plan started yesterday or 2 days ago -> at most one fresh missed slot.
        for days in [1, 2, 3] {
            launch(["-uiTestingPlanStartDaysAgo", String(days)])
            _ = app.navigationBars["Rocky"].waitForExistence(timeout: 5)
            shot("23-home-start-\(days)-days-ago")
            app.terminate()
        }
    }
}
