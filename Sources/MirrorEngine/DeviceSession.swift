// DeviceSession.swift — Per-device streaming pipeline for Daylight Mirror.
//
// Bundles everything needed to stream to one Android device: virtual display,
// screen capture, TCP server, and compositor pacer. MirrorEngine creates one
// DeviceSession per connected device, each at the device's native resolution.
//
// Each session runs its own TCP server on a separate port. The ADB reverse
// tunnel maps the device's localhost:8888 to the session's host port, so the
// same Android APK works on all devices without modification.

import Foundation
import AppKit

public class DeviceSession: Identifiable {
    public var id: String { device.serial }
    public let port: UInt16
    public let resolution: DisplayResolution
    public let displayMode: DisplayMode
    public let device: ConnectedDevice

    private(set) var displayManager: VirtualDisplayManager?
    private(set) var tcpServer: TCPServer?
    private(set) var capture: ScreenCapture?
    private(set) var compositorPacer: CompositorPacer?
    public private(set) var adbConnected: Bool = false

    // Stats — pushed to MirrorEngine via callbacks
    public var clientCount: Int = 0
    public var fps: Double = 0
    var bandwidth: Double = 0
    var totalFrames: Int = 0
    var frameSizeKB: Int = 0
    var greyMs: Double = 0
    var compressMs: Double = 0
    var jitterMs: Double = 0
    var rttMs: Double = 0
    var rttP95Ms: Double = 0
    var skippedFrames: Int = 0

    var onStatsChanged: (() -> Void)?
    var onClientCountChanged: ((Int) -> Void)?
    var onLatencyStats: ((LatencyStats) -> Void)?

    init(port: UInt16, resolution: DisplayResolution, displayMode: DisplayMode, device: ConnectedDevice) {
        self.port = port
        self.resolution = resolution
        self.displayMode = displayMode
        self.device = device
    }

    /// Start the full pipeline: virtual display → capture → TCP server → ADB tunnel → launch app.
    func start(wsServer: WebSocketServer?, sharpenAmount: Double, contrastAmount: Double, gammaAmount: Double) async throws {
        let w = resolution.width
        let h = resolution.height
        let displayName = device.deviceFamily.rawValue

        // 1. Virtual display
        displayManager = VirtualDisplayManager(width: w, height: h, hiDPI: resolution.isHiDPI, name: displayName)
        try? await Task.sleep(for: .seconds(1))

        // 2. Mirror or extend
        if displayMode == .mirror {
            displayManager?.mirrorBuiltInDisplay()
        } else {
            NSLog("[Session:%@] Extended display mode — second screen", device.serial)
        }
        try? await Task.sleep(for: .seconds(1))

        // 3. Compositor pacer (forces frame delivery at target FPS)
        let pacer = CompositorPacer(targetDisplayID: displayManager!.displayID)
        pacer.start()
        compositorPacer = pacer

        // 4. TCP server on this session's port
        let tcp = try TCPServer(port: port)
        tcp.frameWidth = UInt16(w)
        tcp.frameHeight = UInt16(h)
        tcp.onClientCountChanged = { [weak self] count in
            self?.clientCount = count
            self?.onClientCountChanged?(count)
        }
        tcp.onLatencyStats = { [weak self] stats in
            self?.rttMs = stats.rttAvgMs
            self?.rttP95Ms = stats.rttP95Ms
            self?.onLatencyStats?(stats)
        }
        tcp.start()
        tcpServer = tcp

        // 5. Screen capture targeting this session's virtual display
        let cap = ScreenCapture(
            tcpServer: tcp, wsServer: wsServer,
            targetDisplayID: displayManager!.displayID,
            width: Int(w), height: Int(h)
        )
        cap.sharpenAmount = sharpenAmount
        cap.contrastAmount = contrastAmount
        cap.gammaAmount = gammaAmount
        cap.onStats = { [weak self] fps, bw, frameKB, total, grey, compress, jitter, skipped in
            guard let self else { return }
            self.fps = fps
            self.bandwidth = bw
            self.totalFrames = total
            self.frameSizeKB = frameKB
            self.greyMs = grey
            self.compressMs = compress
            self.jitterMs = jitter
            self.skippedFrames = skipped
            self.onStatsChanged?()
        }
        capture = cap
        try await cap.start()

        // 6. ADB: install APK if needed, set up tunnel, launch app
        await setupADB()

        NSLog("[Session:%@] Started — %@, %dx%d, port %d, %@",
              device.serial, displayName, w, h, port,
              displayMode == .mirror ? "mirror" : "extended")
    }

    /// Set up ADB connection: reset display override, install APK, reverse tunnel, launch app.
    private func setupADB() async {
        let serial = device.serial
        let maxAttempts = 3

        // Reset display size override to get full physical panel resolution.
        // Without this, the DC-1's 1184x1584 override causes scaling artifacts.
        ADBBridge.resetDisplaySizeOverride(serial: serial)

        for attempt in 1...maxAttempts {
            // Auto-install bundled APK if needed
            if !ADBBridge.isAppInstalled(serial: serial) {
                NSLog("[Session:%@] Installing companion app (attempt %d)...", serial, attempt)
                if let error = ADBBridge.installBundledAPK(serial: serial) {
                    NSLog("[Session:%@] APK install error: %@", serial, error)
                }
            }

            // Tunnel: device's localhost:8888 → Mac's session port
            let tunnelOK = ADBBridge.setupReverseTunnel(serial: serial, devicePort: TCP_PORT, hostPort: port)
            if tunnelOK {
                NSLog("[Session:%@] Tunnel established (device:8888 → host:%d)", serial, port)
                ADBBridge.launchApp(serial: serial, forceRestart: true)
                adbConnected = true
                return
            }

            if attempt < maxAttempts {
                NSLog("[Session:%@] Tunnel failed (attempt %d/%d), retrying...", serial, attempt, maxAttempts)
                try? await Task.sleep(for: .seconds(1))
            }
        }

        NSLog("[Session:%@] WARNING: ADB setup failed after %d attempts", serial, maxAttempts)
        adbConnected = false
    }

    func stop() async {
        compositorPacer?.stop()
        compositorPacer = nil

        await capture?.stop()
        capture = nil

        tcpServer?.stop()
        tcpServer = nil

        displayManager = nil

        if adbConnected {
            ADBBridge.removeReverseTunnel(serial: device.serial, devicePort: TCP_PORT)
            adbConnected = false
        }

        NSLog("[Session:%@] Stopped", device.serial)
    }

    /// Update sharpen amount on the live capture stream.
    func updateSharpen(_ amount: Double) {
        capture?.sharpenAmount = amount
    }

    /// Update contrast amount on the live capture stream.
    func updateContrast(_ amount: Double) {
        capture?.contrastAmount = amount
    }

    /// Update gamma correction on the live capture stream.
    func updateGamma(_ amount: Double) {
        capture?.gammaAmount = amount
    }

    /// Restart the screen capture stream after a display sleep/wake cycle.
    /// Used by clamshell mode to recover from DarkWake display pipeline stalls.
    func restartCapture() async {
        await capture?.restartStream()
    }

    /// Break the mirror relationship so the virtual display is standalone.
    func unmirror() {
        displayManager?.unmirrorBuiltInDisplay()
    }

    /// Re-establish the mirror relationship with the built-in display.
    func remirror() {
        displayManager?.mirrorBuiltInDisplay()
    }
}
