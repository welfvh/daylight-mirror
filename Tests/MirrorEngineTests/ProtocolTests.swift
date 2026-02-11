import XCTest
@testable import MirrorEngine

final class ProtocolTests: XCTestCase {

    // MARK: - Magic bytes

    func testMagicFrameBytes() {
        XCTAssertEqual(MAGIC_FRAME, [0xDA, 0x7E])
    }

    func testMagicCmdBytes() {
        XCTAssertEqual(MAGIC_CMD, [0xDA, 0x7F])
    }

    func testMagicFrameAndCmdDiffer() {
        XCTAssertNotEqual(MAGIC_FRAME, MAGIC_CMD,
                          "Frame and command magic must be distinguishable")
    }

    // MARK: - Flags

    func testFlagKeyframe() {
        XCTAssertEqual(FLAG_KEYFRAME, 0x01)
    }

    // MARK: - Command IDs

    func testCmdBrightness() {
        XCTAssertEqual(CMD_BRIGHTNESS, 0x01)
    }

    func testCmdWarmth() {
        XCTAssertEqual(CMD_WARMTH, 0x02)
    }

    func testCmdBacklightToggle() {
        XCTAssertEqual(CMD_BACKLIGHT_TOGGLE, 0x03)
    }

    func testCmdResolution() {
        XCTAssertEqual(CMD_RESOLUTION, 0x04)
    }

    func testCommandIDsAreUnique() {
        let ids: [UInt8] = [CMD_BRIGHTNESS, CMD_WARMTH, CMD_BACKLIGHT_TOGGLE, CMD_RESOLUTION]
        XCTAssertEqual(ids.count, Set(ids).count, "All command IDs must be unique")
    }

    // MARK: - Frame header layout

    func testFrameHeaderIs7Bytes() {
        // Build a frame header the same way TCPServer.broadcast does:
        // [magic:2][flags:1][len:4 LE]
        var header = Data(capacity: 7)
        header.append(contentsOf: MAGIC_FRAME)
        header.append(FLAG_KEYFRAME)
        var len = UInt32(1024).littleEndian
        header.append(Data(bytes: &len, count: 4))

        XCTAssertEqual(header.count, 7)
    }

    func testFrameHeaderMagicPrefix() {
        var header = Data()
        header.append(contentsOf: MAGIC_FRAME)
        header.append(0x00) // flags
        var len = UInt32(0).littleEndian
        header.append(Data(bytes: &len, count: 4))

        XCTAssertEqual(header[0], 0xDA)
        XCTAssertEqual(header[1], 0x7E)
    }

    func testFrameHeaderFlagsPosition() {
        var header = Data()
        header.append(contentsOf: MAGIC_FRAME)
        header.append(FLAG_KEYFRAME)
        var len = UInt32(0).littleEndian
        header.append(Data(bytes: &len, count: 4))

        XCTAssertEqual(header[2], FLAG_KEYFRAME, "Flags byte is at offset 2")
    }

    func testFrameHeaderLengthIsLittleEndian() {
        var header = Data()
        header.append(contentsOf: MAGIC_FRAME)
        header.append(0x00)
        let payloadSize: UInt32 = 0x01020304
        var len = payloadSize.littleEndian
        header.append(Data(bytes: &len, count: 4))

        // Little-endian: least significant byte first
        XCTAssertEqual(header[3], 0x04)
        XCTAssertEqual(header[4], 0x03)
        XCTAssertEqual(header[5], 0x02)
        XCTAssertEqual(header[6], 0x01)
    }

    func testNonKeyframeHasFlagZero() {
        var header = Data()
        header.append(contentsOf: MAGIC_FRAME)
        let isKeyframe = false
        header.append(isKeyframe ? FLAG_KEYFRAME : 0)
        var len = UInt32(100).littleEndian
        header.append(Data(bytes: &len, count: 4))

        XCTAssertEqual(header[2], 0x00)
    }

    // MARK: - Command packet layout

    func testCommandPacketIs4Bytes() {
        // Build a command packet the same way TCPServer.sendCommand does:
        // [magic:2][cmd:1][value:1]
        var packet = Data(capacity: 4)
        packet.append(contentsOf: MAGIC_CMD)
        packet.append(CMD_BRIGHTNESS)
        packet.append(128)

        XCTAssertEqual(packet.count, 4)
    }

    func testCommandPacketMagicPrefix() {
        var packet = Data()
        packet.append(contentsOf: MAGIC_CMD)
        packet.append(CMD_WARMTH)
        packet.append(64)

        XCTAssertEqual(packet[0], 0xDA)
        XCTAssertEqual(packet[1], 0x7F)
    }

    func testCommandPacketCmdPosition() {
        var packet = Data()
        packet.append(contentsOf: MAGIC_CMD)
        packet.append(CMD_BRIGHTNESS)
        packet.append(200)

        XCTAssertEqual(packet[2], CMD_BRIGHTNESS, "Command byte is at offset 2")
    }

    func testCommandPacketValuePosition() {
        var packet = Data()
        packet.append(contentsOf: MAGIC_CMD)
        packet.append(CMD_WARMTH)
        packet.append(42)

        XCTAssertEqual(packet[3], 42, "Value byte is at offset 3")
    }

    // MARK: - Step constants

    func testBrightnessStepIsPositive() {
        XCTAssertGreaterThan(BRIGHTNESS_STEP, 0)
    }

    func testWarmthStepIsPositive() {
        XCTAssertGreaterThan(WARMTH_STEP, 0)
    }
}
