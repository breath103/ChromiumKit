import XCTest

/// End-to-end proof of native unhandled-key delivery (the CEF browser-process
/// fallback for keyboard shortcuts): a Cmd+F / Cmd+P the page does not handle
/// surfaces to `ChromiumWebView.keyboardHandler` via `CefKeyboardHandler::
/// OnKeyEvent`.
///
/// The app is launched with `HELLOCHROMIUM_KEYBOARD_FIXTURE` pointing at a
/// bundled HTML file that autofocuses an input (so the renderer holds keyboard
/// focus). `AppDelegate` wires the keyboard hook to stamp `keyboard:searchInPage`
/// into the window title for an unhandled Cmd+F. Typing Cmd+F and seeing that
/// title proves the native key path works. A live CEF browser + real key routing
/// is required, which is why this is a UI test rather than a headless one.
final class KeyboardUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["HELLOCHROMIUM_STORE_PATH"] =
            NSTemporaryDirectory() + "ck-keyboard-\(UUID().uuidString).sqlite"

        let fixture = try XCTUnwrap(Bundle(for: type(of: self))
            .url(forResource: "keyboard", withExtension: "html")
        )
        app.launchEnvironment["HELLOCHROMIUM_KEYBOARD_FIXTURE"] = fixture.path
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    func testUnhandledCmdFSurfacesNatively() {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        // Click into the window so the CEF renderer holds focus, then type Cmd+F.
        window.click()
        app.typeKey("f", modifierFlags: .command)

        // The page does not handle Cmd+F, so it surfaces via OnKeyEvent and the
        // keyboard hook stamps the title. No stamp would mean the key never
        // reached native.
        let titleIsShortcut = NSPredicate(format: "title == %@", "keyboard:searchInPage")
        let exp = expectation(for: titleIsShortcut, evaluatedWith: window)
        wait(for: [exp], timeout: 15)
    }
}
