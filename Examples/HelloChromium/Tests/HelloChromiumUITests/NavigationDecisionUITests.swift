import XCTest

/// End-to-end proof of CEF navigation-policy interception (the
/// `WKNavigationDelegate.decidePolicyFor navigationAction` analogue): a
/// main-frame navigation the app decides to cancel is stopped before it commits
/// via `ChromiumWebView.navigationDecisionHandler` →
/// `CefRequestHandler::OnBeforeBrowse`.
///
/// The app is launched with `HELLOCHROMIUM_NAVBLOCK_FIXTURE` pointing at a
/// bundled HTML file that, on load, attempts a main-frame navigation to a URL
/// containing "blocknav". `AppDelegate` wires the navigation-decision handler to
/// cancel that navigation and stamp `navblock:blocked` into the window title.
/// Seeing the stamp proves the decision path fires end-to-end; the fixture
/// document itself (unmarked) still loads, proving unmarked navigations pass
/// through. A live CEF browser issuing a real navigation is required, which is
/// why this is a UI test.
final class NavigationDecisionUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["HELLOCHROMIUM_STORE_PATH"] =
            NSTemporaryDirectory() + "ck-navblock-\(UUID().uuidString).sqlite"

        let fixture = try XCTUnwrap(Bundle(for: type(of: self))
            .url(forResource: "navigation", withExtension: "html")
        )
        app.launchEnvironment["HELLOCHROMIUM_NAVBLOCK_FIXTURE"] = fixture.path
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    func testMarkedNavigationIsCancelled() {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        // The fixture navigates the main frame to a "blocknav" URL; the handler
        // cancels it and stamps the title. No stamp would mean the navigation
        // was never intercepted (OnBeforeBrowse did not fire or did not reach
        // Swift).
        let titleIsBlocked = NSPredicate(format: "title == %@", "navblock:blocked")
        let exp = expectation(for: titleIsBlocked, evaluatedWith: window)
        wait(for: [exp], timeout: 15)
    }
}
