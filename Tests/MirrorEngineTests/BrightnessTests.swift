import XCTest
@testable import MirrorEngine

final class BrightnessTests: XCTestCase {
    func testSliderAtZeroReturnsOff() {
        XCTAssertEqual(MirrorEngine.brightnessFromSliderPos(0.0), 0)
    }

    func testSliderBelowDeadzoneReturnsOff() {
        XCTAssertEqual(MirrorEngine.brightnessFromSliderPos(0.02), 0)
    }

    func testSliderAtDeadzoneEdgeReturnsMinimum() {
        let result = MirrorEngine.brightnessFromSliderPos(0.04)
        XCTAssertEqual(result, 1, "Just past deadzone should return minimum brightness")
    }

    func testSliderAtMaxReturnsMax() {
        XCTAssertEqual(MirrorEngine.brightnessFromSliderPos(1.0), 255)
    }

    func testSliderAtHalfIsQuadratic() {
        let result = MirrorEngine.brightnessFromSliderPos(0.5)
        // 0.5^2 * 255 = 63.75 → 63
        XCTAssertEqual(result, 63)
    }

    func testSliderIsMonotonic() {
        var prev = MirrorEngine.brightnessFromSliderPos(0.0)
        for i in 1...100 {
            let pos = Double(i) / 100.0
            let val = MirrorEngine.brightnessFromSliderPos(pos)
            XCTAssertGreaterThanOrEqual(val, prev, "Brightness must be monotonically increasing at pos=\(pos)")
            prev = val
        }
    }

    func testSliderOutputRange() {
        for i in 0...100 {
            let pos = Double(i) / 100.0
            let val = MirrorEngine.brightnessFromSliderPos(pos)
            XCTAssertGreaterThanOrEqual(val, 0)
            XCTAssertLessThanOrEqual(val, 255)
        }
    }
}
