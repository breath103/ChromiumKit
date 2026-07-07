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
