@testable import HelloChromium
import SwiftData
import XCTest

/// Model-level behavior of TabRuntime that doesn't need a live web view:
/// new-tab ordering/selection and the reactive reconcile against deletions.
@MainActor
final class TabRuntimeTests: XCTestCase {
    // The container must be held by the test — if it deallocates, its context
    // and models are invalidated ("destroyed by ModelContext.reset").
    private struct Rig {
        let runtime: TabRuntime
        let container: ModelContainer
        let session: Session
    }

    private func makeRig() throws -> Rig {
        let container = try ModelContainer(
            for: Session.self, TabRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let session = Session()
        container.mainContext.insert(session)
        let runtime = TabRuntime()
        runtime.context = container.mainContext
        runtime.session = session
        return Rig(runtime: runtime, container: container, session: session)
    }

    func testNewTabAssignsSequentialSortIndexAndSelects() throws {
        let rig = try makeRig()

        let first = rig.runtime.newTab(in: rig.session, url: URL(string: "https://a.example")!)
        XCTAssertEqual(first.sortIndex, 0)
        XCTAssertEqual(rig.session.selectedTabID, first.id)

        let second = rig.runtime.newTab(in: rig.session, url: URL(string: "https://b.example")!)
        XCTAssertEqual(second.sortIndex, 1, "sortIndex should be max(existing) + 1")
        XCTAssertEqual(rig.session.selectedTabID, second.id, "a new tab becomes selected")
        XCTAssertEqual(rig.session.orderedTabs.count, 2)
    }

    func testReconcileLeavesSelectionWhenNonSelectedTabDeleted() throws {
        let rig = try makeRig()
        let keep = rig.runtime.newTab(in: rig.session, url: URL(string: "https://a.example")!)
        let doomed = rig.runtime.newTab(in: rig.session, url: URL(string: "https://b.example")!)
        rig.session.selectedTabID = keep.id

        rig.container.mainContext.delete(doomed)
        try rig.container.mainContext.save()
        rig.runtime.reconcile(against: rig.session.orderedTabs)

        XCTAssertEqual(rig.session.orderedTabs.count, 1)
        XCTAssertEqual(rig.session.selectedTabID, keep.id, "deleting a non-selected tab must not move selection")
    }

    func testReconcileClearsSelectionWhenLastTabDeleted() throws {
        let rig = try makeRig()
        let only = rig.runtime.newTab(in: rig.session, url: URL(string: "https://a.example")!)

        rig.container.mainContext.delete(only)
        try rig.container.mainContext.save()
        rig.runtime.reconcile(against: rig.session.orderedTabs)

        XCTAssertTrue(rig.session.orderedTabs.isEmpty)
        XCTAssertNil(rig.session.selectedTabID, "no tabs left → nothing selected")
    }
}
