import AppKit
import ChromiumKit
import Foundation

// Program start and CEF's setup block both run on the main thread; assert that
// so we can touch the main-actor-isolated AppDelegate (which owns SwiftData's
// main context).
let delegate = MainActor.assumeIsolated { AppDelegate() }

let config = ChromiumConfiguration(
    userAgent: "HelloChromium/0.3 (ChromiumKit; macOS)",
    cachePath: FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "org.example.HelloChromium"),
    // Demo app: skip the macOS Keychain so the "Chromium Safe Storage" prompt
    // never blocks a launch (local, CI, or automated UI tests).
    useMockKeychain: true
)

exit(Int32(ChromiumApplication.run(configuration: config) {
    MainActor.assumeIsolated {
        NSApp.delegate = delegate
        delegate.makeMenu()
        delegate.makeWindow()
    }
}))
