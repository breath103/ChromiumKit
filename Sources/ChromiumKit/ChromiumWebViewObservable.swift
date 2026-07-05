import AppKit
@_exported import ChromiumViewObjC
import Foundation
import Observation

/// `@Observable` mirror of `ChromiumWebView`'s reactive state, for SwiftUI binding.
///
/// The truth lives on the `ChromiumWebView` itself (the underlying ObjC `@property`s
/// fire KVO when CEF callbacks land). This class observes those KVO keys and
/// republishes them as Observation-tracked properties so SwiftUI views that
/// read them re-render automatically.
///
/// One instance per `ChromiumWebView`. Access via `webView.observable` — that
/// accessor lazily creates and caches a single instance per webView.
///
/// ```swift
/// Text(tab.webView.observable.title ?? "new tab")  // updates live
/// ProgressView().opacity(tab.webView.observable.isLoading ? 1 : 0)
/// ```
@available(macOS 14, *)
@Observable
public final class ChromiumWebViewObservable {
    // weak: the observable is attached to the webView via
    // objc_setAssociatedObject (RETAIN). A strong `webView` here would form
    // a cycle and the webView would never deallocate.
    @ObservationIgnored public weak var webView: ChromiumWebView?

    public private(set) var title: String?
    public private(set) var url: URL?
    public private(set) var isLoading: Bool = false
    public private(set) var canGoBack: Bool = false
    public private(set) var canGoForward: Bool = false
    public private(set) var favicon: Favicon?

    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    public init(_ webView: ChromiumWebView) {
        self.webView = webView
        // Seed initial values before observing — KVO with .initial would also
        // work but we prefer explicit reads here.
        title = webView.title
        url = webView.url
        isLoading = webView.isLoading
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        favicon = webView.favicon.map(Favicon.init)

        observations.append(webView.observe(\.title, options: [.new]) { [weak self] _, c in
            self?.title = c.newValue ?? nil
        })
        observations.append(webView.observe(\.url, options: [.new]) { [weak self] _, c in
            self?.url = c.newValue ?? nil
        })
        observations.append(webView.observe(\.isLoading, options: [.new]) { [weak self] _, c in
            self?.isLoading = c.newValue ?? false
        })
        observations.append(webView.observe(\.canGoBack, options: [.new]) { [weak self] _, c in
            self?.canGoBack = c.newValue ?? false
        })
        observations.append(webView.observe(\.canGoForward, options: [.new]) { [weak self] _, c in
            self?.canGoForward = c.newValue ?? false
        })
        observations.append(webView.observe(\.favicon, options: [.new]) { [weak self] _, c in
            self?.favicon = (c.newValue ?? nil).map(Favicon.init)
        })
    }
}
