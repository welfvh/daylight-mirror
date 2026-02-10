import XCTest
@testable import MirrorEngine

final class ConfigurationTests: XCTestCase {
    func testAllResolutionsAre4by3() {
        for res in DisplayResolution.allCases {
            let ratio = Double(res.width) / Double(res.height)
            XCTAssertEqual(ratio, 4.0 / 3.0, accuracy: 0.01,
                           "\(res.label) should be 4:3 but is \(res.width)x\(res.height)")
        }
    }

    func testCozyIsHiDPI() {
        XCTAssertTrue(DisplayResolution.cozy.isHiDPI)
    }

    func testNonCozyAreNotHiDPI() {
        let nonCozy: [DisplayResolution] = [.comfortable, .balanced, .sharp]
        for res in nonCozy {
            XCTAssertFalse(res.isHiDPI, "\(res.label) should not be HiDPI")
        }
    }

    func testResolutionRawValueRoundTrips() {
        for res in DisplayResolution.allCases {
            XCTAssertEqual(DisplayResolution(rawValue: res.rawValue), res)
        }
    }

    func testSharpIsNativePanel() {
        XCTAssertEqual(DisplayResolution.sharp.width, 1600)
        XCTAssertEqual(DisplayResolution.sharp.height, 1200)
    }

    func testCozyPixelDimensionsMatchNativePanel() {
        XCTAssertEqual(DisplayResolution.cozy.width, 1600)
        XCTAssertEqual(DisplayResolution.cozy.height, 1200)
    }
}
