import XCTest

/// Closing a tab deletes its record; the sidebar reacts and the row disappears.
final class CloseTabUITests: XCTestCase {
    func testCloseTabRemovesRow() {
        let app = XCUIApplication()
        app.launchEnvironment["HELLOCHROMIUM_STORE_PATH"] =
            NSTemporaryDirectory() + "ck-close-\(UUID().uuidString).sqlite"
        app.launch()

        let outline = app.outlines.firstMatch
        XCTAssertTrue(outline.waitForExistence(timeout: 10), "sidebar missing")

        // Seeded with one tab; open a second so there's one to close.
        app.buttons["newTabButton"].firstMatch.click()
        let twoRows = NSPredicate(format: "outlineRows.count == 2")
        wait(for: [expectation(for: twoRows, evaluatedWith: outline)], timeout: 10)

        // Right-click the second row → Close tab.
        let secondRow = outline.outlineRows.element(boundBy: 1)
        secondRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        app.menuItems["Close tab"].click()

        let oneRow = NSPredicate(format: "outlineRows.count == 1")
        wait(for: [expectation(for: oneRow, evaluatedWith: outline)], timeout: 10)
        app.terminate()
    }
}
