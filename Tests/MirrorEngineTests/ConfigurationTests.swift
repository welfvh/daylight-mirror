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
        let nonCozy: [DisplayResolution] = [.comfortable, .balanced, .sharp, .widescreen,
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

    func testWidescreenIs16by10() {
        let ratio = Double(DisplayResolution.widescreen.width) / Double(DisplayResolution.widescreen.height)
        XCTAssertEqual(ratio, 16.0 / 10.0, accuracy: 0.01)
    }

    func testFrameHeaderSizeIs11() {
        XCTAssertEqual(FRAME_HEADER_SIZE, 11)
    }
}
