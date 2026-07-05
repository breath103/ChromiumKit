import AppKit
import Foundation
import SwiftData

/// One persisted browser tab. The SwiftData row IS the shared, observable source
/// of truth: a single `ModelContext` hands back one instance per row, so the
/// record shown in the sidebar, the address bar, and the detail pane is the
/// same object. The live `ChromiumWebView` writes navigation updates straight
/// into these properties (see `TabRuntime`), which both persists to SQLite and
/// re-renders every view that reads them — no second copy to keep in sync.
@Model
final class TabRecord {
    @Attribute(.unique) var id: UUID
    var url: URL
    var title: String

    /// Favicon bytes, kept out of the SQLite row so the table stays small. Lets
    /// a cold launch paint favicons for hibernated tabs without loading them.
    @Attribute(.externalStorage) var faviconPNG: Data?

    /// Explicit left-to-right order within the owning session (SwiftData rows
    /// have no inherent order).
    var sortIndex: Int

    /// Owning session (the `session_id` back-reference).
    var session: Session?

    init(id: UUID = UUID(), url: URL, title: String = "", sortIndex: Int, session: Session? = nil) {
        self.id = id
        self.url = url
        self.title = title
        self.sortIndex = sortIndex
        self.session = session
    }

    /// Title for display, falling back to the host then a placeholder.
    var displayTitle: String {
        if !title.isEmpty { return title }
        return url.host() ?? "new tab"
    }

    /// Decoded favicon, or nil while none has loaded.
    var displayFavicon: NSImage? {
        faviconPNG.flatMap(NSImage.init(data:))
    }
}
