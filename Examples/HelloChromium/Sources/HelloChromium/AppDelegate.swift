import AppKit
import ChromiumKit
import Foundation
import SwiftData
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let runtime = TabRuntime()
    private var container: ModelContainer!
    var window: NSWindow!
    private var downloadObservation: NSKeyValueObservation?

    func makeMenu() {
        // ChromiumApplication overrides `terminate:` to call CefQuitMessageLoop,
        // so the standard Quit item is enough to unwind CEF cleanly.
        let appName = ProcessInfo.processInfo.processName
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Quit \(appName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        NSApp.mainMenu = mainMenu
    }

    func makeWindow() {
        container = makeContainer()
        let session = restoreOrSeedSession()
        runtime.context = container.mainContext
        runtime.session = session
        configureBridgeProofIfRequested(session)
        configureDocumentStartProofIfRequested(session)
        configureCookieProofIfRequested()
        configureDownloadProofIfRequested(session)
        configureKeyboardProofIfRequested(session)
        configureContentBlockProofIfRequested(session)
        configureNavigationBlockProofIfRequested(session)
        configureZoomProofIfRequested(session)
        configureDataIsolationProofIfRequested(session)
        configureFindProofIfRequested(session)
        runtime.reconcileLiveTabs() // start reacting to tab deletions

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "HelloChromium"
        window.center()
        window.contentView = NSHostingView(
            rootView: ContentView(session: session)
                .modelContainer(container)
                .environment(runtime)
        )
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// JS→native bridge round-trip proof (drives the BridgeUITests). When
    /// `HELLOCHROMIUM_BRIDGE_FIXTURE` points at an HTML file, seed the session's
    /// single tab with it and wire `runtime.onBridgeMessage` to stamp the
    /// received body into the window title as `bridge:<json>`. The page posts
    /// `{kind:"hello",n:42}` via `window.webkit.messageHandlers.bridgeTest`, so a
    /// successful round trip makes the title observable to XCUITest.
    private func configureBridgeProofIfRequested(_ session: Session) {
        guard let fixture = ProcessInfo.processInfo.environment["HELLOCHROMIUM_BRIDGE_FIXTURE"]
        else { return }
        runtime.onBridgeMessage = { [weak self] body in
            // Re-serialize the received Foundation JSON value for a stable,
            // assertable title string.
            let json = (body as? [String: Any]).flatMap {
                try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys])
            }.flatMap { String(data: $0, encoding: .utf8) } ?? "\(body ?? "nil")"
            self?.window.title = "bridge:\(json)"
        }
        // Point the seeded tab at the fixture so the page posts on load.
        if let tab = session.orderedTabs.first {
            tab.url = URL(fileURLWithPath: fixture)
        }
    }

    /// Document-start user-script round-trip proof (drives DocumentStartUITests).
    /// When `HELLOCHROMIUM_DOCSTART_FIXTURE` points at an HTML file, inject a
    /// document-start script that sets `window.__docStartValue = 'ok'` and wire
    /// `bridgeTest` to stamp the value the page reads back into the window title
    /// as `docstart:<value>`. The fixture's parse-time inline script reads the
    /// global and posts it, so `docstart:ok` proves the user script ran BEFORE
    /// page scripts; `docstart:MISSING` would mean it did not.
    private func configureDocumentStartProofIfRequested(_ session: Session) {
        guard let fixture = ProcessInfo.processInfo.environment["HELLOCHROMIUM_DOCSTART_FIXTURE"]
        else { return }
        runtime.documentStartScript = "window.__docStartValue = 'ok';"
        runtime.onBridgeMessage = { [weak self] body in
            self?.window.title = "docstart:\(body ?? "nil")"
        }
        if let tab = session.orderedTabs.first {
            tab.url = URL(fileURLWithPath: fixture)
        }
    }

    /// Cookie-store round-trip proof (drives CookieStoreUITests). When
    /// `HELLOCHROMIUM_COOKIE_PROOF` is set, exercise the global cookie store —
    /// delete all, set a cookie, then read it back — and stamp the read-back
    /// value into the window title as `cookie:<value>`. `cookie:hello42` proves
    /// set + get round-trip through CEF's `CefCookieManager`; `cookie:MISSING`
    /// (not found) or `cookie:SETFAILED` (rejected) would prove it did not.
    private func configureCookieProofIfRequested() {
        guard ProcessInfo.processInfo.environment["HELLOCHROMIUM_COOKIE_PROOF"] != nil
        else { return }
        let store = ChromiumCookieStore.global()
        store.deleteAllCookies { _ in
            let cookie = ChromiumCookie(name: "ckproof", value: "hello42")
            cookie.domain = "example.com"
            cookie.path = "/"
            store.setCookie(cookie, for: URL(string: "https://example.com/")!) { [weak self] success in
                guard success else { self?.window.title = "cookie:SETFAILED"; return }
                store.getAllCookies { cookies in
                    let match = cookies.first { $0.name == "ckproof" }
                    self?.window.title = "cookie:\(match?.value ?? "MISSING")"
                }
            }
        }
    }

    /// Download round-trip proof (drives DownloadUITests). When
    /// `HELLOCHROMIUM_DOWNLOAD_PROOF` is set, wire the runtime's download
    /// delegate to save into an isolated temp dir, point the seeded tab at a
    /// forced-download URL, observe the `ChromiumDownload` to completion, read
    /// the written file back, and stamp its contents into the window title as
    /// `download:<contents>`. `download:hello-download` proves CEF's
    /// `CefDownloadHandler` delivered the bytes to disk; `download:MISSING`
    /// (file absent/empty) would prove it did not.
    private func configureDownloadProofIfRequested(_ session: Session) {
        guard ProcessInfo.processInfo.environment["HELLOCHROMIUM_DOWNLOAD_PROOF"] != nil
        else { return }
        let dir = ProcessInfo.processInfo.environment["HELLOCHROMIUM_DOWNLOAD_DIR"]
            .map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        runtime.onDownload = { [weak self] download, suggestedFilename, completion in
            let name = suggestedFilename.isEmpty ? "download.bin" : suggestedFilename
            let dest = dir.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: dest)
            self?.observeDownload(download, writtenTo: dest)
            completion(dest)
        }
        // A top-level navigation to an octet-stream data: URL is unrenderable, so
        // Chromium turns it into a download. Override with HELLOCHROMIUM_DOWNLOAD_URL
        // (e.g. a real Content-Disposition:attachment URL) if needed.
        let trigger = ProcessInfo.processInfo.environment["HELLOCHROMIUM_DOWNLOAD_URL"]
            .flatMap { URL(string: $0) }
            // base64("hello-download")
            ?? URL(string: "data:application/octet-stream;base64,aGVsbG8tZG93bmxvYWQ=")!
        session.orderedTabs.first?.url = trigger
    }

    private func observeDownload(_ download: ChromiumDownload, writtenTo dest: URL) {
        downloadObservation = download.observe(\.isComplete, options: [.new]) { [weak self] dl, _ in
            guard dl.isComplete else { return }
            MainActor.assumeIsolated {
                let contents = (try? Data(contentsOf: dest))
                    .flatMap { String(data: $0, encoding: .utf8) }
                self?.window.title = "download:\(contents ?? "MISSING")"
            }
        }
    }

    /// Unhandled-keyboard proof (drives KeyboardUITests). When
    /// `HELLOCHROMIUM_KEYBOARD_FIXTURE` points at an HTML file, load it and wire
    /// the runtime's keyboard hook to translate an unhandled Cmd+F / Cmd+P into a
    /// window-title stamp (`keyboard:searchInPage` / `keyboard:printPage`),
    /// returning true to swallow it. The fixture autofocuses an input so the CEF
    /// renderer holds keyboard focus and the key routes through the page first
    /// (unhandled), then surfaces via `CefKeyboardHandler::OnKeyEvent`. So
    /// `keyboard:searchInPage` proves the native key path works; no stamp would
    /// mean the event never surfaced.
    private func configureKeyboardProofIfRequested(_ session: Session) {
        guard let fixture = ProcessInfo.processInfo.environment["HELLOCHROMIUM_KEYBOARD_FIXTURE"]
        else { return }
        runtime.onKeyboardEvent = { [weak self] event in
            guard event.modifierFlags.contains(.command) else { return false }
            let shortcut: String? =
                switch event.charactersIgnoringModifiers {
                    case "f": "searchInPage"
                    case "p": "printPage"
                    default: nil
                }
            guard let shortcut else { return false }
            self?.window.title = "keyboard:\(shortcut)"
            return true
        }
        if let tab = session.orderedTabs.first {
            tab.url = URL(fileURLWithPath: fixture)
        }
    }

    /// Content-block proof (drives ContentBlockUITests). When
    /// `HELLOCHROMIUM_ADBLOCK_FIXTURE` points at an HTML file, load it and wire
    /// the runtime's resource-request blocker to CANCEL any request whose URL
    /// contains "blockme", stamping `adblock:blocked` into the window title when
    /// it does. The fixture references a `blockme` subresource (an <img>), so the
    /// request surfaces via `CefResourceRequestHandler::OnBeforeResourceLoad` and
    /// is cancelled before it hits the network. Seeing the stamp proves the block
    /// path works end-to-end; the page itself (an unmarked file:// document) still
    /// loads, proving unmarked requests are allowed through.
    private func configureContentBlockProofIfRequested(_ session: Session) {
        guard let fixture = ProcessInfo.processInfo.environment["HELLOCHROMIUM_ADBLOCK_FIXTURE"]
        else { return }
        runtime.onResourceRequest = { [weak self] url, _ in
            guard url.absoluteString.contains("blockme") else { return false }
            // Called off-main (CEF IO thread) — hop to main to touch the window.
            DispatchQueue.main.async { self?.window.title = "adblock:blocked" }
            return true
        }
        if let tab = session.orderedTabs.first {
            tab.url = URL(fileURLWithPath: fixture)
        }
    }

    /// Navigation-decision proof (drives NavigationDecisionUITests). When
    /// `HELLOCHROMIUM_NAVBLOCK_FIXTURE` points at an HTML file, load it and wire
    /// the runtime's navigation-decision hook to CANCEL any main-frame
    /// navigation whose URL contains "blocknav", stamping `navblock:blocked`
    /// into the window title when it does. The fixture navigates the main frame
    /// to a `blocknav` URL on load, so the attempt surfaces via
    /// `CefRequestHandler::OnBeforeBrowse` and is cancelled before it commits.
    /// Seeing the stamp proves the decision path works end-to-end; the fixture
    /// document itself (an unmarked file:// load) still loads, proving unmarked
    /// navigations are allowed through.
    private func configureNavigationBlockProofIfRequested(_ session: Session) {
        guard let fixture = ProcessInfo.processInfo.environment["HELLOCHROMIUM_NAVBLOCK_FIXTURE"]
        else { return }
        runtime.onNavigationDecision = { [weak self] request in
            guard let url = request.url, url.absoluteString.contains("blocknav")
            else { return false }
            // Called on the main thread — safe to touch the window directly.
            self?.window.title = "navblock:blocked"
            return true // YES = cancel the navigation
        }
        if let tab = session.orderedTabs.first {
            tab.url = URL(fileURLWithPath: fixture)
        }
    }

    /// Page-zoom round-trip proof (drives ZoomUITests). When
    /// `HELLOCHROMIUM_ZOOM_FIXTURE` points at an HTML file, load it and watch the
    /// page's `devicePixelRatio` over the `bridgeTest` channel: capture the first
    /// value as a baseline, set `zoomFactor = 1.5` on the live web view, and once
    /// a later report rises to ~1.5x the baseline stamp `zoom:1.5` into the window
    /// title — page zoom multiplies `devicePixelRatio`, so the stamp proves
    /// `CefBrowserHost::SetZoomLevel` took effect page-side. The ratio (not the
    /// absolute DPR) keeps it independent of the display's own backing scale.
    /// When `HELLOCHROMIUM_FIND_FIXTURE` points at an HTML file, load it and,
    /// once the page signals ready (via the bridge), run a find-in-page search
    /// for "banana"; the final `OnFindResult` stamps the match count into the
    /// window title as `find:<count>` (`find:3` for the fixture's three matches),
    /// proving `CefBrowserHost::Find` + `CefFindHandler` round-trip to Swift.
    private func configureFindProofIfRequested(_ session: Session) {
        guard let fixture = ProcessInfo.processInfo.environment["HELLOCHROMIUM_FIND_FIXTURE"]
        else { return }
        var searchStarted = false
        runtime.onBridgeMessage = { [weak self] _ in
            guard let self, !searchStarted else { return }
            searchStarted = true
            if let tab = session.orderedTabs.first,
               let webView = self.runtime.liveWebView(for: tab) {
                webView.findText("banana", forward: true, matchCase: false, findNext: false)
            }
        }
        runtime.onFindResult = { [weak self] result in
            guard result.isFinalUpdate else { return }
            self?.window.title = "find:\(result.count)"
        }
        if let tab = session.orderedTabs.first {
            tab.url = URL(fileURLWithPath: fixture)
        }
    }

    private func configureZoomProofIfRequested(_ session: Session) {
        guard let fixture = ProcessInfo.processInfo.environment["HELLOCHROMIUM_ZOOM_FIXTURE"]
        else { return }
        var baseline: Double?
        var zoomApplied = false
        runtime.onBridgeMessage = { [weak self] body in
            guard let self, let dpr = (body as? NSNumber)?.doubleValue, dpr > 0 else { return }
            guard let baselineDPR = baseline else {
                baseline = dpr
                if let tab = session.orderedTabs.first,
                   let webView = self.runtime.liveWebView(for: tab) {
                    webView.zoomFactor = 1.5
                    zoomApplied = true
                }
                return
            }
            if zoomApplied, dpr >= baselineDPR * 1.4 {
                self.window.title = "zoom:\(String(format: "%.1f", dpr / baselineDPR))"
            }
        }
        if let tab = session.orderedTabs.first {
            tab.url = URL(fileURLWithPath: fixture)
        }
    }

    /// Per-view data-isolation proof (drives DataIsolationUITests). When
    /// `HELLOCHROMIUM_ISOLATION_FIXTURE` points at an HTML file, give the seeded
    /// "writer" tab and a second "reader" tab two DISTINCT non-persistent
    /// `ChromiumDataStore`s, then run two phases over the `bridgeTest` channel:
    /// the writer loads `?role=writer`, writes a marker into `localStorage`, and
    /// posts `wrote`; on hearing that we select (wake) the reader at
    /// `?role=reader`, which reads its OWN (isolated) `localStorage` and posts
    /// `read:<value>`. An empty read proves the stores are isolated
    /// (`isolation:isolated`); seeing the writer's marker would prove a leak
    /// (`isolation:LEAKED`).
    private func configureDataIsolationProofIfRequested(_ session: Session) {
        guard let fixture = ProcessInfo.processInfo.environment["HELLOCHROMIUM_ISOLATION_FIXTURE"]
        else { return }
        let fixtureURL = URL(fileURLWithPath: fixture)
        func roleURL(_ role: String) -> URL {
            var comps = URLComponents(url: fixtureURL, resolvingAgainstBaseURL: false)
            comps?.queryItems = [URLQueryItem(name: "role", value: role)]
            return comps?.url ?? fixtureURL
        }

        let writerStore = ChromiumDataStore.nonPersistent()
        let readerStore = ChromiumDataStore.nonPersistent()

        guard let writerTab = session.orderedTabs.first else { return }
        writerTab.url = roleURL("writer")

        let nextIndex = (session.tabs.map(\.sortIndex).max() ?? -1) + 1
        let readerTab = TabRecord(url: roleURL("reader"), sortIndex: nextIndex, session: session)
        container.mainContext.insert(readerTab)

        let writerID = writerTab.id
        runtime.dataStoreProvider = { record in
            record.id == writerID ? writerStore : readerStore
        }
        runtime.onBridgeMessage = { [weak self] body in
            guard let self, let msg = body as? String else { return }
            if msg == "wrote" {
                // Writer done — waking the reader (its own isolated store) loads
                // ?role=reader, which reports what IT sees in localStorage.
                self.runtime.session.selectedTabID = readerTab.id
            } else if msg.hasPrefix("read:") {
                let value = String(msg.dropFirst("read:".count))
                self.window.title = value == "EMPTY"
                    ? "isolation:isolated"
                    : "isolation:LEAKED(\(value))"
            }
        }
    }

    // Flush SwiftData's deferred autosave so the latest tab state reaches disk.
    func applicationWillTerminate(_: Notification) {
        try? container?.mainContext.save()
    }

    private func makeContainer() -> ModelContainer {
        // HELLOCHROMIUM_STORE_PATH lets UI tests point at an isolated temp store.
        let storeURL = ProcessInfo.processInfo.environment["HELLOCHROMIUM_STORE_PATH"]
            .map { URL(fileURLWithPath: $0) } ?? Self.defaultStoreURL()
        do {
            return try ModelContainer(
                for: Session.self, TabRecord.self,
                configurations: ModelConfiguration(url: storeURL)
            )
        } catch {
            fatalError("Could not create ModelContainer at \(storeURL.path): \(error)")
        }
    }

    private static func defaultStoreURL() -> URL {
        let dir = URL.applicationSupportDirectory
            .appending(path: "HelloChromium", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "tabs.sqlite")
    }

    /// The current session is the most recently created one. First launch (or a
    /// cleared store) seeds a session with a single default tab.
    private func restoreOrSeedSession() -> Session {
        let context = container.mainContext
        var descriptor = FetchDescriptor<Session>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor).first {
            return existing
        }

        let session = Session()
        context.insert(session)
        let tab = TabRecord(url: URL(string: "https://example.com")!, sortIndex: 0, session: session)
        context.insert(tab)
        session.selectedTabID = tab.id
        try? context.save()
        return session
    }
}
