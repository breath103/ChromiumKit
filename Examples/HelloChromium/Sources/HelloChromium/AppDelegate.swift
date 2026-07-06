import AppKit
import Foundation
import SwiftData
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let runtime = TabRuntime()
    private var container: ModelContainer!
    var window: NSWindow!

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
