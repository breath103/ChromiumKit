import XCTest

final class TargetBlankUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Isolate from the real session store: a fresh temp SQLite per run.
        app.launchEnvironment["HELLOCHROMIUM_STORE_PATH"] =
            NSTemporaryDirectory() + "ck-targetblank-\(UUID().uuidString).sqlite"
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    /// Loads a file:// fixture whose entire viewport is a `target=_blank`
    /// link, clicks anywhere inside (real user gesture, required for popup
    /// allowance), and asserts a new row appears in the sidebar.
    func testTargetBlankOpensNewTab() throws {
        let outline = app.outlines.firstMatch
        XCTAssertTrue(outline.waitForExistence(timeout: 10))
        let initialRowCount = outline.outlineRows.count

        let fixtureURL = try XCTUnwrap(Bundle(for: type(of: self))
            .url(forResource: "target-blank", withExtension: "html")
        )

        // Navigate the selected tab to the fixture.
        let display = app.buttons["addressBar.display"]
        XCTAssertTrue(display.waitForExistence(timeout: 5))
        display.click()

        let field = app.textFields["addressBar.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        field.typeKey("a", modifierFlags: .command)
        field.typeText(fixtureURL.absoluteString)
        field.typeKey(.return, modifierFlags: [])

        // Give the page a moment to render, then click somewhere inside it.
        Thread.sleep(forTimeInterval: 1.5)
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.6))
            .click()

        let expectedRowCount = NSPredicate(format: "outlineRows.count == %d", initialRowCount + 1)
        let exp = expectation(for: expectedRowCount, evaluatedWith: outline)
        wait(for: [exp], timeout: 10)
    }
}
