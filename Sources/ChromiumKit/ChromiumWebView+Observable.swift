@_exported import ChromiumViewObjC
import ObjectiveC

private var observableKey: UInt8 = 0

@available(macOS 14, *)
public extension ChromiumWebView {
    /// Per-webView lazy singleton `@Observable` bridge for SwiftUI binding.
    /// Same instance every call — safe to read from view bodies.
    var observable: ChromiumWebViewObservable {
        if let existing = objc_getAssociatedObject(self, &observableKey) as? ChromiumWebViewObservable {
            return existing
        }
        let made = ChromiumWebViewObservable(self)
        objc_setAssociatedObject(self, &observableKey, made, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return made
    }
}
