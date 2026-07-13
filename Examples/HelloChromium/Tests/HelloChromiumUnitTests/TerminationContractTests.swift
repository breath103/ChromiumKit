import AppKit
import ChromiumKit
import XCTest

/// A stub `NSApplicationDelegate` that records `applicationShouldTerminate`
/// invocations and returns a configurable reply.
private final class StubTerminationDelegate: NSObject, NSApplicationDelegate {
    var reply: NSApplication.TerminateReply = .terminateCancel
    private(set) var shouldTerminateCallCount = 0

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        shouldTerminateCallCount += 1
        return reply
    }
}

/// Proves `_CEFNSApplication.terminate:` runs the NSApplication delegate
/// termination contract (the PR #44 fix): `applicationShouldTerminate` fires,
/// `NSTerminateCancel` is honored (no unwind, process stays alive), and
/// `NSTerminateLater` defers until `replyToApplicationShouldTerminate:`.
///
/// Hosted by HelloChromium.app, whose NSApp IS a live `_CEFNSApplication`. The
/// tests only exercise replies that do NOT unwind the run loop (`Cancel`, and
/// `Later` + reply(false)), so they never quit the host app mid-test-run.
final class TerminationContractTests: XCTestCase {
    private var app: NSApplication!
    private var stub: StubTerminationDelegate!
    private var previousDelegate: NSApplicationDelegate?

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard let cls = NSClassFromString("_CEFNSApplication") as? NSApplication.Type else {
            XCTFail("_CEFNSApplication is not linked into the test bundle")
            return
        }
        // `sharedApplication` creates the singleton from the receiving class the
        // first time it's called. If some other test/harness already created a
        // plain NSApplication, we can't retrofit the subclass — skip, don't fail.
        let shared = cls.shared
        guard type(of: shared) == cls else {
            throw XCTSkip("NSApp already exists as \(type(of: shared)), not _CEFNSApplication")
        }
        app = shared
        stub = StubTerminationDelegate()
        previousDelegate = app.delegate
        app.delegate = stub
    }

    override func tearDown() {
        if let app {
            app.delegate = previousDelegate
        }
        app = nil
        stub = nil
        previousDelegate = nil
        super.tearDown()
    }

    private func observeWillTerminate(_ posted: UnsafeMutablePointer<Bool>) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: app,
            queue: nil
        ) { _ in posted.pointee = true }
    }

    func testTerminateInvokesDelegateAndHonorsCancel() {
        var willTerminatePosted = false
        let observer = observeWillTerminate(&willTerminatePosted)
        defer { NotificationCenter.default.removeObserver(observer) }

        stub.reply = .terminateCancel
        app.terminate(nil)

        // The delegate contract ran…
        XCTAssertEqual(stub.shouldTerminateCallCount, 1)
        // …and Cancel was honored: no willTerminate, no unwind — we're still here.
        XCTAssertFalse(willTerminatePosted)
    }

    func testTerminateLaterDefersUntilReplyAndHonorsFalse() {
        var willTerminatePosted = false
        let observer = observeWillTerminate(&willTerminatePosted)
        defer { NotificationCenter.default.removeObserver(observer) }

        stub.reply = .terminateLater
        app.terminate(nil)

        XCTAssertEqual(stub.shouldTerminateCallCount, 1)
        // Deferred: nothing happens until the delegate replies.
        XCTAssertFalse(willTerminatePosted)

        // reply(false) = the delegate aborted the quit; still no unwind.
        app.reply(toApplicationShouldTerminate: false)
        XCTAssertFalse(willTerminatePosted)

        // The deferred flag must have been consumed: a Cancel quit afterwards
        // still routes through the delegate normally.
        stub.reply = .terminateCancel
        app.terminate(nil)
        XCTAssertEqual(stub.shouldTerminateCallCount, 2)
        XCTAssertFalse(willTerminatePosted)
    }
}
