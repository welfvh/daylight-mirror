// VirtualDisplayManager.swift — Virtual display creation via CGVirtualDisplay.
//
// Creates a virtual display at the given resolution and mirrors the Mac's built-in
// display to it. Uses CGVirtualDisplay private API (same as BetterDisplay, DeskPad).
// With hiDPI=true, macOS renders at 2x — e.g. 1600x1200 pixels at 800x600 logical points.
// The virtual display disappears when this object is deallocated.
//
// Clamshell support: when the built-in display disappears (lid close), the mirror
// relationship is removed so the virtual display becomes standalone. When the built-in
// reappears (lid open), mirroring is re-established.

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

    /// Set up the mirror relationship: built-in display mirrors our virtual display.
    fileprivate func performMirror() {
        guard let masterID = findBuiltInDisplay() else {
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

    /// Remove the mirror relationship so the virtual display becomes standalone.
    /// Called when the built-in display disappears (lid close in clamshell mode).
    fileprivate func unmirror() {
        var configRef: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configRef) == .success, let config = configRef else {
            NSLog("[VirtualDisplay] Failed to begin unmirror configuration")
            return
        }

        // Passing kCGNullDirectDisplay (0) as the master removes the mirror relationship
        guard CGConfigureDisplayMirrorOfDisplay(config, displayID, CGDirectDisplayID(kCGNullDirectDisplay)) == .success else {
            NSLog("[VirtualDisplay] Failed to configure unmirror")
            CGCancelDisplayConfiguration(config)
            return
        }

        guard CGCompleteDisplayConfiguration(config, .forSession) == .success else {
            NSLog("[VirtualDisplay] Failed to complete unmirror configuration")
            return
        }

        NSLog("[VirtualDisplay] Unmirrored — virtual display %d is now standalone", displayID)
    }

    /// Find the built-in display ID, or nil if the lid is closed.
    fileprivate func findBuiltInDisplay() -> CGDirectDisplayID? {
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 32)
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(32, &displayIDs, &displayCount)

        for i in 0..<Int(displayCount) {
            if CGDisplayIsBuiltin(displayIDs[i]) != 0 {
                return displayIDs[i]
            }
        }
        return nil
    }

    /// Listen for display reconfiguration events (lid open/close, external display changes).
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
/// On lid close: un-mirrors so virtual display becomes standalone (primary screen).
/// On lid open: re-mirrors so virtual display shows the built-in display again.
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

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        let builtInAvailable = manager.findBuiltInDisplay() != nil
        if builtInAvailable {
            NSLog("[VirtualDisplay] Built-in display available — re-establishing mirror")
            manager.performMirror()
        } else {
            NSLog("[VirtualDisplay] Built-in display gone (lid closed) — switching to standalone")
            manager.unmirror()
        }
    }
}
