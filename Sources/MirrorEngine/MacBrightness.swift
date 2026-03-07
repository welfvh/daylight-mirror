// MacBrightness.swift — Mac display brightness control.
//
// Controls the Mac's built-in display brightness. Used to auto-dim the Mac
// when the Daylight is connected (no point lighting both screens).
//
// Primary path: DisplayServices private framework (works on Apple Silicon).
// Fallback: IOKit IODisplayGetFloatParameter/IODisplaySetFloatParameter.

import Foundation
import CoreGraphics
import IOKit.graphics

// DisplayServices private framework function types (loaded via dlsym).
// These are the standard brightness control APIs on Apple Silicon Macs.
private typealias DSGetBrightnessFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
private typealias DSSetBrightnessFn = @convention(c) (UInt32, Float) -> Int32

struct MacBrightness {
    // Lazy-loaded DisplayServices symbols
    private static let dsHandle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    }()

    private static let dsGetBrightness: DSGetBrightnessFn? = {
        guard let handle = dsHandle,
              let sym = dlsym(handle, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(sym, to: DSGetBrightnessFn.self)
    }()

    private static let dsSetBrightness: DSSetBrightnessFn? = {
        guard let handle = dsHandle,
              let sym = dlsym(handle, "DisplayServicesSetBrightness") else { return nil }
        return unsafeBitCast(sym, to: DSSetBrightnessFn.self)
    }()

    /// Get the built-in display ID.
    private static func builtInDisplayID() -> CGDirectDisplayID? {
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(16, &displayIDs, &count)
        for i in 0..<Int(count) {
            if CGDisplayIsBuiltin(displayIDs[i]) != 0 {
                return displayIDs[i]
            }
        }
        return nil
    }

    static func get() -> Float? {
        // Try DisplayServices first (Apple Silicon)
        if let getFn = dsGetBrightness, let displayID = builtInDisplayID() {
            var brightness: Float = 0
            if getFn(displayID, &brightness) == 0 {
                return brightness
            }
        }

        // Fallback: IOKit (Intel Macs)
        return getViaIOKit()
    }

    static func set(_ value: Float) {
        // Try DisplayServices first (Apple Silicon)
        if let setFn = dsSetBrightness, let displayID = builtInDisplayID() {
            let result = setFn(displayID, value)
            if result == 0 { return }
            NSLog("[MacBrightness] DisplayServices set failed (%d), trying IOKit", result)
        }

        // Fallback: IOKit (Intel Macs)
        setViaIOKit(value)
    }

    // MARK: - IOKit fallback

    private static func getViaIOKit() -> Float? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
              IOServiceMatching("IODisplayConnect"), &iterator) == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            var brightness: Float = 0
            let err = IODisplayGetFloatParameter(service, 0,
                      kIODisplayBrightnessKey as CFString, &brightness)
            IOObjectRelease(service)
            if err == kIOReturnSuccess { return brightness }
            service = IOIteratorNext(iterator)
        }
        return nil
    }

    private static func setViaIOKit(_ value: Float) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
              IOServiceMatching("IODisplayConnect"), &iterator) == kIOReturnSuccess else { return }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            IODisplaySetFloatParameter(service, 0,
                kIODisplayBrightnessKey as CFString, value)
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
    }
}
