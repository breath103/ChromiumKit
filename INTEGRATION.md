# Integrating ChromiumKit into a macOS app

This is the WKWebView-style integration story. You add ChromiumKit as a Swift
Package dependency in Xcode, add one Run Script Build Phase, and ship.

---

## Why a Run Script Phase

Chromium Embedded Framework needs **five sibling helper `.app` bundles** in
your host's `Contents/Frameworks/` directory. SwiftPM has no concept of
embedding nested `.app` bundles, so the package ships:

- `Chromium Embedded Framework.framework` as an XCFramework (binaryTarget) —
  Xcode embeds it for you automatically when you depend on the `ChromiumKit`
  product.
- A prebuilt **helper executable** + plist template — your Run Script copies
  this into five `.app` bundles named `${PRODUCT_NAME} Helper{|.GPU|.Renderer|.Plugin|.Alerts}.app`.

You write **zero** custom embed logic. The package provides
`scripts/embed-chromiumkit.sh`. Your Run Script Phase invokes it.

---

## Adding the dependency in Xcode

1. **File → Add Package Dependencies…**
2. Enter the package URL (or pick "Add Local…" pointing at your checkout).
3. Add the `ChromiumKit` library product to your app target.

In your code:

```swift
import AppKit
import ChromiumKit

@main
struct App {
    static func main() {
        let cfg = ChromiumConfiguration(
            cachePath: FileManager.default
                .urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(Bundle.main.bundleIdentifier!))
        exit(Int32(ChromiumApplication.run(configuration: cfg) {
            let win = NSWindow(...)
            let webView = ChromiumWebView(frame: ..., url: URL(string: "https://example.com")!)
            win.contentView = webView
            win.makeKeyAndOrderFront(nil)
        }))
    }
}
```

You also need a sub-process executable target for the helper. The simplest
form (literally one line):

```swift
// HelperApp/main.swift
import ChromiumKit
exit(Int32(ChromiumApplication.runHelper()))
```

In Xcode: create a second target of type **Command Line Tool**, link the
`ChromiumKit` library, set its bundle identifier to `${PRODUCT_BUNDLE_IDENTIFIER}.helper.shared`
or similar. The Run Script (below) copies this binary into all five helper
slots — you do not create five helper targets.

---

## The Run Script Build Phase

On your host app target → **Build Phases → + → New Run Script Phase**.
Place it **after** "Embed Frameworks" but **before** any code-signing-only
phases.

```sh
"$BUILD_DIR/../../SourcePackages/checkouts/ChromiumKit/scripts/embed-chromiumkit.sh"
```

Required environment variables (Xcode already sets the first three; you set
the rest in the script phase's environment section, OR via "Input Files"
shell vars, OR inline):

| Variable | What |
|---|---|
| `BUILT_PRODUCTS_DIR` | provided by Xcode |
| `PRODUCT_NAME` | provided by Xcode |
| `PRODUCT_BUNDLE_IDENTIFIER` | provided by Xcode |
| `CHROMIUMKIT_FRAMEWORK_PATH` | path to `Chromium Embedded Framework.framework` shipped by the package |
| `CHROMIUMKIT_HELPER_PATH` | path to your built helper Mach-O executable (e.g. `$BUILT_PRODUCTS_DIR/MyAppHelper`) |
| `CHROMIUMKIT_HELPER_PLIST` | `$SRCROOT/../SourcePackages/checkouts/ChromiumKit/scripts/helper.plist.in` |
| `EXPANDED_CODE_SIGN_IDENTITY` | provided by Xcode |

Suggested inline script body:

```sh
PKG="$BUILD_DIR/../../SourcePackages/checkouts/ChromiumKit"
export CHROMIUMKIT_FRAMEWORK_PATH="$PKG/artifacts/CEF.xcframework/macos-arm64/Chromium Embedded Framework.framework"
export CHROMIUMKIT_HELPER_PATH="$BUILT_PRODUCTS_DIR/MyAppHelper"
export CHROMIUMKIT_HELPER_PLIST="$PKG/scripts/helper.plist.in"
"$PKG/scripts/embed-chromiumkit.sh"
```

---

## Codesigning details

The script does the right thing automatically:

- **Framework**: signed with your identity (or ad-hoc `-` in dev).
- **Host app**: signed with your identity *after* helpers + framework are in
  place, so the seal includes them.
- **Helper bundles**: explicitly **not** re-codesigned. Their executables are
  linker-signed at build time and Chromium's IPC handshake validates that
  exact signature byte-for-byte. Re-codesigning the bundle wraps the binary
  in a new signature and breaks the helpers with a `CHECK` fail inside
  `cef_execute_process`.

For Developer ID distribution: set your signing identity in the target's
Signing & Capabilities tab; `EXPANDED_CODE_SIGN_IDENTITY` flows through to
the script automatically.

---

## Hardened runtime, entitlements, notarization

For Developer ID distribution (the typical "ship outside the Mac App Store"
path) macOS requires Hardened Runtime, which blocks the things Chromium
needs by default — V8's JIT, executable-memory writes during V8 startup,
and cross-bundle `dlopen` of the framework from helper executables.

We ship two ready-made entitlements templates in this package. Copy them
into your project and point your targets at them:

| Template | Apply to |
|---|---|
| `Resources/entitlements/CEFKit.host.entitlements` | Your host app target (`CODE_SIGN_ENTITLEMENTS` build setting) |
| `Resources/entitlements/CEFKit.helper.entitlements` | Your helper executable target |

Both files set:

```xml
<key>com.apple.security.cs.allow-jit</key><true/>
<key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
<key>com.apple.security.cs.disable-library-validation</key><true/>
```

These are exceptions to Hardened Runtime — they tell macOS that yes, this
process really does need to JIT, mark memory as executable, and load
libraries that weren't signed by the same team.

**App Sandbox.** Don't enable the App Sandbox capability. CEF/Chromium runs
its own multi-process sandbox; layering Apple's App Sandbox on top breaks
inter-process communication. Mac App Store distribution is therefore not
supported.

### Helper bundle signing under hardened runtime

`embed-chromiumkit.sh` signs the 5 helper `.app` bundles for you **when a real
signing identity is in play**. It keys off `EXPANDED_CODE_SIGN_IDENTITY`:

- **Ad-hoc dev builds** (identity `-`): helpers are left **linker-signed** and
  untouched — Chromium's IPC handshake validates those signatures byte-for-byte
  and a naive ad-hoc re-sign trips a `CHECK` inside `cef_execute_process`.
- **Developer ID builds**: each helper is re-signed with your identity, the
  Hardened Runtime (`--options runtime`), a secure `--timestamp`, and the helper
  entitlements. Apple notarization rejects the un-notarizable linker-signed
  helpers, so a shipping build needs these proper same-team signatures — exactly
  what Chrome/Electron/Slack ship. Same-team re-signing keeps the IPC handshake
  valid because every process shares one Team ID.

The entitlements file defaults to the package's
`Resources/entitlements/CEFKit.helper.entitlements`; override it by exporting
`CHROMIUMKIT_HELPER_ENTITLEMENTS` before the script runs. You do **not** need a
second Run Script Phase for helper signing.

Verify with `codesign --verify --deep --strict --verbose=4 YourApp.app` and
test on a Mac without your dev cert installed before submitting for
notarization.

### Notarization checklist

1. Apply both entitlements templates (host + helpers)
2. `embed-chromiumkit.sh` codesigns the helpers with your Developer ID + helper entitlements automatically (real identity only)
3. Let Xcode handle the host signing (uses host entitlements via `CODE_SIGN_ENTITLEMENTS`)
4. Archive (`xcodebuild archive ...`)
5. `xcrun notarytool submit YourApp.zip --keychain-profile <profile> --wait`
6. `xcrun stapler staple YourApp.app`

---

## Dev-only friction

First launch of every freshly-linked binary prompts "Your App wants to use
your confidential information stored in 'Chromium Safe Storage' in your
keychain." Click **Always Allow** once per binary hash. Each recompile
produces a new hash and prompts again — annoying but harmless in dev.

For shipping builds, your stable signing identity gives the binary a stable
identity in the keychain and the prompt only appears once per user per app.
