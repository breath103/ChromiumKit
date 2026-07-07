import XCTest

/// End-to-end proof of CEF page zoom (the `WKWebView.pageZoom` analogue):
/// setting `ChromiumWebView.zoomFactor` maps to `CefBrowserHost::SetZoomLevel`
/// and takes effect in the live page.
///
/// The app is launched with `HELLOCHROMIUM_ZOOM_FIXTURE` pointing at a bundled
/// HTML file that reports its `devicePixelRatio` to native over the `bridgeTest`
/// channel on a short interval. `AppDelegate` captures the first value as a
/// baseline, sets `zoomFactor = 1.5` on the live web view, and once a later
/// report rises to ~1.5x the baseline stamps `zoom:1.5` into the window title —
/// page zoom multiplies `devicePixelRatio`, so seeing the stamp proves the zoom
/// reached the renderer. Using the ratio (not the absolute DPR) keeps it
/// independent of the display's own backing-scale factor. A live CEF browser is
/// required, which is why this is a UI test.
final class ZoomUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["HELLOCHROMIUM_STORE_PATH"] =
            NSTemporaryDirectory() + "ck-zoom-\(UUID().uuidString).sqlite"

        let fixture = try XCTUnwrap(Bundle(for: type(of: self))
            .url(forResource: "zoom", withExtension: "html")
        )
        app.launchEnvironment["HELLOCHROMIUM_ZOOM_FIXTURE"] = fixture.path
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    func testZoomFactorTakesEffect() {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        // The stamp appears only if devicePixelRatio rose to ~1.5x after the
        // handler applied zoomFactor = 1.5. No stamp would mean SetZoomLevel
        // never reached the renderer.
        let titleIsZoomed = NSPredicate(format: "title == %@", "zoom:1.5")
        let exp = expectation(for: titleIsZoomed, evaluatedWith: window)
        wait(for: [exp], timeout: 15)
    }
}
