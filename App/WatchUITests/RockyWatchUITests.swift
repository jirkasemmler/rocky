import XCTest

/// Watch: start a workout, pause/resume from the controls page. With
/// `TEST_RUNNER_ROCKY_SYNC_HOLD=<s>` the workout is held running so the paired iPhone can be
/// checked (watch -> phone mirroring).
@MainActor
final class RockyWatchUITests: XCTestCase {
    private func expect(_ condition: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(condition, message, file: file, line: line)
    }

    func testStartPauseAndEndOnWatch() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()

        let start = app.buttons["watchStart"]
        expect(start.waitForExistence(timeout: 10))
        start.tap()
        expect(app.staticTexts["Rozcvička"].waitForExistence(timeout: 5))

        if let hold = ProcessInfo.processInfo.environment["ROCKY_SYNC_HOLD"].flatMap(UInt32.init) {
            sleep(hold)
        }

        app.swipeUp() // controls page
        let pause = app.buttons["watchPause"]
        expect(pause.waitForExistence(timeout: 5))
        pause.tap()
        app.swipeDown()
        expect(app.staticTexts["PAUZA"].waitForExistence(timeout: 3))
        app.swipeUp()
        app.buttons["watchPause"].tap()
        app.buttons["watchEnd"].tap()
        expect(app.staticTexts["Ukončeno"].waitForExistence(timeout: 5))
    }
}
