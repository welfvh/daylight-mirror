import XCTest
@testable import MirrorEngine

final class ConfigurationTests: XCTestCase {
    func testLandscape4x3ResolutionsAre4by3() {
        let landscape: [DisplayResolution] = [.cozy, .comfortable, .balanced, .sharp]
        for res in landscape {
            let ratio = Double(res.width) / Double(res.height)
            XCTAssertEqual(ratio, 4.0 / 3.0, accuracy: 0.01,
                           "\(res.label) should be 4:3 but is \(res.width)x\(res.height)")
        }
    }

    func testPortraitResolutionsAre3by4() {
        let portrait: [DisplayResolution] = [.portraitCozy, .portraitComfortable, .portraitBalanced, .portraitSharp]
        for res in portrait {
            let ratio = Double(res.width) / Double(res.height)
            XCTAssertEqual(ratio, 3.0 / 4.0, accuracy: 0.01,
                           "\(res.label) should be 3:4 but is \(res.width)x\(res.height)")
        }
    }

    func testPortraitPresetsHaveHeightGreaterThanWidth() {
        let portrait: [DisplayResolution] = [.portraitCozy, .portraitComfortable, .portraitBalanced, .portraitSharp]
        for res in portrait {
            XCTAssertGreaterThan(res.height, res.width, "\(res.label) should have height > width")
            XCTAssertTrue(res.isPortrait, "\(res.label) should report isPortrait=true")
        }
    }

    func testCozyIsHiDPI() {
        XCTAssertTrue(DisplayResolution.cozy.isHiDPI)
        XCTAssertTrue(DisplayResolution.portraitCozy.isHiDPI)
    }

    func testNonCozyAreNotHiDPI() {
        let nonCozy: [DisplayResolution] = [.comfortable, .balanced, .sharp,
                                            .portraitComfortable, .portraitBalanced, .portraitSharp]
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

    func testPortraitSharpIsNativePanelRotated() {
        XCTAssertEqual(DisplayResolution.portraitSharp.width, 1200)
        XCTAssertEqual(DisplayResolution.portraitSharp.height, 1600)
    }

    func testTargetFPSIs60() {
        XCTAssertEqual(TARGET_FPS, 60)
    }

    func testTargetFPSDoesNotExceedPanelLimit() {
        XCTAssertLessThanOrEqual(TARGET_FPS, 120,
            "DC-1 panel supports up to 120Hz")
    }

    func testKeyframeIntervalMatchesFPS() {
        XCTAssertEqual(KEYFRAME_INTERVAL, TARGET_FPS,
            "Keyframe interval should equal TARGET_FPS (one keyframe per second)")
    }

    func testFrameHeaderSizeIs11() {
        XCTAssertEqual(FRAME_HEADER_SIZE, 11)
    }

    func testPortraitComfortableDimensions() {
        XCTAssertEqual(DisplayResolution.portraitComfortable.width, 768)
        XCTAssertEqual(DisplayResolution.portraitComfortable.height, 1024)
    }

    func testLandscapePresetsAreNotPortrait() {
        let landscape: [DisplayResolution] = [.cozy, .comfortable, .balanced, .sharp]
        for res in landscape {
            XCTAssertFalse(res.isPortrait, "\(res.label) should not be portrait")
        }
    }

    // MARK: - Backpressure formula

    func testBackpressureAtLowRTT() {
        // RTT 10ms → 120/10 = 12, clamped to max 6
        XCTAssertEqual(adaptiveBackpressureThreshold(rttMs: 10.0), 6)
    }

    func testBackpressureAtTypicalRTT() {
        // RTT 30ms → 120/30 = 4
        XCTAssertEqual(adaptiveBackpressureThreshold(rttMs: 30.0), 4)
    }

    func testBackpressureAtHighRTT() {
        // RTT 60ms → 120/60 = 2 (floor)
        XCTAssertEqual(adaptiveBackpressureThreshold(rttMs: 60.0), 2)
    }

    func testBackpressureAtVeryHighRTT() {
        // RTT 200ms → 120/200 = 0, clamped to min 2
        XCTAssertEqual(adaptiveBackpressureThreshold(rttMs: 200.0), 2)
    }

    func testBackpressureNeverBelowTwo() {
        for rtt in stride(from: 1.0, through: 500.0, by: 10.0) {
            XCTAssertGreaterThanOrEqual(adaptiveBackpressureThreshold(rttMs: rtt), 2,
                "Threshold must be >= 2 at RTT \(rtt)ms to prevent keyframe cascade")
        }
    }

    func testBackpressureNeverAboveSix() {
        for rtt in stride(from: 1.0, through: 500.0, by: 10.0) {
            XCTAssertLessThanOrEqual(adaptiveBackpressureThreshold(rttMs: rtt), 6,
                "Threshold must be <= 6 at RTT \(rtt)ms to maintain backpressure")
        }
    }

    func testBackpressureHandlesZeroRTT() {
        // RTT 0ms → max(0,1) = 1 → 120/1 = 120, clamped to 6
        XCTAssertEqual(adaptiveBackpressureThreshold(rttMs: 0.0), 6)
    }

    func testBackpressureHandlesNegativeRTT() {
        // Negative RTT (shouldn't happen but guard against it)
        XCTAssertEqual(adaptiveBackpressureThreshold(rttMs: -5.0), 6)
    }

    // MARK: - Trivial delta threshold

    func testTrivialDeltaThresholdIsReasonable() {
        XCTAssertGreaterThan(TRIVIAL_DELTA_THRESHOLD, 0)
        XCTAssertLessThan(TRIVIAL_DELTA_THRESHOLD, 4096,
            "Threshold should be small enough to only skip near-empty deltas")
    }
}
