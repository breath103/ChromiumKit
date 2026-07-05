import ChromiumKit
import XCTest

/// Covers the `useMockKeychain` config flag: its default, the Swift convenience
/// initializer wiring, and that `NSCopying` preserves it.
final class ChromiumConfigurationTests: XCTestCase {
    func testUseMockKeychainDefaultsFalse() {
        XCTAssertFalse(ChromiumConfiguration().useMockKeychain)
        XCTAssertFalse(ChromiumConfiguration(userAgent: "x").useMockKeychain)
    }

    func testConvenienceInitSetsUseMockKeychain() {
        XCTAssertTrue(ChromiumConfiguration(useMockKeychain: true).useMockKeychain)
    }

    func testCopyPreservesUseMockKeychain() throws {
        let config = ChromiumConfiguration(userAgent: "UA", useMockKeychain: true)
        let copy = try XCTUnwrap(config.copy() as? ChromiumConfiguration)
        XCTAssertTrue(copy.useMockKeychain)
        XCTAssertEqual(copy.userAgent, "UA")
    }
}
