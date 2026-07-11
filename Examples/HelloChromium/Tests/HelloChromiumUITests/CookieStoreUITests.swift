import XCTest

/// End-to-end proof of the global cookie store (`ChromiumCookieStore`, backed by
/// CEF's `CefCookieManager`) — the analogue of `WKWebsiteDataStore.default()
/// .httpCookieStore`. The app is launched with `HELLOCHROMIUM_COOKIE_PROOF` set;
/// `AppDelegate` clears the store, sets a cookie (`ckproof=hello42` for
/// example.com), reads every cookie back, and stamps the matching value into the
/// window title as `cookie:<value>`.
///
/// `cookie:hello42` proves the set + get round-trip works through CEF;
/// `cookie:MISSING` (read-back didn't find it) or `cookie:SETFAILED` (CEF
/// rejected the set) would prove it did not. Requires CEF to be initialized —
/// the store is fetched inside `ChromiumApplication.run`'s setup — which is why
/// this is a UI test rather than a headless one.
final class CookieStoreUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["HELLOCHROMIUM_STORE_PATH"] =
            NSTemporaryDirectory() + "ck-cookie-\(UUID().uuidString).sqlite"
        app.launchEnvironment["HELLOCHROMIUM_COOKIE_PROOF"] = "1"
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    func testCookieSetGetRoundTrip() {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        let titleMatches = NSPredicate(format: "title == %@", "cookie:hello42")
        let exp = expectation(for: titleMatches, evaluatedWith: window)
        wait(for: [exp], timeout: 15)
    }
}
