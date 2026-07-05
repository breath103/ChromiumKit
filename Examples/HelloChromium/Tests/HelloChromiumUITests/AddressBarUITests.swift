import XCTest

final class AddressBarUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Isolate from the real session store: a fresh temp SQLite per run, so
        // the app starts from its seeded single-tab state, deterministically.
        app.launchEnvironment["HELLOCHROMIUM_STORE_PATH"] =
            NSTemporaryDirectory() + "ck-addressbar-\(UUID().uuidString).sqlite"
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    /// 1. Idle state shows the title-bearing display button.
    /// 2. Clicking it reveals the URL text field.
    /// 3. Typing + Enter dismisses the field (proxy for "submitted").
    func testFocusToEditFlow() {
        // Wait for at least one CEF page to finish loading so the title is set.
        let display = app.buttons["addressBar.display"]
        XCTAssertTrue(display.waitForExistence(timeout: 10), "display button missing")

        // Click → switch to edit mode.
        display.click()

        let field = app.textFields["addressBar.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 2), "text field did not appear on click")
        let seeded = (field.value as? String) ?? ""
        XCTAssertFalse(seeded.isEmpty, "field should be seeded with current URL, got: \(seeded)")

        // Replace + submit.
        // Select-all then type to overwrite whatever was seeded.
        field.typeKey("a", modifierFlags: .command)
        field.typeText("example.com")
        field.typeKey(.return, modifierFlags: [])

        // Submitting flips fieldFocused back to false → display button returns.
        XCTAssertTrue(display.waitForExistence(timeout: 3), "display button did not return after submit")
    }

    /// Esc cancels: bar returns to display state without navigating.
    func testEscapeCancelsEdit() {
        let display = app.buttons["addressBar.display"]
        XCTAssertTrue(display.waitForExistence(timeout: 10))
        display.click()

        let field = app.textFields["addressBar.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 2))

        field.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(display.waitForExistence(timeout: 2), "Esc should return to display state")
    }
}
