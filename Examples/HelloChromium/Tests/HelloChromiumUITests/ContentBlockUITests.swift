import XCTest

/// End-to-end proof of CEF request interception / content blocking (the
/// `WKContentRuleList` analogue): a resource request the app decides to block
/// is cancelled via `ChromiumWebView.resourceRequestBlocker` →
/// `CefResourceRequestHandler::OnBeforeResourceLoad` before it hits the network.
///
/// The app is launched with `HELLOCHROMIUM_ADBLOCK_FIXTURE` pointing at a bundled
/// HTML file that references a subresource whose URL contains "blockme".
/// `AppDelegate` wires the resource-request blocker to cancel that request and
/// stamp `adblock:blocked` into the window title. Seeing the stamp proves the
/// block path fires end-to-end; the fixture document itself (unmarked) still
/// loads, proving unmarked requests pass through. A live CEF browser issuing a
/// real subresource request is required, which is why this is a UI test.
final class ContentBlockUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["HELLOCHROMIUM_STORE_PATH"] =
            NSTemporaryDirectory() + "ck-adblock-\(UUID().uuidString).sqlite"

        let fixture = try XCTUnwrap(Bundle(for: type(of: self))
            .url(forResource: "adblock", withExtension: "html")
        )
        app.launchEnvironment["HELLOCHROMIUM_ADBLOCK_FIXTURE"] = fixture.path
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    func testMarkedResourceRequestIsBlocked() {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        // The fixture's <img> points at a "blockme" URL; the blocker cancels it
        // and stamps the title. No stamp would mean the request was never
        // intercepted (OnBeforeResourceLoad did not fire or did not reach Swift).
        let titleIsBlocked = NSPredicate(format: "title == %@", "adblock:blocked")
        let exp = expectation(for: titleIsBlocked, evaluatedWith: window)
        wait(for: [exp], timeout: 15)
    }
}
