// MacBrightness.swift — Mac built-in display brightness control via IOKit.

import Foundation
import IOKit.graphics

// MARK: - Mac Brightness Control

/// Controls the Mac's built-in display brightness via IOKit.
/// Used to auto-dim the Mac when the Daylight is connected (no point lighting both screens).
struct MacBrightness {
    static func get() -> Float? {
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

    static func set(_ value: Float) {
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
