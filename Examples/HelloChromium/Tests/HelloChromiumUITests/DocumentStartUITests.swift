import XCTest

/// End-to-end proof of document-start user-script injection (the CEF equivalent
/// of `WKUserScript` at `.atDocumentStart`): a script registered via
/// `ChromiumWebView.addUserScript(atDocumentStart:)` sets `window.__docStartValue`
/// BEFORE the page's own parse-time scripts run.
///
/// The app is launched with `HELLOCHROMIUM_DOCSTART_FIXTURE` pointing at a
/// bundled HTML file whose inline `<script>` reads that global and posts it back
/// through the `bridgeTest` channel. `AppDelegate` injects the document-start
/// script (`window.__docStartValue = 'ok'`) and stamps the value the page read
/// into the window title as `docstart:<value>`. So `docstart:ok` proves the user
/// script ran first; `docstart:MISSING` would prove it did not. A live CEF
/// browser is required (the script only injects once the browser attaches in a
/// sized window), which is why this is a UI test rather than a headless one.
final class DocumentStartUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["HELLOCHROMIUM_STORE_PATH"] =
            NSTemporaryDirectory() + "ck-docstart-\(UUID().uuidString).sqlite"

        let fixture = try XCTUnwrap(Bundle(for: type(of: self))
            .url(forResource: "docstart", withExtension: "html")
        )
        app.launchEnvironment["HELLOCHROMIUM_DOCSTART_FIXTURE"] = fixture.path
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    func testDocumentStartScriptRunsBeforePageScripts() {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        // "ok" means the .atDocumentStart script set the global before the page's
        // parse-time inline script read it; "MISSING" would mean the ordering broke.
        let titleIsDocStart = NSPredicate(format: "title == %@", "docstart:ok")
        let exp = expectation(for: titleIsDocStart, evaluatedWith: window)
        wait(for: [exp], timeout: 15)
    }
}
