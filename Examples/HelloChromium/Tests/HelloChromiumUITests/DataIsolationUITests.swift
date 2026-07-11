import XCTest

/// End-to-end proof of per-view data isolation (`ChromiumDataStore`, backed by a
/// CEF `CefRequestContext`) — the analogue of building two `WKWebView`s with
/// different `WKWebsiteDataStore`s. Two tabs are given two DISTINCT
/// `nonPersistent` stores; a "writer" tab writes a marker into `localStorage`
/// and a "reader" tab (its own isolated store) reads back what it can see.
///
/// The app is launched with `HELLOCHROMIUM_ISOLATION_FIXTURE` pointing at a
/// bundled HTML file that acts as writer or reader per its `?role=` query.
/// `AppDelegate` runs the two phases and stamps the reader's result into the
/// window title: `isolation:isolated` (reader saw nothing — storage is
/// partitioned per request context) or `isolation:LEAKED(...)` (reader saw the
/// writer's marker — isolation failed). A live CEF browser with real
/// localStorage is required, which is why this is a UI test.
final class DataIsolationUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["HELLOCHROMIUM_STORE_PATH"] =
            NSTemporaryDirectory() + "ck-isolation-\(UUID().uuidString).sqlite"

        let fixture = try XCTUnwrap(Bundle(for: type(of: self))
            .url(forResource: "isolation", withExtension: "html")
        )
        app.launchEnvironment["HELLOCHROMIUM_ISOLATION_FIXTURE"] = fixture.path
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    func testDistinctStoresDoNotShareLocalStorage() {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        // The reader tab uses a different CefRequestContext than the writer, so
        // it must not observe the writer's localStorage marker. `LEAKED` would
        // mean the two views shared a storage partition.
        let titleIsolated = NSPredicate(format: "title == %@", "isolation:isolated")
        let exp = expectation(for: titleIsolated, evaluatedWith: window)
        wait(for: [exp], timeout: 20)
    }
}
