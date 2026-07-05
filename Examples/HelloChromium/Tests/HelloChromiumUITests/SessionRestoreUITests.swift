import XCTest

/// End-to-end proof of persistence: a tab opened in one launch is restored in
/// the next, because both launches share one SQLite store path.
final class SessionRestoreUITests: XCTestCase {
    func testTabsRestoreAcrossRelaunch() {
        let storePath = NSTemporaryDirectory() + "ck-restore-\(UUID().uuidString).sqlite"
        let app = XCUIApplication()
        app.launchEnvironment["HELLOCHROMIUM_STORE_PATH"] = storePath

        // First launch: seeded with one tab. Open a second.
        app.launch()
        let outline = app.outlines.firstMatch
        XCTAssertTrue(outline.waitForExistence(timeout: 10), "sidebar missing")
        XCTAssertEqual(outline.outlineRows.count, 1, "seeded session should have one tab")

        app.buttons["newTabButton"].firstMatch.click()
        let twoRows = NSPredicate(format: "outlineRows.count == 2")
        wait(for: [expectation(for: twoRows, evaluatedWith: outline)], timeout: 10)
        app.terminate()

        // Second launch against the same store: both tabs come back.
        app.launch()
        let restoredOutline = app.outlines.firstMatch
        XCTAssertTrue(restoredOutline.waitForExistence(timeout: 10), "sidebar missing after relaunch")
        let stillTwoRows = NSPredicate(format: "outlineRows.count == 2")
        wait(for: [expectation(for: stillTwoRows, evaluatedWith: restoredOutline)], timeout: 10)
        app.terminate()
    }
}
