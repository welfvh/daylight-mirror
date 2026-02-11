import XCTest
@testable import MirrorEngine

final class DisplayControllerTests: XCTestCase {

    private var tcpServer: TCPServer!
    private var controller: DisplayController!

    override func setUp() {
        super.setUp()
        // Create a TCPServer on a high port — never started, so no actual listening.
        // sendCommand just iterates an empty connections array, which is safe.
        tcpServer = try! TCPServer(port: 19888)
        controller = DisplayController(tcpServer: tcpServer)
    }

    override func tearDown() {
        controller = nil
        tcpServer = nil
        super.tearDown()
    }

    // MARK: - Initial state

    func testInitialBrightness() {
        XCTAssertEqual(controller.currentBrightness, 128)
    }

    func testInitialWarmth() {
        XCTAssertEqual(controller.currentWarmth, 128)
    }

    func testInitialBacklightOn() {
        XCTAssertTrue(controller.backlightOn)
    }

    func testInitialSavedBrightness() {
        XCTAssertEqual(controller.savedBrightness, 128)
    }

    // MARK: - setBrightness clamping

    func testSetBrightnessNormal() {
        controller.setBrightness(200)
        XCTAssertEqual(controller.currentBrightness, 200)
    }

    func testSetBrightnessClampsAbove255() {
        controller.setBrightness(300)
        XCTAssertEqual(controller.currentBrightness, 255)
    }

    func testSetBrightnessClampsBelowZero() {
        controller.setBrightness(-5)
        XCTAssertEqual(controller.currentBrightness, 0)
    }

    func testSetBrightnessAtZero() {
        controller.setBrightness(0)
        XCTAssertEqual(controller.currentBrightness, 0)
    }

    func testSetBrightnessAt255() {
        controller.setBrightness(255)
        XCTAssertEqual(controller.currentBrightness, 255)
    }

    func testSetBrightnessUpdatesBacklightOn() {
        controller.setBrightness(100)
        XCTAssertTrue(controller.backlightOn)

        controller.setBrightness(0)
        XCTAssertFalse(controller.backlightOn)
    }

    func testSetBrightnessSavesBrightness() {
        controller.setBrightness(200)
        // savedBrightness = max(currentBrightness, 1)
        XCTAssertEqual(controller.savedBrightness, 200)
    }

    func testSetBrightnessZeroSavedIsAtLeastOne() {
        controller.setBrightness(0)
        // savedBrightness = max(0, 1) = 1
        XCTAssertEqual(controller.savedBrightness, 1)
    }

    // MARK: - setWarmth clamping

    func testSetWarmthNormal() {
        controller.setWarmth(100)
        XCTAssertEqual(controller.currentWarmth, 100)
    }

    func testSetWarmthClampsAbove255() {
        controller.setWarmth(300)
        XCTAssertEqual(controller.currentWarmth, 255)
    }

    func testSetWarmthClampsBelowZero() {
        controller.setWarmth(-5)
        XCTAssertEqual(controller.currentWarmth, 0)
    }

    func testSetWarmthAtZero() {
        controller.setWarmth(0)
        XCTAssertEqual(controller.currentWarmth, 0)
    }

    func testSetWarmthAt255() {
        controller.setWarmth(255)
        XCTAssertEqual(controller.currentWarmth, 255)
    }

    // MARK: - toggleBacklight

    func testToggleBacklightOff() {
        // Start with backlight on, brightness 128
        controller.currentBrightness = 128
        controller.backlightOn = true

        controller.toggleBacklight()

        XCTAssertFalse(controller.backlightOn)
        XCTAssertEqual(controller.currentBrightness, 0)
        XCTAssertEqual(controller.savedBrightness, 128, "Should save brightness before turning off")
    }

    func testToggleBacklightOnRestoresBrightness() {
        // Set up: backlight on at 200
        controller.currentBrightness = 200
        controller.savedBrightness = 200
        controller.backlightOn = true

        // Toggle off
        controller.toggleBacklight()
        XCTAssertEqual(controller.currentBrightness, 0)
        XCTAssertFalse(controller.backlightOn)

        // Toggle back on
        controller.toggleBacklight()
        XCTAssertTrue(controller.backlightOn)
        XCTAssertEqual(controller.currentBrightness, 200, "Should restore saved brightness")
    }

    func testToggleBacklightSavesAtLeastOne() {
        // Edge case: brightness is 0 but backlight is "on"
        controller.currentBrightness = 0
        controller.backlightOn = true

        controller.toggleBacklight()
        // savedBrightness = max(0, 1) = 1
        XCTAssertEqual(controller.savedBrightness, 1)
    }

    func testDoubleToggleIsRoundTrip() {
        controller.currentBrightness = 150
        controller.savedBrightness = 150
        controller.backlightOn = true

        controller.toggleBacklight()  // off
        controller.toggleBacklight()  // on

        XCTAssertTrue(controller.backlightOn)
        XCTAssertEqual(controller.currentBrightness, 150)
    }

    // MARK: - Callbacks

    func testBrightnessCallbackFires() {
        var received: Int?
        controller.onBrightnessChanged = { received = $0 }

        controller.setBrightness(42)
        XCTAssertEqual(received, 42)
    }

    func testWarmthCallbackFires() {
        var received: Int?
        controller.onWarmthChanged = { received = $0 }

        controller.setWarmth(77)
        XCTAssertEqual(received, 77)
    }

    func testBacklightCallbackFires() {
        var received: Bool?
        controller.onBacklightChanged = { received = $0 }

        controller.setBrightness(0)
        XCTAssertEqual(received, false)

        controller.setBrightness(100)
        XCTAssertEqual(received, true)
    }

    func testToggleBacklightCallbackFires() {
        var brightnessValues: [Int] = []
        var backlightValues: [Bool] = []
        controller.onBrightnessChanged = { brightnessValues.append($0) }
        controller.onBacklightChanged = { backlightValues.append($0) }

        controller.toggleBacklight()  // off
        controller.toggleBacklight()  // on

        XCTAssertEqual(brightnessValues.count, 2)
        XCTAssertEqual(backlightValues, [false, true])
    }
}
