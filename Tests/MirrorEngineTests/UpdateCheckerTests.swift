import XCTest
@testable import MirrorEngine

final class UpdateCheckerTests: XCTestCase {

    // MARK: - Same version

    func testSameVersionIsNotNewer() {
        XCTAssertFalse(UpdateChecker.isNewer(remote: "1.0.0", local: "1.0.0"))
    }

    func testSameVersionTwoComponents() {
        XCTAssertFalse(UpdateChecker.isNewer(remote: "2.5", local: "2.5"))
    }

    func testSameVersionFourComponents() {
        XCTAssertFalse(UpdateChecker.isNewer(remote: "1.2.3.4", local: "1.2.3.4"))
    }

    // MARK: - Single component versions

    func testSingleComponentNewer() {
        XCTAssertTrue(UpdateChecker.isNewer(remote: "2", local: "1"))
    }

    func testSingleComponentOlder() {
        XCTAssertFalse(UpdateChecker.isNewer(remote: "1", local: "2"))
    }

    func testSingleComponentEqual() {
        XCTAssertFalse(UpdateChecker.isNewer(remote: "3", local: "3"))
    }

    // MARK: - Empty / malformed input

    func testEmptyRemoteIsNotNewer() {
        // Empty string → no numeric components → treated as 0.0.0
        XCTAssertFalse(UpdateChecker.isNewer(remote: "", local: "1.0.0"))
    }

    func testEmptyLocalMakesRemoteNewer() {
        XCTAssertTrue(UpdateChecker.isNewer(remote: "1.0.0", local: ""))
    }

    func testBothEmptyIsNotNewer() {
        XCTAssertFalse(UpdateChecker.isNewer(remote: "", local: ""))
    }

    // MARK: - Mismatched component counts

    func testRemoteHasMoreComponents() {
        // "1.0.0.1" vs "1.0.0" — remote has extra .1, treated as newer
        XCTAssertTrue(UpdateChecker.isNewer(remote: "1.0.0.1", local: "1.0.0"))
    }

    func testLocalHasMoreComponents() {
        // "1.0.0" vs "1.0.0.1" — local has extra .1, remote is older
        XCTAssertFalse(UpdateChecker.isNewer(remote: "1.0.0", local: "1.0.0.1"))
    }

    func testTwoVsThreeComponents() {
        XCTAssertTrue(UpdateChecker.isNewer(remote: "1.1", local: "1.0"))
        XCTAssertFalse(UpdateChecker.isNewer(remote: "1.0", local: "1.1"))
    }

    // MARK: - Large version numbers

    func testLargeVersionNumbers() {
        XCTAssertTrue(UpdateChecker.isNewer(remote: "100.200.300", local: "100.200.299"))
        XCTAssertFalse(UpdateChecker.isNewer(remote: "100.200.299", local: "100.200.300"))
    }

    // MARK: - Non-numeric components are dropped

    func testNonNumericComponentsIgnored() {
        // "v1.0.0" → split by "." → ["v1", "0", "0"] → compactMap Int → [0, 0]
        // because "v1" is not a valid Int. This tests the raw isNewer behavior.
        // The v-prefix stripping happens in check(), not isNewer().
        // So "v1.0.0" effectively becomes [0, 0] (only "0" and "0" parse).
        // vs "0.9.0" → [0, 9, 0]
        // [0,0] vs [0,9,0] → 0==0, 0<9 → false
        XCTAssertFalse(UpdateChecker.isNewer(remote: "v1.0.0", local: "0.9.0"))
    }

    // MARK: - Boundary cases

    func testZeroVersions() {
        XCTAssertFalse(UpdateChecker.isNewer(remote: "0.0.0", local: "0.0.0"))
    }

    func testZeroVsOne() {
        XCTAssertTrue(UpdateChecker.isNewer(remote: "0.0.1", local: "0.0.0"))
    }

    func testMajorBumpOverridesMinorAndPatch() {
        XCTAssertTrue(UpdateChecker.isNewer(remote: "2.0.0", local: "1.99.99"))
    }

    func testMinorBumpOverridesPatch() {
        XCTAssertTrue(UpdateChecker.isNewer(remote: "1.2.0", local: "1.1.99"))
    }
}
