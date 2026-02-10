import XCTest
@testable import MirrorEngine

final class SemverTests: XCTestCase {
    func testNewerMajor() {
        XCTAssertTrue(UpdateChecker.isNewer(remote: "2.0.0", local: "1.0.0"))
    }

    func testNewerMinor() {
        XCTAssertTrue(UpdateChecker.isNewer(remote: "1.1.0", local: "1.0.0"))
    }

    func testNewerPatch() {
        XCTAssertTrue(UpdateChecker.isNewer(remote: "1.0.1", local: "1.0.0"))
    }

    func testSameVersion() {
        XCTAssertFalse(UpdateChecker.isNewer(remote: "1.3.0", local: "1.3.0"))
    }

    func testOlderVersion() {
        XCTAssertFalse(UpdateChecker.isNewer(remote: "1.2.0", local: "1.3.0"))
    }

    func testMismatchedComponents() {
        XCTAssertTrue(UpdateChecker.isNewer(remote: "1.0.0.1", local: "1.0.0"))
        XCTAssertFalse(UpdateChecker.isNewer(remote: "1.0.0", local: "1.0.0.1"))
    }

    func testTwoComponentVersion() {
        XCTAssertTrue(UpdateChecker.isNewer(remote: "1.1", local: "1.0"))
        XCTAssertFalse(UpdateChecker.isNewer(remote: "1.0", local: "1.1"))
    }
}
