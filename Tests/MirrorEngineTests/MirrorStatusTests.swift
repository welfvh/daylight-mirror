import XCTest
@testable import MirrorEngine

final class MirrorStatusTests: XCTestCase {

    // MARK: - Equality

    func testIdleEqualsIdle() {
        XCTAssertEqual(MirrorStatus.idle, MirrorStatus.idle)
    }

    func testWaitingForDeviceEqualsWaitingForDevice() {
        XCTAssertEqual(MirrorStatus.waitingForDevice, MirrorStatus.waitingForDevice)
    }

    func testStartingEqualsStarting() {
        XCTAssertEqual(MirrorStatus.starting, MirrorStatus.starting)
    }

    func testRunningEqualsRunning() {
        XCTAssertEqual(MirrorStatus.running, MirrorStatus.running)
    }

    func testStoppingEqualsStopping() {
        XCTAssertEqual(MirrorStatus.stopping, MirrorStatus.stopping)
    }

    func testErrorEqualsSameMessage() {
        XCTAssertEqual(MirrorStatus.error("timeout"), MirrorStatus.error("timeout"))
    }

    func testErrorEqualsEmptyMessage() {
        XCTAssertEqual(MirrorStatus.error(""), MirrorStatus.error(""))
    }

    // MARK: - Inequality

    func testIdleNotEqualRunning() {
        XCTAssertNotEqual(MirrorStatus.idle, MirrorStatus.running)
    }

    func testIdleNotEqualStarting() {
        XCTAssertNotEqual(MirrorStatus.idle, MirrorStatus.starting)
    }

    func testIdleNotEqualStopping() {
        XCTAssertNotEqual(MirrorStatus.idle, MirrorStatus.stopping)
    }

    func testIdleNotEqualWaitingForDevice() {
        XCTAssertNotEqual(MirrorStatus.idle, MirrorStatus.waitingForDevice)
    }

    func testRunningNotEqualStopping() {
        XCTAssertNotEqual(MirrorStatus.running, MirrorStatus.stopping)
    }

    func testStartingNotEqualRunning() {
        XCTAssertNotEqual(MirrorStatus.starting, MirrorStatus.running)
    }

    func testErrorDifferentMessages() {
        XCTAssertNotEqual(MirrorStatus.error("x"), MirrorStatus.error("y"))
    }

    func testErrorNotEqualIdle() {
        XCTAssertNotEqual(MirrorStatus.error("something"), MirrorStatus.idle)
    }

    func testErrorNotEqualRunning() {
        XCTAssertNotEqual(MirrorStatus.error("fail"), MirrorStatus.running)
    }

    // MARK: - All cases exist

    func testAllCasesCanBeConstructed() {
        // Verify every case of MirrorStatus can be created
        let cases: [MirrorStatus] = [
            .idle,
            .waitingForDevice,
            .starting,
            .running,
            .stopping,
            .error("test"),
        ]
        XCTAssertEqual(cases.count, 6, "MirrorStatus should have 6 cases")
    }

    func testEachCaseIsDistinct() {
        let cases: [MirrorStatus] = [
            .idle,
            .waitingForDevice,
            .starting,
            .running,
            .stopping,
            .error("test"),
        ]
        // Every pair should be unequal
        for i in 0..<cases.count {
            for j in (i + 1)..<cases.count {
                XCTAssertNotEqual(cases[i], cases[j],
                                  "\(cases[i]) should not equal \(cases[j])")
            }
        }
    }
}
