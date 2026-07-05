import XCTest

final class HibernateTabUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Isolate from the real session store: a fresh temp SQLite per run.
        app.launchEnvironment["HELLOCHROMIUM_STORE_PATH"] =
            NSTemporaryDirectory() + "ck-hibernate-\(UUID().uuidString).sqlite"
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    /// Right-click a sidebar row → choose Hibernate → assert the row sprouts the
    /// `moon.zzz` badge. Then right-click again → Wake up → assert the badge is gone.
    func testHibernateThenWake() {
        // The seeded session has one tab at launch; grab the first row.
        let firstRow = app.outlines.firstMatch.outlineRows.element(boundBy: 0)
        XCTAssertTrue(firstRow.waitForExistence(timeout: 10), "first tab row missing")

        let badge = firstRow.images["tabRow.hibernatedBadge"]
        XCTAssertFalse(badge.exists, "row should start awake (no badge)")

        // Right-clicking the outline row directly reports "not hittable" —
        // route via a coordinate inside the row instead.
        firstRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        app.menuItems["Hibernate"].click()

        XCTAssertTrue(badge.waitForExistence(timeout: 2), "badge should appear after Hibernate")

        // Attach a screenshot of the hibernated state so the PR has a visual.
        let shot = XCUIScreen.main.screenshot()
        let attach = XCTAttachment(screenshot: shot)
        attach.name = "hibernated-state"
        attach.lifetime = .keepAlways
        add(attach)

        firstRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        app.menuItems["Wake up"].click()

        // The badge view goes away when the tab wakes.
        let badgeGone = NSPredicate(format: "exists == NO")
        let exp = expectation(for: badgeGone, evaluatedWith: badge)
        wait(for: [exp], timeout: 2)
    }
}
