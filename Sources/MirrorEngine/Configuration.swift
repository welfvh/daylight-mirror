// Configuration.swift — Constants and resolution presets for Daylight Mirror.
//
// Protocol constants, resolution presets (landscape + portrait), and shared
// configuration values used across the engine.

import Foundation

let TCP_PORT: UInt16 = 8888
let INPUT_PORT: UInt16 = 8892
let INPUT_CMD_PORT: UInt16 = 8893
let WS_PORT: UInt16 = 8890
let HTTP_PORT: UInt16 = 8891
let TARGET_FPS: Int = 30
let JPEG_QUALITY: CGFloat = 0.8
let KEYFRAME_INTERVAL: Int = 30

// Image processing for e-ink/greyscale displays.
// macOS font smoothing produces subpixel-antialiased text that looks fuzzy when
// converted to greyscale. Two independent post-processing knobs counteract this:
//   sharpenAmount (0.0-3.0): spatial sharpening via Laplacian kernel
//   contrastAmount (1.0-2.0): linear contrast stretch around midpoint

// Resolution presets matching Daylight DC-1's native 1600x1200 panel.
// Landscape presets are 4:3. Portrait presets are 3:4 (1200x1600 native).
// Cozy variants use HiDPI (2x): macOS renders at half logical points with full backing
// pixels — big UI, full native sharpness. Other presets are non-HiDPI 1:1 pixel modes.
public enum DisplayResolution: String, CaseIterable, Identifiable {
    // Landscape (4:3)
    case cozy        = "800x600"    // HiDPI 2x: 800x600pt → 1600x1200px — large UI, native sharpness
    case comfortable = "1024x768"   // Larger UI, easy on the eyes
    case balanced    = "1280x960"   // Good balance of size and sharpness
    case sharp       = "1600x1200"  // Maximum sharpness, smaller UI (1:1 native)
    // Portrait (3:4)
    case portraitCozy     = "600x800"    // HiDPI 2x: 600x800pt → 1200x1600px — large UI, native sharpness
    case portraitBalanced = "960x1280"   // Good balance of size and sharpness
    case portraitSharp    = "1200x1600"  // Maximum sharpness, smaller UI (1:1 native)

    public var id: String { rawValue }
    /// Pixel dimensions captured by SCStream and sent to the Daylight.
    public var width: UInt {
        switch self {
        case .cozy: 1600; case .comfortable: 1024; case .balanced: 1280; case .sharp: 1600
        case .portraitCozy: 1200; case .portraitBalanced: 960; case .portraitSharp: 1200
        }
    }
    public var height: UInt {
        switch self {
        case .cozy: 1200; case .comfortable: 768; case .balanced: 960; case .sharp: 1200
        case .portraitCozy: 1600; case .portraitBalanced: 1280; case .portraitSharp: 1600
        }
    }
    public var label: String {
        switch self {
        case .cozy: "Cozy"; case .comfortable: "Comfortable"; case .balanced: "Balanced"; case .sharp: "Sharp"
        case .portraitCozy: "Portrait Cozy"; case .portraitBalanced: "Portrait Balanced"; case .portraitSharp: "Portrait Sharp"
        }
    }
    /// Whether the virtual display uses HiDPI (2x) scaling.
    public var isHiDPI: Bool { switch self { case .cozy, .portraitCozy: true; default: false } }
    /// Whether this is a portrait (vertical) orientation preset.
    public var isPortrait: Bool {
        switch self {
        case .portraitCozy, .portraitBalanced, .portraitSharp: true
        default: false
        }
    }
}

// Protocol constants
let MAGIC_FRAME: [UInt8] = [0xDA, 0x7E]
let MAGIC_CMD: [UInt8] = [0xDA, 0x7F]
let MAGIC_ACK: [UInt8] = [0xDA, 0x7A]  // ACK from Android → Mac for RTT measurement
let MAGIC_INPUT: [UInt8] = [0xDA, 0x70] // Input packet Android -> Mac
let FLAG_KEYFRAME: UInt8 = 0x01
let CMD_BRIGHTNESS: UInt8 = 0x01
let CMD_WARMTH: UInt8 = 0x02
let CMD_BACKLIGHT_TOGGLE: UInt8 = 0x03
let CMD_RESOLUTION: UInt8 = 0x04

let INPUT_TOUCH_DOWN: UInt8 = 0x01
let INPUT_TOUCH_MOVE: UInt8 = 0x02
let INPUT_TOUCH_UP: UInt8 = 0x03
let INPUT_SCROLL: UInt8 = 0x04

// Frame header: [DA 7E] [flags:1] [seq:4 LE] [len:4 LE] [payload] = 11 bytes
// ACK packet:   [DA 7A] [seq:4 LE] = 6 bytes (sent by Android after rendering)
let FRAME_HEADER_SIZE = 11
// Input packet: [DA 70] [type:1] [x:4 f32 LE] [y:4 f32 LE] [dx:4 f32 LE] [dy:4 f32 LE] [pointer:4 u32 LE]
let INPUT_PACKET_SIZE = 23

let BRIGHTNESS_STEP: Int = 15
let WARMTH_STEP: Int = 20

// MARK: - Status

public enum MirrorStatus: Equatable {
    case idle
    case waitingForDevice
    case starting
    case running
    case stopping
    case error(String)
}
