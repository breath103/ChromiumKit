import Foundation
import SwiftData

/// A persisted browsing session — one window's worth of tabs plus which tab is
/// selected. Every `TabRecord` belongs to exactly one `Session` (its
/// `session_id`). Selection lives here so it survives a relaunch with no side
/// table. Today the app uses a single current session (the most recently
/// created one); the concept leaves room for multiple windows later.
@Model
final class Session {
    @Attribute(.unique) var id: UUID
    var createdAt: Date

    /// The `id` of the active tab. Mutating it persists *and* re-renders every
    /// view bound to the session, through the same Observation path as the tabs.
    var selectedTabID: UUID?

    /// Cascade: deleting a session deletes its tabs.
    @Relationship(deleteRule: .cascade, inverse: \TabRecord.session)
    var tabs: [TabRecord] = []

    init(id: UUID = UUID(), createdAt: Date = .now) {
        self.id = id
        self.createdAt = createdAt
    }

    /// Tabs in their persisted left-to-right order.
    var orderedTabs: [TabRecord] {
        tabs.sorted { $0.sortIndex < $1.sortIndex }
    }
}
