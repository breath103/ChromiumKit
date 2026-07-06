import XCTest

/// End-to-end proof of the JS→native message bridge: a page calls
/// `window.webkit.messageHandlers.bridgeTest.postMessage(...)` (the WKWebView
/// shape ChromiumKit shims) and the native Swift handler receives the body.
///
/// The app is launched with `HELLOCHROMIUM_BRIDGE_FIXTURE` pointing at a bundled
/// HTML file that posts `{kind:"hello",n:42}` on load; `AppDelegate` wires the
/// handler to stamp the received body into the window title as `bridge:<json>`.
/// So the round trip is confirmed the moment the window title flips — a live
/// CEF browser is required (the browser only attaches once mounted in a sized
/// window), which is why this is a UI test rather than a headless unit test.
final class BridgeUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["HELLOCHROMIUM_STORE_PATH"] =
            NSTemporaryDirectory() + "ck-bridge-\(UUID().uuidString).sqlite"

        let fixture = try XCTUnwrap(Bundle(for: type(of: self))
            .url(forResource: "bridge", withExtension: "html")
        )
        app.launchEnvironment["HELLOCHROMIUM_BRIDGE_FIXTURE"] = fixture.path
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    func testPostMessageRoundTripsToSwift() {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        // The handler stamps the received, re-serialized body into the title.
        let expected = #"bridge:{"kind":"hello","n":42}"#
        let titleIsBridged = NSPredicate(format: "title == %@", expected)
        let exp = expectation(for: titleIsBridged, evaluatedWith: window)
        wait(for: [exp], timeout: 15)
    }
}
