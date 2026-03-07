// VirtualDisplayManager.swift — Virtual display creation via CGVirtualDisplay.
//
// Creates a virtual display at the given resolution and mirrors the Mac's built-in
// display to it. Uses CGVirtualDisplay private API (same as BetterDisplay, DeskPad).
// With hiDPI=true, macOS renders at 2x — e.g. 1600x1200 pixels at 800x600 logical points.
// The virtual display disappears when this object is deallocated.

import Foundation
import CVirtualDisplay

class VirtualDisplayManager {
    let virtualDisplay: CGVirtualDisplay
    let displayID: CGDirectDisplayID
    let width: UInt
    let height: UInt
    /// Whether this display is configured as a mirror of the built-in display.
    fileprivate var isMirroring = false
    /// Callback registered for display reconfiguration events (lid open/close).
    private var reconfigCallbackRegistered = false

    /// Each virtual display needs a unique serial number so macOS treats them as
    /// separate displays. Without this, the second display creation fails (ID 0).
    private static var nextSerial: UInt32 = 1

    init(width: UInt, height: UInt, hiDPI: Bool = false, name: String = "Daylight DC-1") {
        self.width = width
        self.height = height

        let serial = VirtualDisplayManager.nextSerial
        VirtualDisplayManager.nextSerial += 1

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = name
        descriptor.maxPixelsWide = UInt32(width)
        descriptor.maxPixelsHigh = UInt32(height)
        descriptor.sizeInMillimeters = CGSize(
            width: 25.4 * Double(width) / 100.0,
            height: 25.4 * Double(height) / 100.0
        )
        descriptor.productID = 0xDA7E
        descriptor.vendorID = 0xDA7E
        descriptor.serialNum = serial

        virtualDisplay = CGVirtualDisplay(descriptor: descriptor)
        displayID = virtualDisplay.displayID
        print("Virtual display created: ID \(displayID)")

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = hiDPI ? 1 : 0
        settings.modes = [
            CGVirtualDisplayMode(width: width, height: height, refreshRate: 60)
        ]

        guard virtualDisplay.apply(settings) else {
            print("WARNING: Failed to apply virtual display settings")
            return
        }
        let modeLabel = hiDPI ? "HiDPI (\(width/2)x\(height/2)pt @ 2x)" : "non-HiDPI"
        print("Virtual display configured: \(width)x\(height) \(modeLabel) @ 60Hz")
    }

    func mirrorBuiltInDisplay() {
        performMirror()
        isMirroring = true
        registerReconfigCallback()
    }

    /// Actually set up the mirror relationship with the built-in display.
    fileprivate func performMirror() {
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 32)
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(32, &displayIDs, &displayCount)

        var builtInID: CGDirectDisplayID?
        for i in 0..<Int(displayCount) {
            if CGDisplayIsBuiltin(displayIDs[i]) != 0 {
                builtInID = displayIDs[i]
                break
            }
        }

        guard let masterID = builtInID else {
            NSLog("[VirtualDisplay] No built-in display found (lid closed?) — skipping mirror")
            return
        }

        var configRef: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configRef) == .success, let config = configRef else {
            print("WARNING: Failed to begin display configuration")
            return
        }

        guard CGConfigureDisplayMirrorOfDisplay(config, masterID, displayID) == .success else {
            print("WARNING: Failed to configure mirror")
            CGCancelDisplayConfiguration(config)
            return
        }

        guard CGCompleteDisplayConfiguration(config, .forSession) == .success else {
            print("WARNING: Failed to complete mirror configuration")
            return
        }

        print("Mirroring: built-in display \(masterID) -> virtual display \(displayID)")
    }

    /// Listen for display reconfiguration events (lid open/close, external display changes).
    /// Re-establishes the mirror relationship when the built-in display reappears.
    private func registerReconfigCallback() {
        guard !reconfigCallbackRegistered else { return }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback(displayReconfigCallback, selfPtr)
        reconfigCallbackRegistered = true
        NSLog("[VirtualDisplay] Registered display reconfiguration callback")
    }

    /// Unregister the reconfiguration callback to avoid dangling pointers.
    private func unregisterReconfigCallback() {
        guard reconfigCallbackRegistered else { return }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRemoveReconfigurationCallback(displayReconfigCallback, selfPtr)
        reconfigCallbackRegistered = false
    }

    deinit {
        unregisterReconfigCallback()
    }
}

/// Stable C-function-compatible callback for display reconfiguration events.
/// Must be a free function (not a closure) so the same pointer is used for register/remove.
private func displayReconfigCallback(
    _ displayID: CGDirectDisplayID,
    _ flags: CGDisplayChangeSummaryFlags,
    _ userInfo: UnsafeMutableRawPointer?
) {
    guard let userInfo = userInfo else { return }
    let manager = Unmanaged<VirtualDisplayManager>.fromOpaque(userInfo).takeUnretainedValue()
    // Only act on completion of reconfiguration, not the begin phase
    guard !flags.contains(.beginConfigurationFlag) else { return }
    guard manager.isMirroring else { return }
    // Re-establish mirror after a short delay to let macOS settle
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        NSLog("[VirtualDisplay] Display reconfiguration detected — re-establishing mirror")
        manager.performMirror()
    }
}
