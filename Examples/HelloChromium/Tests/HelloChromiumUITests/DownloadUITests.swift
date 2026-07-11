import XCTest

/// End-to-end proof of file downloads (`CefDownloadHandler`, surfaced as
/// `ChromiumView.downloadDelegate` + the `ChromiumDownload` handle) — the
/// ChromiumKit analogue of `WKDownloadDelegate` / `WKDownload`. The app is
/// launched with `HELLOCHROMIUM_DOWNLOAD_PROOF` set; `AppDelegate` wires the
/// runtime's download delegate to save into an isolated temp dir, points the
/// seeded tab at a forced-download URL (an octet-stream `data:` URL), observes
/// the `ChromiumDownload` to completion, reads the written file back, and stamps
/// its contents into the window title as `download:<contents>`.
///
/// `download:hello-download` proves the download flowed all the way through CEF
/// to disk (destination decided by the delegate, bytes written, completion
/// observed via KVO); `download:MISSING` (file absent/empty) would prove it did
/// not. Requires CEF to be initialized (the download starts inside a live
/// browser), which is why this is a UI test rather than a headless one.
final class DownloadUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["HELLOCHROMIUM_STORE_PATH"] =
            NSTemporaryDirectory() + "ck-dl-\(UUID().uuidString).sqlite"
        app.launchEnvironment["HELLOCHROMIUM_DOWNLOAD_DIR"] =
            NSTemporaryDirectory() + "ck-dldir-\(UUID().uuidString)"
        app.launchEnvironment["HELLOCHROMIUM_DOWNLOAD_PROOF"] = "1"
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    func testDownloadWritesFileToDisk() {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        let titleMatches = NSPredicate(format: "title == %@", "download:hello-download")
        let exp = expectation(for: titleMatches, evaluatedWith: window)
        wait(for: [exp], timeout: 20)
    }
}
