import AppKit
@_exported import ChromiumViewObjC
import Foundation
import Observation

/// One favicon for one URL. `url` is fixed at construction; `image` lands
/// asynchronously when CEF's image loader finishes (nil while pending, or
/// if the download failed).
///
/// ChromiumView creates a fresh `Favicon` for each new favicon URL the page
/// reports, so a late download callback writing to a stale instance is
/// silently ignored — no race guard needed.
@available(macOS 14, *)
@Observable
public final class Favicon {
    public let url: URL
    public private(set) var image: NSImage?

    @ObservationIgnored private var imageObs: NSKeyValueObservation?

    init(_ ref: CEFFaviconRef) {
        url = ref.url
        image = ref.image
        imageObs = ref.observe(\.image, options: [.new]) { [weak self] _, c in
            self?.image = c.newValue ?? nil
        }
    }
}
