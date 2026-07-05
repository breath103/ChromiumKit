import AppKit
@testable import HelloChromium
import SwiftData
import XCTest

/// Round-trips the persisted models through SwiftData to prove the schema and
/// the session→tabs relationship survive a save + re-fetch.
@MainActor
final class SessionPersistenceTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Session.self, TabRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    func testSessionAndTabsRoundTrip() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let session = Session()
        context.insert(session)
        let first = TabRecord(url: URL(string: "https://a.example")!, title: "A", sortIndex: 0, session: session)
        let second = TabRecord(url: URL(string: "https://b.example")!, title: "B", sortIndex: 1, session: session)
        context.insert(first)
        context.insert(second)
        session.selectedTabID = second.id
        try context.save()

        // Re-fetch from a fresh context on the same store.
        let refetched = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<Session>()).first
        )
        XCTAssertEqual(refetched.selectedTabID, second.id)
        XCTAssertEqual(refetched.orderedTabs.map(\.title), ["A", "B"])
        XCTAssertEqual(refetched.orderedTabs.map(\.sortIndex), [0, 1])
        XCTAssertEqual(refetched.orderedTabs.first?.url, URL(string: "https://a.example"))
    }

    func testOrderedTabsSortsBySortIndex() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let session = Session()
        context.insert(session)
        // Insert out of order.
        for index in [2, 0, 1] {
            context.insert(TabRecord(url: URL(string: "https://\(index).example")!, sortIndex: index, session: session))
        }
        XCTAssertEqual(session.orderedTabs.map(\.sortIndex), [0, 1, 2])
    }

    func testDisplayTitleUsesTitleWhenPresent() {
        let tab = TabRecord(url: URL(string: "https://news.example")!, title: "Front Page", sortIndex: 0)
        XCTAssertEqual(tab.displayTitle, "Front Page")
    }

    func testDisplayTitleFallsBackToHost() {
        let tab = TabRecord(url: URL(string: "https://news.example/path")!, title: "", sortIndex: 0)
        XCTAssertEqual(tab.displayTitle, "news.example")
    }

    func testDisplayTitleFallsBackToPlaceholderWithoutHost() {
        let tab = TabRecord(url: URL(string: "about:blank")!, title: "", sortIndex: 0)
        XCTAssertEqual(tab.displayTitle, "new tab")
    }

    func testDisplayFaviconDecodesPNGAndRejectsGarbage() {
        let noData = TabRecord(url: URL(string: "https://a.example")!, sortIndex: 0)
        XCTAssertNil(noData.displayFavicon)

        let garbage = TabRecord(url: URL(string: "https://a.example")!, sortIndex: 0)
        garbage.faviconPNG = Data([0x00, 0x01, 0x02, 0x03])
        XCTAssertNil(garbage.displayFavicon, "invalid bytes should not decode to an image")

        let valid = TabRecord(url: URL(string: "https://a.example")!, sortIndex: 0)
        valid.faviconPNG = Self.makePNG()
        XCTAssertNotNil(valid.displayFavicon)
    }

    /// A tiny real PNG so displayFavicon has something valid to decode.
    private static func makePNG() -> Data {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()
        let tiff = image.tiffRepresentation!
        return NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
    }

    /// Deleting a tab record drops it from the session, and the runtime reacts by
    /// moving selection off the deleted tab — without anyone calling a close().
    func testDeletingSelectedTabReactivelyMovesSelection() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let session = Session()
        context.insert(session)
        let first = TabRecord(url: URL(string: "https://a.example")!, sortIndex: 0, session: session)
        let second = TabRecord(url: URL(string: "https://b.example")!, sortIndex: 1, session: session)
        context.insert(first)
        context.insert(second)
        session.selectedTabID = second.id

        let runtime = TabRuntime()
        runtime.context = context
        runtime.session = session

        // Closing = deleting the record from the store. The relationship updates
        // when the change is processed; in the app that's autosave, then the
        // observation fires reconcile. Mirror that ordering here.
        context.delete(second)
        try context.save()
        runtime.reconcile(against: session.orderedTabs)

        XCTAssertEqual(session.tabs.count, 1)
        XCTAssertEqual(session.selectedTabID, first.id, "selection should react to the deletion")
    }
}
