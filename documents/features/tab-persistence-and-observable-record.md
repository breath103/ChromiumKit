# Tab persistence + observable tab records (SwiftData)

## Problem

HelloChromium's tab state is in-memory only. `AppDelegate.makeWindow()`
hardcodes two tabs every launch; nothing survives a quit. And there's no clean
line between a tab's **durable data** (url, title, favicon) and its **live
runtime object** (`ChromiumWebView`) — `BrowserTab` carries ad-hoc `snapshot*`
fields that half-implement that idea and persist nowhere.

## Goal

1. **Persist every tab change to SQLite, restore on launch** — url, title,
   favicon, tab order, selection.
2. **One shared, observable source of truth per tab** so that changing a tab
   re-renders every view that mounts it (list row, address bar, detail) *and*
   saves to disk through the same act.

## Approach: SwiftData

SwiftData is SQLite-backed and its `@Model` types are `@Observable`. That makes
it the whole solution in one piece:

- The **DB row is the shared object.** A single `mainContext` returns **one
  instance per row**, so the `TabRecord` in the sidebar, the address bar, and
  the detail pane are literally the same object. Mutating `record.title`
  re-renders all of them (Observation) and autosaves to SQLite. This is the
  "share changes within the app" mechanism — there is no second copy to keep in
  sync, no `onChange`, no manual persist call.
- `@Query(sort: \.sortIndex)` gives an auto-updating, ordered tab list:
  insert/delete/reorder a row → the list re-renders.

### `Session` owns tabs; two models replace `BrowserTab` + `TabStore`

A **`Session`** is the persisted browsing session — a window's worth of tabs
plus which one is selected. Every `TabRecord` belongs to exactly one `Session`
(`session_id`). Selection lives on the session, so it persists in SQLite with no
side table. Today there is one current session; the concept leaves room for
multiple windows/sessions later.

**`Session` — the persisted session (`Session.swift`)**

```swift
@Model
final class Session {
    var id: UUID
    var selectedTabID: UUID?                              // which tab is active
    var createdAt: Date                                   // pick the current session
    @Relationship(deleteRule: .cascade, inverse: \TabRecord.session)
    var tabs: [TabRecord] = []                            // cascade: drop session → drop its tabs

    init() { … }
}
```

**`TabRecord` — the persisted, observable tab (`TabRecord.swift`)**

```swift
@Model
final class TabRecord {
    var id: UUID
    var url: URL
    var title: String
    @Attribute(.externalStorage) var faviconPNG: Data?   // blob stored out-of-row
    var sortIndex: Int                                    // explicit tab order
    var session: Session?                                 // owning session (session_id)

    init(url: URL, sortIndex: Int, session: Session) { … }
}
```

SwiftData has no inherent row order, hence `sortIndex` (ordered within a
session). `.externalStorage` keeps favicon bytes out of the SQLite row. No
`Codable`/`CodingKeys` to hand-write — SwiftData owns the schema. Selection
(`Session.selectedTabID`) is `@Observable` too, so changing the active tab
persists and re-renders through the same mechanism as everything else.

**`TabRuntime` — the live-object registry (`TabRuntime.swift`)**

The `ChromiumWebView` is an NSView-backed, non-persistable object; it must NOT
live on the model (`@Transient` is unreliable for Observation and pollutes the
persistence layer). Instead a `@MainActor @Observable` registry keyed by the
record's stable `persistentModelID` owns the live web views and the KVO glue:

```swift
@MainActor @Observable
final class TabRuntime: NSObject {
    private var webViews: [PersistentIdentifier: ChromiumWebView] = [:]
    var context: ModelContext!            // set at launch; used to insert popup tabs

    /// Live web view for a record, created lazily on first access (= waking it).
    func webView(for record: TabRecord) -> ChromiumWebView { … }

    /// Hibernate: drop the live view. The record keeps last url/title/favicon.
    func hibernate(_ record: TabRecord) { webViews[record.persistentModelID] = nil }

    func isAwake(_ record: TabRecord) -> Bool { webViews[record.persistentModelID] != nil }
}
```

When `webView(for:)` creates a `ChromiumWebView`, it installs
`NSKeyValueObservation`s on the view's `url` / `title` / `favicon` keys whose
callbacks **write straight into the `TabRecord`** — which persists *and*
re-renders in one move. `TabRuntime` is also the `ChromiumNavigationDelegate`:
`requestsNewTabFor` inserts a new `TabRecord` into `context` and returns the
shell web view (the existing `target="_blank"` flow, now record-backed).

This makes tabs **lazy**: on relaunch every tab is hibernated until selected, so
only the active tab spins up a Chromium browser — a strict improvement over
today's "all tabs live."

### Closing a tab is a deletion the runtime reacts to

Closing a tab is **deleting its `TabRecord` from the store** (`TabRow`'s context
menu calls `modelContext.delete(tab)`) — nothing more. The release of the live
`ChromiumWebView` is **not** wired into that action; it's a reaction to the
database changing. `TabRuntime.reconcileLiveTabs()` observes `session.orderedTabs`
via `withObservationTracking` and, on every change, drops any `LiveTab` whose
record no longer exists (tearing down the web view + its KVO observers) and moves
`selectedTabID` off a deleted tab. It re-arms itself after each change.

This keeps the database as the single source of truth: *any* path that removes a
record — the close button, a future multi-window sync, a debug action — frees the
connected web view automatically. There is no imperative `close()` that a caller
must remember to route the release through.

### Views

- `ContentView`: holds the current `Session` (passed in), reads
  `session.tabs` sorted by `sortIndex`, binds selection to `session.selectedTabID`,
  `@Environment(TabRuntime.self)`. List rows + a detail ZStack that mounts the web
  view for each currently-awake record (waking the selected one). Mutating
  `session.selectedTabID` persists + re-renders.
- `TabRow` / `AddressBar`: read `record.title` / `record.url` / `record.faviconPNG`
  (durable, always current because the web view writes into the record live).
  Ephemeral state (`isLoading`, `canGoBack/Forward`) is read from the live web
  view via `TabRuntime`.
- `displayTitle` (title-empty → host fallback) becomes a computed property on
  `TabRecord`.

### App wiring (`AppDelegate.swift`)

```swift
let storeURL = ProcessInfo.processInfo.environment["HELLOCHROMIUM_STORE_PATH"]
    .map(URL.init(fileURLWithPath:))
    ?? URL.applicationSupportDirectory.appending(path: "HelloChromium/tabs.sqlite")
container = try ModelContainer(for: TabRecord.self,
                               configurations: ModelConfiguration(url: storeURL))
runtime.context = container.mainContext
// seed one default tab iff the store is empty
let root = ContentView().modelContainer(container).environment(runtime)
window.contentView = NSHostingView(rootView: root)
```

- `HELLOCHROMIUM_STORE_PATH` env override = the test seam (UI test points it at a
  temp file, relaunches, asserts restore). Default = Application Support.
- `applicationWillTerminate` → `try? container.mainContext.save()` to flush
  (autosave is deferred).
- The hardcoded `store.newTab(...)` seeding is deleted.

**Selection** persists on the current `Session` (`selectedTabID`) — in SQLite,
no side table. On launch the current session is the most-recent `Session` row;
if none exists, seed one with a single default tab.

### Deleted

`BrowserTab.swift`, `TabStore.swift` — both subsumed by `TabRecord` + `TabRuntime`.

## No migration tooling

Client-side SQLite file managed by SwiftData. First launch / absent file → seed
one tab. Schema is v1; a future field change would use SwiftData's
`SchemaMigrationPlan`, out of scope here.

## Verification

- **Unit** (`HelloChromiumUnitTests`): insert `TabRecord`s into an in-memory
  `ModelContainer`, save, re-fetch, assert fields + `sortIndex` order survive.
- **UI** (`HelloChromiumUITests`): launch with `HELLOCHROMIUM_STORE_PATH`=temp →
  open + navigate a second tab → terminate → relaunch same path → assert tab
  count, titles, and selection restored.

## Risks

- **SwiftData under the AppKit lifecycle.** Confirmed fine: build the
  `ModelContainer` yourself, apply `.modelContainer(container)` to the root view
  before `NSHostingView`. Container lifetime is ours (stored on the delegate);
  `mainContext` is `@MainActor`.
- **Deferred autosave.** Mitigated by the explicit save on terminate.
- **Existing UI tests** (`TargetBlank`, `Hibernate`, `AddressBar`) assume the
  old in-memory model; they'll need light updates for the record-backed flow.
