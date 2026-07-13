import AppKit
import ChromiumKit
import XCTest

/// Regression tests for `evaluateJavaScript`'s result bridging — most
/// importantly the `undefined` case. The ObjC completion fires `(nil, nil)`
/// when the script evaluates to `undefined` (any fire-and-forget statement).
/// The completion's `result` param must therefore be `_Nullable_result`:
/// without it, Swift's auto-generated `async` thunk imports the return as
/// NON-optional `Any` and traps on `(nil, nil)` — which crashed the host app
/// on every page that ran such a script (Mirror preview builds 1997–1999;
/// SIGTRAP on CrBrowserMain from `_onDevToolsResult`'s main-queue block).
///
/// XCTest (not Swift Testing) on purpose: `wait(for:)`/`fulfillment(of:)`
/// pump the main run loop, which CEF work is marshaled onto.
final class EvaluateJavaScriptResultTests: XCTestCase {
    @MainActor
    private func makeLoadedWebView() async throws -> (NSWindow, ChromiumWebView) {
        let html = "<html><head><title>eval-host-ok</title></head><body>hi</body></html>"
        let encoded = html.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let url = URL(string: "data:text/html,\(encoded)")!

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let webView = ChromiumWebView(frame: window.contentView!.bounds, url: url)
        window.contentView!.addSubview(webView)

        let loaded = expectation(description: "page load reaches title")
        loaded.assertForOverFulfill = false
        var observation: NSKeyValueObservation? = webView.observe(\.title, options: [.initial, .new]) { view, _ in
            if view.title == "eval-host-ok" { loaded.fulfill() }
        }
        await fulfillment(of: [loaded], timeout: 30)
        observation = nil
        _ = observation
        return (window, webView)
    }

    /// `undefined` result → the async form must return nil, not trap.
    @MainActor
    func testUndefinedResultReturnsNil() async throws {
        let (window, webView) = try await makeLoadedWebView()
        defer { window.close() }

        let result = try await webView.evaluateJavaScript("document.title; undefined")
        XCTAssertNil(result)
    }

    /// A real value still round-trips.
    @MainActor
    func testValueResultRoundTrips() async throws {
        let (window, webView) = try await makeLoadedWebView()
        defer { window.close() }

        let result = try await webView.evaluateJavaScript("1 + 41")
        XCTAssertEqual(result as? Int, 42)
    }
}
