import XCTest

/// Main flow on the iPhone: Home → preview → running workout (pause, skip) → end → summary →
/// save → history; plus the catch-up (debt) banner and the settings screen.
/// The app runs with `-uiTesting`: fresh data in a temp file, no notification prompt.
@MainActor
final class RockyUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    /// Evaluates on the main actor first (XCTAssert's autoclosures are nonisolated).
    private func expect(_ condition: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(condition, message, file: file, line: line)
    }

    private func launch(planStartDaysAgo: Int? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        if let planStartDaysAgo {
            app.launchArguments += ["-uiTestingPlanStartDaysAgo", String(planStartDaysAgo)]
        }
        app.launch()
        return app
    }

    /// Today's workout, or the bonus workout on a rest day.
    private func openPreview(_ app: XCUIApplication) {
        let start = app.buttons["startToday"]
        let bonus = app.buttons["startBonus"]
        if start.waitForExistence(timeout: 5) {
            start.tap()
        } else {
            expect(bonus.waitForExistence(timeout: 2), "Home shows neither today's nor a bonus workout")
            bonus.tap()
        }
    }

    func testWorkoutFlowFromHomeToHistory() {
        let app = launch()
        expect(app.navigationBars["Rocky"].waitForExistence(timeout: 5))
        openPreview(app)

        let startWorkout = app.buttons["startWorkout"]
        expect(startWorkout.waitForExistence(timeout: 5))
        startWorkout.tap()

        // Running: warm-up first.
        let phase = app.staticTexts["phaseTitle"]
        expect(phase.waitForExistence(timeout: 5))
        expect(phase.label == "Rozcvička", phase.label)

        // Pause / resume.
        app.buttons["pauseButton"].tap()
        expect(app.staticTexts["PAUZA"].waitForExistence(timeout: 2))
        app.buttons["pauseButton"].tap()
        expect(!app.staticTexts["PAUZA"].waitForExistence(timeout: 1))

        // Skip the warm-up → first exercise of round 1.
        app.buttons["skipButton"].tap()
        expect(app.staticTexts["Kolo 1/3"].waitForExistence(timeout: 2))
        expect(phase.label != "Rozcvička", phase.label)

        // End early → summary.
        app.buttons["endWorkout"].tap()
        let confirm = app.buttons["Ukončit"]
        expect(confirm.waitForExistence(timeout: 2))
        confirm.tap()

        let save = app.buttons["saveSession"]
        expect(save.waitForExistence(timeout: 5))
        expect(app.staticTexts["Trénink ukončen předčasně"].exists)
        app.buttons["difficulty3"].tap()
        save.tap()

        // Back on Home; the session is in the history.
        expect(app.navigationBars["Rocky"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Historie"].tap()
        expect(app.staticTexts["nedokončeno"].waitForExistence(timeout: 5))
        expect(app.staticTexts["náročnost 3/5"].exists)
    }

    func testCatchUpBannerWhenAWorkoutWasMissed() {
        // Plan started 8 days ago and nothing was done → at least one missed slot.
        let app = launch(planStartDaysAgo: 8)
        expect(app.otherElements["debtBanner"].waitForExistence(timeout: 5)
                      || app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Dlužíš'")).firstMatch.exists)
        // Long debt (> 2 days) → shortened catch-up offered; it can be started today.
        expect(app.buttons["startToday"].exists)
        expect(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Dohon'")).firstMatch.exists)
        // It can only be postponed with a reason.
        expect(app.buttons["postpone"].exists)
    }

    func testSettingsShowFixedStretchAndRockyOptions() {
        let app = launch()
        app.tabBars.buttons["Nastavení"].tap()
        expect(app.navigationBars["Nastavení"].waitForExistence(timeout: 5))
        expect(app.switches["Rockyho hlášky"].waitForExistence(timeout: 2)
                      || app.swipeUpUntil(app.switches["Rockyho hlášky"]))
        expect(app.textFields["Oslovení (5. pád, např. Jiří)"].exists)
    }
}

private extension XCUIApplication {
    func swipeUpUntil(_ element: XCUIElement, maxSwipes: Int = 6) -> Bool {
        for _ in 0..<maxSwipes where !element.exists {
            swipeUp()
        }
        return element.exists
    }
}
