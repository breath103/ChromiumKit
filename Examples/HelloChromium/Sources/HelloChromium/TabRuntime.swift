import AppKit
import ChromiumKit
import Foundation
import Observation
import SwiftData

/// Owns the live, non-persistable `ChromiumWebView`s and keeps each one synced
/// into its `TabRecord`. The web view is an NSView-backed browser that must NOT
/// be persisted, so it lives here (keyed by the record's stable
/// `persistentModelID`) rather than on the model. Creating a web view = waking
/// the tab; dropping it = hibernating. Whenever the page navigates, KVO
/// callbacks write `url` / `title` / `faviconPNG` back into the record, which
/// persists and re-renders through SwiftData's Observation.
@MainActor
@Observable
final class TabRuntime: NSObject {
    // Keyed by the record's own UUID, not its `persistentModelID`: SwiftData
    // swaps a newly-inserted model's temporary identifier for a permanent one on
    // the next save, which would orphan a live web view registered before then.
    private var live: [UUID: LiveTab] = [:]

    /// Set once at launch. The context new tabs (incl. popups) are inserted into.
    @ObservationIgnored var context: ModelContext!
    /// The current session new tabs belong to.
    @ObservationIgnored var session: Session!

    /// The live web view for a record, or nil if the tab is hibernated. Pure
    /// lookup — safe to call from a SwiftUI view body.
    func liveWebView(for record: TabRecord) -> ChromiumWebView? {
        live[record.id]?.webView
    }

    /// Wake a tab: create its web view (loading the record's URL) if absent, and
    /// start syncing navigation back into the record. Idempotent.
    @discardableResult
    func wake(_ record: TabRecord) -> ChromiumWebView {
        if let existing = live[record.id] { return existing.webView }
        return register(ChromiumWebView(frame: .zero, url: record.url), for: record)
    }

    /// Hibernate a tab: drop the live web view. The record keeps the last
    /// url/title/favicon, so the row still renders and a later `wake` restores it.
    func hibernate(_ record: TabRecord) {
        live[record.id] = nil
    }

    /// React to the store: release any live web view whose `TabRecord` has left
    /// the session, and move selection off a deleted tab. Closing a tab is just
    /// deleting its record — this is the single place that observes that and
    /// frees the connected `ChromiumWebView` (+ its KVO observers), so there's no
    /// imperative release path a caller has to remember. Re-arms itself on every
    /// change to the session's tabs.
    func reconcileLiveTabs() {
        // Read (and track) the tabs inside the tracking closure; do the mutations
        // outside it via reconcile(against:) so they don't re-trigger the observer.
        let tabs = withObservationTracking {
            session.orderedTabs
        } onChange: { [weak self] in
            Task { @MainActor in self?.reconcileLiveTabs() }
        }
        reconcile(against: tabs)
    }

    /// Release live web views whose record is not in `tabs`, and move selection
    /// off a tab that's gone. Split out from the observation arming above so the
    /// logic is unit-testable without installing a long-lived observer.
    func reconcile(against tabs: [TabRecord]) {
        let existingIDs = Set(tabs.map(\.id))
        for id in live.keys where !existingIDs.contains(id) {
            live[id] = nil
        }
        if let selected = session.selectedTabID, !existingIDs.contains(selected) {
            session.selectedTabID = tabs.last?.id
        }
    }

    /// Open a new foreground tab in the session and select it.
    @discardableResult
    func newTab(in session: Session, url: URL = URL(string: "https://example.com")!) -> TabRecord {
        let record = insertTab(url: url, into: session)
        session.selectedTabID = record.id
        return record
    }

    private func insertTab(url: URL, into session: Session) -> TabRecord {
        let nextIndex = (session.tabs.map(\.sortIndex).max() ?? -1) + 1
        let record = TabRecord(url: url, sortIndex: nextIndex, session: session)
        context.insert(record)
        return record
    }

    /// Register a web view (freshly created, or an adopted popup shell) as the
    /// live view for a record and start syncing navigation into it.
    @discardableResult
    private func register(_ webView: ChromiumWebView, for record: TabRecord) -> ChromiumWebView {
        webView.navigationDelegate = self
        live[record.id] = LiveTab(webView: webView, record: record)
        return webView
    }

    /// A live web view plus the KVO observations that mirror its navigation
    /// state into a `TabRecord`. Scopes those observations to the web view's
    /// lifetime in the registry — dropping the `LiveTab` invalidates them.
    private final class LiveTab {
        let webView: ChromiumWebView
        private weak var record: TabRecord?
        private var observations: [NSKeyValueObservation] = []
        private var faviconImageObservation: NSKeyValueObservation?

        init(webView: ChromiumWebView, record: TabRecord) {
            self.webView = webView
            self.record = record

            observations.append(webView.observe(\.url, options: [.new]) { [weak self] _, change in
                guard let newURL = change.newValue ?? nil else { return }
                MainActor.assumeIsolated { self?.record?.url = newURL }
            })
            observations.append(webView.observe(\.title, options: [.new]) { [weak self] _, change in
                MainActor.assumeIsolated { self?.record?.title = (change.newValue ?? nil) ?? "" }
            })
            // The favicon ref is replaced on each favicon-URL change; its image
            // lands asynchronously, so re-bind to the new ref's image each time.
            observations.append(webView.observe(\.favicon, options: [.new, .initial]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.bindFavicon(view.favicon) }
            })
        }

        private func bindFavicon(_ favicon: CEFFaviconRef?) {
            faviconImageObservation = favicon?.observe(\.image, options: [.new, .initial]) { [weak self] _, change in
                let image = change.newValue ?? nil
                MainActor.assumeIsolated { self?.record?.faviconPNG = image?.pngData }
            }
        }
    }
}

extension TabRuntime: ChromiumNavigationDelegate {
    // CEF invokes this on the main thread; hop into the actor to touch the
    // context and session safely.
    nonisolated func webView(
        _: ChromiumWebView,
        requestsNewTabFor url: URL?,
        userGesture _: Bool,
        disposition: CEFTabDisposition
    ) -> ChromiumWebView? {
        MainActor.assumeIsolated {
            let shell = ChromiumWebView.popupView()
            let target = url ?? URL(string: "about:blank")!
            let record = insertTab(url: target, into: session)
            register(shell, for: record)
            if disposition == .newForegroundTab {
                session.selectedTabID = record.id
            }
            return shell
        }
    }
}

private extension NSImage {
    var pngData: Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
