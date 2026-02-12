// USBDeviceMonitor.swift — USB device detection via ADB polling.
//
// Polls `adb devices` every 2 seconds to detect USB connect/disconnect.
// Calls onDeviceConnected/onDeviceDisconnected on the main queue when state changes.
// Used by MirrorEngine for auto-start/stop based on DC-1 presence.

import Foundation

class USBDeviceMonitor {
    private var timer: DispatchSourceTimer?
    private var wasConnected = false
    private var disconnectCount = 0
    var onDeviceConnected: (() -> Void)?
    var onDeviceDisconnected: (() -> Void)?

    /// Number of consecutive "not connected" polls before firing a disconnect event.
    /// At 2s polling interval, 3 misses = 6 seconds of confirmed absence.
    /// Prevents transient adb hiccups (concurrent commands, server restarts) from
    /// triggering false disconnect → reconnect → relaunch cycles.
    private let disconnectThreshold = 3

    func start() {
        guard ADBBridge.isAvailable() else {
            print("[USB] No adb available — device monitoring disabled")
            return
        }
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now(), repeating: .seconds(2))
        t.setEventHandler { [weak self] in
            guard let self = self else { return }
            let connected = ADBBridge.connectedDevice() != nil
            if connected {
                self.disconnectCount = 0
                if !self.wasConnected {
                    self.wasConnected = true
                    print("[USB] Device connected")
                    DispatchQueue.main.async { self.onDeviceConnected?() }
                }
            } else if self.wasConnected {
                self.disconnectCount += 1
                if self.disconnectCount >= self.disconnectThreshold {
                    self.wasConnected = false
                    self.disconnectCount = 0
                    print("[USB] Device disconnected (confirmed after \(self.disconnectThreshold) polls)")
                    DispatchQueue.main.async { self.onDeviceDisconnected?() }
                }
            }
        }
        t.resume()
        timer = t
        print("[USB] Device monitoring started (polling adb every 2s)")
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    var isDeviceConnected: Bool { wasConnected }
}
