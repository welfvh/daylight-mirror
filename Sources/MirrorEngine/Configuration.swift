// Configuration.swift — Constants and resolution presets for Daylight Mirror.
//
// Protocol constants, resolution presets (landscape + portrait), and shared
// configuration values used across the engine.

import Foundation

let TCP_PORT: UInt16 = 8888
let TCP_PORT_SECONDARY: UInt16 = 8889  // Second device gets its own TCP server
let WS_PORT: UInt16 = 8890
let HTTP_PORT: UInt16 = 8891
let TARGET_FPS: Int = 60  // DC-1 panel supports up to 120Hz; 60fps viable with GL shader + NEON opts
let JPEG_QUALITY: CGFloat = 0.8
let KEYFRAME_INTERVAL: Int = 60

// Image processing for reflective paper displays (greyscale).
// macOS font smoothing produces subpixel-antialiased text that looks fuzzy when
// converted to greyscale. Two independent post-processing knobs counteract this:
//   sharpenAmount (0.0-3.0): spatial sharpening via Laplacian kernel (default 1.5)
//   contrastAmount (1.0-1.8): linear contrast stretch around midpoint (default 1.2)

// Resolution presets for the Daylight DC-1 (1600x1200 native, 4:3 landscape / 3:4 portrait).
// Cozy variants use HiDPI (2x): macOS renders at half logical points with full backing
// pixels — big UI, full native sharpness. Other presets are non-HiDPI 1:1 pixel modes.
//
// Future: auto-detect panel resolution from connected devices and generate presets
// dynamically, rather than hardcoding per-device families.
public enum DisplayResolution: String, CaseIterable, Identifiable {
    // DC-1 Landscape (4:3)
    case cozy        = "800x600"    // HiDPI 2x: 800x600pt → 1600x1200px — large UI, native sharpness
    case comfortable = "1024x768"   // Larger UI, easy on the eyes
    case balanced    = "1280x960"   // Good middle ground
    case sharp       = "1600x1200"  // Maximum sharpness, 1:1 native pixel mapping
    // DC-1 Portrait (3:4)
    case portraitCozy        = "600x800"    // HiDPI 2x: 600x800pt → 1200x1600px — large UI, native sharpness
    case portraitComfortable = "768x1024"   // Larger UI, easy on the eyes
    case portraitBalanced    = "960x1280"   // Good middle ground
    case portraitSharp       = "1200x1600"  // Maximum sharpness, 1:1 native pixel mapping

    public var id: String { rawValue }
    /// Pixel dimensions captured and sent to the device.
    public var width: UInt {
        switch self {
        case .cozy: 1600; case .comfortable: 1024; case .balanced: 1280; case .sharp: 1600
        case .portraitCozy: 1200; case .portraitComfortable: 768; case .portraitBalanced: 960; case .portraitSharp: 1200
        }
    }
    public var height: UInt {
        switch self {
        case .cozy: 1200; case .comfortable: 768; case .balanced: 960; case .sharp: 1200
        case .portraitCozy: 1600; case .portraitComfortable: 1024; case .portraitBalanced: 1280; case .portraitSharp: 1600
        }
    }
    public var label: String {
        switch self {
        case .cozy: "Cozy"; case .comfortable: "Comfortable"; case .balanced: "Balanced"; case .sharp: "Sharp"
        case .portraitCozy: "Portrait Cozy"; case .portraitComfortable: "Portrait Comfortable"
        case .portraitBalanced: "Portrait Balanced"; case .portraitSharp: "Portrait Sharp"
        }
    }
    /// Whether the virtual display uses HiDPI (2x) scaling.
    public var isHiDPI: Bool { switch self { case .cozy, .portraitCozy: true; default: false } }
    /// Whether this is a portrait (vertical) orientation preset.
    public var isPortrait: Bool {
        switch self {
        case .portraitCozy, .portraitComfortable, .portraitBalanced, .portraitSharp: true
        default: false
        }
    }
}

/// Device families for connected Android devices.
/// DC-1 is the primary target; other devices get a generic label and use
/// the same resolution as the DC-1 (future: auto-detect native panel size).
public enum DeviceFamily: String {
    case daylightDC1 = "Daylight DC-1"
    case other       = "External Display"
}

/// Display mode: mirror the built-in display, or extend as a second screen.
public enum DisplayMode: String, CaseIterable, Identifiable {
    case mirror   = "mirror"    // Virtual display mirrors the Mac's built-in display
    case extended = "extended"  // Virtual display is an independent second screen

    public var id: String { rawValue }
    public var label: String {
        switch self { case .mirror: "Mirror"; case .extended: "Extend" }
    }
}

// Protocol constants
let MAGIC_FRAME: [UInt8] = [0xDA, 0x7E]
let MAGIC_CMD: [UInt8] = [0xDA, 0x7F]
let MAGIC_ACK: [UInt8] = [0xDA, 0x7A]  // ACK from Android → Mac for RTT measurement
let FLAG_KEYFRAME: UInt8 = 0x01
let CMD_BRIGHTNESS: UInt8 = 0x01
let CMD_WARMTH: UInt8 = 0x02
let CMD_BACKLIGHT_TOGGLE: UInt8 = 0x03
let CMD_RESOLUTION: UInt8 = 0x04

// Frame header: [DA 7E] [flags:1] [seq:4 LE] [len:4 LE] [payload] = 11 bytes
// ACK packet:   [DA 7A] [seq:4 LE] = 6 bytes (sent by Android after rendering)
let FRAME_HEADER_SIZE = 11

let BRIGHTNESS_STEP: Int = 15
let WARMTH_STEP: Int = 20

// MARK: - Display Profiles

/// Bundles sharpen, contrast, and gamma into named presets for the DC-1 reflective panel.
/// "Crisp Paper" is the optimized default. "Balanced" is gentler. "Custom" unlocks sliders.
public enum DisplayProfile: String, CaseIterable, Identifiable {
    case crispPaper = "Crisp Paper"
    case balanced  = "Balanced"
    case custom    = "Custom"

    public var id: String { rawValue }

    public var sharpen: Double {
        switch self { case .crispPaper: 1.5; case .balanced: 0.5; case .custom: 0 }
    }
    public var contrast: Double {
        switch self { case .crispPaper: 1.2; case .balanced: 1.0; case .custom: 1.0 }
    }
    public var gamma: Double {
        switch self { case .crispPaper: 1.2; case .balanced: 1.0; case .custom: 1.0 }
    }

    /// Migration: map old "E-ink Crisp" raw value to the renamed case.
    public init?(rawValue: String) {
        switch rawValue {
        case "Crisp Paper": self = .crispPaper
        case "E-ink Crisp": self = .crispPaper  // v1.6 → v1.7 migration
        case "Balanced": self = .balanced
        case "Custom": self = .custom
        default: return nil
        }
    }
}

// MARK: - Status

public enum MirrorStatus: Equatable {
    case idle
    case waitingForDevice
    case starting
    case running
    case stopping
    case error(String)
}
