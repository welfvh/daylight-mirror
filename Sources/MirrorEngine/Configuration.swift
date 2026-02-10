// Configuration.swift — Global constants, resolution presets, and status enum.

import Foundation
import CoreGraphics

// MARK: - Configuration

let TCP_PORT: UInt16 = 8888
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

// Resolution presets (all 4:3, matching Daylight DC-1's native 1600x1200 panel).
// Cozy uses HiDPI (2x): macOS renders at 800x600 logical points with 1600x1200 backing
// pixels — big UI, full native sharpness. Other presets are non-HiDPI 1:1 pixel modes.
public enum DisplayResolution: String, CaseIterable, Identifiable {
    case cozy        = "800x600"    // HiDPI 2x: 800x600pt → 1600x1200px — large UI, native sharpness
    case comfortable = "1024x768"   // Larger UI, easy on the eyes
    case balanced    = "1280x960"   // Good balance of size and sharpness
    case sharp       = "1600x1200"  // Maximum sharpness, smaller UI (1:1 native)

    public var id: String { rawValue }
    /// Pixel dimensions captured by SCStream and sent to the Daylight.
    public var width: UInt { switch self { case .cozy: 1600; case .comfortable: 1024; case .balanced: 1280; case .sharp: 1600 } }
    public var height: UInt { switch self { case .cozy: 1200; case .comfortable: 768; case .balanced: 960; case .sharp: 1200 } }
    public var label: String { switch self { case .cozy: "Cozy"; case .comfortable: "Comfortable"; case .balanced: "Balanced"; case .sharp: "Sharp" } }
    /// Whether the virtual display uses HiDPI (2x) scaling.
    public var isHiDPI: Bool { switch self { case .cozy: true; default: false } }
}

// Protocol constants
let MAGIC_FRAME: [UInt8] = [0xDA, 0x7E]
let MAGIC_CMD: [UInt8] = [0xDA, 0x7F]
let FLAG_KEYFRAME: UInt8 = 0x01
let CMD_BRIGHTNESS: UInt8 = 0x01
let CMD_WARMTH: UInt8 = 0x02
let CMD_BACKLIGHT_TOGGLE: UInt8 = 0x03
let CMD_RESOLUTION: UInt8 = 0x04

let BRIGHTNESS_STEP: Int = 15
let WARMTH_STEP: Int = 20

// MARK: - Status

public enum MirrorStatus: Equatable {
    case idle
    case starting
    case running
    case stopping
    case error(String)
}
