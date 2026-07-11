import XCTest

/// Proves `ChromiumWebView.findText(_:forward:matchCase:findNext:)` runs a
/// CefBrowserHost::Find search and that `CefFindHandler::OnFindResult` surfaces
/// the match count through `findResultHandler`. The fixture holds three
/// "banana" occurrences; the AppDelegate proof searches for "banana" once the
/// page signals ready and stamps `find:<count>` into the window title.
final class FindUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["HELLOCHROMIUM_STORE_PATH"] =
            NSTemporaryDirectory() + "ck-find-\(UUID().uuidString).sqlite"

        let fixture = try XCTUnwrap(Bundle(for: type(of: self))
            .url(forResource: "find", withExtension: "html")
        )
        app.launchEnvironment["HELLOCHROMIUM_FIND_FIXTURE"] = fixture.path
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    func testFindReportsMatchCount() {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        let titleHasCount = NSPredicate(format: "title == %@", "find:3")
        let exp = expectation(for: titleHasCount, evaluatedWith: window)
        wait(for: [exp], timeout: 15)
    }
}
