// DisplayController.swift — Keyboard controls for Daylight hardware (brightness, warmth, backlight).

import Foundation
import AppKit

// MARK: - Display Controller (keyboard controls for Daylight hardware)

/// Intercepts Ctrl+function key events for Daylight display control:
///   Ctrl+F1/F2:   Brightness down/up
///   Ctrl+F10:     Toggle backlight on/off
///   Ctrl+F11/F12: Warmth (amber) down/up
class DisplayController {
    let tcpServer: TCPServer
    var currentBrightness: Int = 128
    var currentWarmth: Int = 128
    var backlightOn: Bool = true
    var savedBrightness: Int = 128
    var keyMonitor: Any?
    var systemMonitor: Any?

    var onBrightnessChanged: ((Int) -> Void)?
    var onWarmthChanged: ((Int) -> Void)?
    var onBacklightChanged: ((Bool) -> Void)?

    init(tcpServer: TCPServer) {
        self.tcpServer = tcpServer
    }

    func start() {
        // Query current values from device
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            if let val = ADBBridge.querySystemSetting("screen_brightness") {
                self.currentBrightness = val
                self.savedBrightness = val
                self.onBrightnessChanged?(val)
                print("[Display] Daylight brightness: \(val)/255")
            }
            if let val = ADBBridge.querySystemSetting("screen_brightness_amber_rate") {
                // Effective range is 0-255 (device accepts 0-1023 but caps effect at 255)
                self.currentWarmth = min(val, 255)
                self.onWarmthChanged?(self.currentWarmth)
                print("[Display] Daylight warmth: \(self.currentWarmth)/255")
            }
        }

        // NSEvent monitors for keyboard shortcuts (no TCC code-signing issues)
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.contains(.control), let self = self else { return }
            switch event.keyCode {
            case 122: self.adjustBrightness(by: -BRIGHTNESS_STEP)  // Ctrl+F1
            case 120: self.adjustBrightness(by: BRIGHTNESS_STEP)   // Ctrl+F2
            case 109: self.toggleBacklight()                       // Ctrl+F10
            case 103: self.adjustWarmth(by: -WARMTH_STEP)          // Ctrl+F11
            case 111: self.adjustWarmth(by: WARMTH_STEP)           // Ctrl+F12
            default: break
            }
        }

        systemMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            guard event.subtype.rawValue == 8, let self = self else { return }
            let data1 = event.data1
            let keyCode = (data1 & 0xFFFF0000) >> 16
            let keyDown = ((data1 & 0xFF00) >> 8) == 0xA
            guard keyDown && event.modifierFlags.contains(.control) else { return }
            switch keyCode {
            case 3: self.adjustBrightness(by: -BRIGHTNESS_STEP)  // Ctrl+F1 media
            case 2: self.adjustBrightness(by: BRIGHTNESS_STEP)   // Ctrl+F2 media
            case 7: self.toggleBacklight()                       // Ctrl+F10 media
            case 1: self.adjustWarmth(by: -WARMTH_STEP)          // Ctrl+F11 media
            case 0: self.adjustWarmth(by: WARMTH_STEP)           // Ctrl+F12 media
            default: break
            }
        }

        print("[Display] Ctrl+F1/F2: brightness | Ctrl+F10: backlight toggle | Ctrl+F11/F12: warmth")
    }

    func stop() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let m = systemMonitor { NSEvent.removeMonitor(m); systemMonitor = nil }
    }

    /// Step brightness using the same quadratic curve as the slider.
    /// Steps happen in slider-space (0–1) so they're tiny at low brightness, bigger at high.
    func adjustBrightness(by delta: Int) {
        let pos = sqrt(Double(currentBrightness) / 255.0)
        let step = 0.05 * Double(delta > 0 ? 1 : -1)
        let newPos = max(0, min(1, pos + step))
        currentBrightness = Self.brightnessFromSliderPos(newPos)
        savedBrightness = max(currentBrightness, 1)
        backlightOn = currentBrightness > 0
        tcpServer.sendCommand(CMD_BRIGHTNESS, value: UInt8(currentBrightness))
        onBrightnessChanged?(currentBrightness)
        onBacklightChanged?(backlightOn)
        print("[Display] Brightness -> \(currentBrightness)/255")
    }

    func setBrightness(_ value: Int) {
        currentBrightness = max(0, min(255, value))
        savedBrightness = max(currentBrightness, 1)
        backlightOn = currentBrightness > 0
        tcpServer.sendCommand(CMD_BRIGHTNESS, value: UInt8(currentBrightness))
        onBrightnessChanged?(currentBrightness)
        onBacklightChanged?(backlightOn)
    }

    /// Quadratic curve with widened landing zone at the low end.
    /// Shared with MirrorEngine.brightnessFromSliderPos (public API for the slider).
    static func brightnessFromSliderPos(_ pos: Double) -> Int {
        MirrorEngine.brightnessFromSliderPos(pos)
    }

    func adjustWarmth(by delta: Int) {
        currentWarmth = max(0, min(255, currentWarmth + delta))
        // Warmth goes via adb shell — screen_brightness_amber_rate is a Daylight-protected
        // setting that only the shell user can write, not a regular Android app.
        DispatchQueue.global().async { [warmth = currentWarmth] in
            ADBBridge.setSystemSetting("screen_brightness_amber_rate", value: warmth)
        }
        onWarmthChanged?(currentWarmth)
        print("[Display] Warmth -> \(currentWarmth)/255")
    }

    func setWarmth(_ value: Int) {
        currentWarmth = max(0, min(255, value))
        DispatchQueue.global().async { [warmth = currentWarmth] in
            ADBBridge.setSystemSetting("screen_brightness_amber_rate", value: warmth)
        }
        onWarmthChanged?(currentWarmth)
        print("[Display] Warmth -> \(currentWarmth)/255")
    }

    func toggleBacklight() {
        if backlightOn {
            savedBrightness = max(currentBrightness, 1)
            currentBrightness = 0
            backlightOn = false
            tcpServer.sendCommand(CMD_BRIGHTNESS, value: 0)
            onBrightnessChanged?(0)
            onBacklightChanged?(false)
            print("[Display] Backlight OFF")
        } else {
            currentBrightness = savedBrightness
            backlightOn = true
            tcpServer.sendCommand(CMD_BRIGHTNESS, value: UInt8(currentBrightness))
            onBrightnessChanged?(currentBrightness)
            onBacklightChanged?(true)
            print("[Display] Backlight ON -> \(currentBrightness)/255")
        }
    }
}
