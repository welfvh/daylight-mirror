// MirrorEngine.swift — Core orchestrator for Daylight Mirror.
//
// Coordinates: virtual display creation, screen capture, TCP/WS/HTTP servers,
// display controls (brightness, warmth, backlight), ADB bridge, USB device
// monitoring, and the control socket for CLI integration.
//
// Used by both the CLI (`daylight-mirror`) and the menu bar app (`DaylightMirror`).
// All heavy lifting is zero-GPU: vImage SIMD greyscale + LZ4 delta compression.
//
// Individual components live in their own files (see Configuration.swift,
// ADBBridge.swift, ScreenCapture.swift, etc.). This file contains only the
// MirrorEngine class that wires them together.

import Foundation
import AppKit

public class MirrorEngine: ObservableObject {
    // RELEASE: Bump this BEFORE creating a GitHub release. Also upload both
    // DaylightMirror-vX.Y.dmg (versioned) and DaylightMirror.dmg (stable name for Gumroad link)
    // to the release. Update Homebrew cask in welfvh/homebrew-tap with new version + sha256.
    public static let appVersion = "1.3.0"

    @Published public var status: MirrorStatus = .idle
    @Published public var fps: Double = 0
    @Published public var bandwidth: Double = 0
    @Published public var brightness: Int = 128
    @Published public var warmth: Int = 128
    @Published public var backlightOn: Bool = true
    @Published public var adbConnected: Bool = false
    @Published public var apkInstallStatus: String = ""  // Empty = idle, "Installing..." = in progress, "Installed" = done, or error
    @Published public var clientCount: Int = 0
    @Published public var totalFrames: Int = 0
    @Published public var frameSizeKB: Int = 0
    @Published public var greyMs: Double = 0      // Greyscale + sharpen time per frame
    @Published public var compressMs: Double = 0   // LZ4 delta compress time per frame
    @Published public var jitterMs: Double = 0     // SCStream delivery jitter (deviation from expected interval)
    @Published public var rttMs: Double = 0        // Round-trip latency (Mac send → Android ACK)
    @Published public var rttP95Ms: Double = 0     // 95th percentile RTT
    @Published public var skippedFrames: Int = 0  // Frames skipped due to Android backpressure
    @Published public var sharpenAmount: Double = 1.0 {
        didSet {
            capture?.sharpenAmount = sharpenAmount
            UserDefaults.standard.set(sharpenAmount, forKey: "sharpenAmount")
        }
    }
    @Published public var contrastAmount: Double = 1.0 {
        didSet {
            capture?.contrastAmount = contrastAmount
            UserDefaults.standard.set(contrastAmount, forKey: "contrastAmount")
        }
    }
    @Published public var fontSmoothingDisabled: Bool = false
    @Published public var deviceDetected: Bool = false
    @Published public var updateVersion: String? = nil
    @Published public var updateURL: String? = nil
    @Published public var resolution: DisplayResolution {
        didSet { UserDefaults.standard.set(resolution.rawValue, forKey: "resolution") }
    }

    private var displayManager: VirtualDisplayManager?
    private var tcpServer: TCPServer?
    private var wsServer: WebSocketServer?
    private var httpServer: HTTPServer?
    private var inputServer: InputServer?
    private var inputCommandServer: InputCommandServer?
    private var capture: ScreenCapture?
    private var displayController: DisplayController?
    private var compositorPacer: CompositorPacer?
    private var controlSocket: ControlSocket?
    private var usbMonitor: USBDeviceMonitor?
    private var savedMacBrightness: Float?   // Mac brightness before auto-dim
    /// When true, auto-start/stop mirroring based on USB device state.
    @Published public var autoMirrorEnabled: Bool = true {
        didSet { UserDefaults.standard.set(autoMirrorEnabled, forKey: "autoMirrorEnabled") }
    }

    public init() {
        let saved = UserDefaults.standard.string(forKey: "resolution") ?? ""
        self.resolution = DisplayResolution(rawValue: saved) ?? .sharp
        let savedSharpen = UserDefaults.standard.double(forKey: "sharpenAmount")
        self.sharpenAmount = savedSharpen > 0 ? savedSharpen : 1.0
        let savedContrast = UserDefaults.standard.double(forKey: "contrastAmount")
        self.contrastAmount = savedContrast > 0 ? savedContrast : 1.0
        if UserDefaults.standard.object(forKey: "autoMirrorEnabled") != nil {
            self.autoMirrorEnabled = UserDefaults.standard.bool(forKey: "autoMirrorEnabled")
        }
        NSLog("[MirrorEngine] init, resolution: %@, sharpen: %.1f, contrast: %.1f",
              resolution.rawValue, sharpenAmount, contrastAmount)

        // Control socket — always listening so CLI can send START/STOP/etc.
        // Started after init completes (self is fully initialized).
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let sock = ControlSocket(engine: self)
            sock.start()
            self.controlSocket = sock
        }

        // USB device monitoring — auto-detect DC-1 connect/disconnect
        // Ensure adb server is running before polling, otherwise `adb devices` returns nothing.
        DispatchQueue.global(qos: .utility).async {
            if ADBBridge.isAvailable() { ADBBridge.ensureServerRunning() }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let monitor = USBDeviceMonitor()
                monitor.onDeviceConnected = { [weak self] in
                    guard let self = self else { return }
                    self.deviceDetected = true
                    if self.autoMirrorEnabled && self.status == .idle {
                        NSLog("[USB] Device connected — auto-starting mirror")
                        Task { @MainActor in await self.start() }
                    } else if self.autoMirrorEnabled && self.status == .waitingForDevice {
                        NSLog("[USB] Device connected — starting mirror")
                        self.status = .idle
                        Task { @MainActor in await self.start() }
                    } else if self.autoMirrorEnabled && self.status == .stopping {
                        NSLog("[USB] Device connected while stopping — will restart after teardown")
                        Task { @MainActor in
                            while self.status == .stopping {
                                try? await Task.sleep(for: .milliseconds(200))
                            }
                            if self.status == .idle {
                                NSLog("[USB] Teardown complete — restarting mirror")
                                await self.start()
                            }
                        }
                    } else if self.status == .running {
                        NSLog("[USB] Device reconnected — re-establishing tunnel")
                        self.reconnect()
                    }
                }
                monitor.onDeviceDisconnected = { [weak self] in
                    guard let self = self else { return }
                    self.deviceDetected = false
                    if self.autoMirrorEnabled && self.status == .running {
                        NSLog("[USB] Device disconnected — stopping mirror")
                        self.stop()
                        self.status = .waitingForDevice
                    }
                }
                monitor.start()
                self.usbMonitor = monitor
                self.deviceDetected = monitor.isDeviceConnected
            }
        }

        // Check for updates in the background
        Task { @MainActor in
            if let release = await UpdateChecker.check(currentVersion: Self.appVersion) {
                self.updateVersion = release.version
                self.updateURL = release.url
                NSLog("[Update] New version available: %@", release.version)
            }
        }
    }

    private var globalKeyMonitor: Any?
    private var globalSystemMonitor: Any?

    /// Call once after init, from the main thread, to register Ctrl+F8 global hotkey.
    public func setupGlobalShortcut() {
        NSLog("[Global] Setting up Ctrl+F8 hotkey via NSEvent monitors...")

        // Monitor regular key events (Ctrl+F8 = keyCode 100)
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains(.control) && event.keyCode == 100 {
                NSLog("[Global] Ctrl+F8 pressed — toggling")
                self?.toggleMirror()
            }
        }

        // Monitor system-defined events (F8 as media key = play/pause)
        globalSystemMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            guard event.subtype.rawValue == 8 else { return }
            let data1 = event.data1
            let keyCode = (data1 & 0xFFFF0000) >> 16
            let keyDown = ((data1 & 0xFF00) >> 8) == 0xA
            let ctrl = event.modifierFlags.contains(.control)
            if keyDown && ctrl && keyCode == 16 {
                NSLog("[Global] Ctrl+F8 media key — toggling")
                self?.toggleMirror()
            }
        }

        NSLog("[Global] Ctrl+F8 hotkey registered (key=%@, system=%@)",
              globalKeyMonitor != nil ? "yes" : "no",
              globalSystemMonitor != nil ? "yes" : "no")
    }

    /// Toggle mirror on/off from keyboard shortcut
    private func toggleMirror() {
        DispatchQueue.main.async {
            if self.status == .running {
                self.stop()
            } else if self.status == .idle || self.status == .waitingForDevice {
                Task { @MainActor in
                    await self.start()
                }
            }
        }
    }

    // MARK: - Permission & Device Checks

    /// Check if Screen Recording permission is granted.
    public static func hasScreenRecordingPermission() -> Bool {
        return CGPreflightScreenCaptureAccess()
    }

    /// Prompt the user for Screen Recording permission (opens System Settings).
    public static func requestScreenRecordingPermission() {
        CGRequestScreenCaptureAccess()
    }

    /// Check if Accessibility permission is granted (needed for global keyboard shortcuts).
    public static func hasAccessibilityPermission() -> Bool {
        return AXIsProcessTrusted()
    }

    /// Prompt for Accessibility permission with the system dialog.
    public static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// Check if adb is installed.
    public static func hasADB() -> Bool {
        return ADBBridge.isAvailable()
    }

    /// Check if a Daylight device is connected via USB.
    public static func hasDevice() -> Bool {
        return ADBBridge.connectedDevice() != nil
    }

    /// Whether the onboarding setup has been completed.
    public static var setupCompleted: Bool {
        get { UserDefaults.standard.bool(forKey: "setupCompleted") }
        set { UserDefaults.standard.set(newValue, forKey: "setupCompleted") }
    }

    /// Whether all required permissions are granted.
    public static var allPermissionsGranted: Bool {
        hasScreenRecordingPermission() && hasAccessibilityPermission()
    }

    @MainActor
    public func start() async {
        guard status == .idle || status != .starting else { return }

        // Disable font smoothing for cleaner greyscale rendering on e-ink
        if fontSmoothingDisabled {
            setFontSmoothing(enabled: false)
        }

        // Check Screen Recording permission before attempting capture
        if !Self.hasScreenRecordingPermission() {
            Self.requestScreenRecordingPermission()
            status = .error("Grant Screen Recording permission in System Settings, then retry")
            return
        }

        status = .starting

        // 1. Virtual display at selected resolution
        let w = resolution.width
        let h = resolution.height
        displayManager = VirtualDisplayManager(width: w, height: h, hiDPI: resolution.isHiDPI)
        try? await Task.sleep(for: .seconds(1))

        // 3. Mirroring
        displayManager?.mirrorBuiltInDisplay()
        try? await Task.sleep(for: .seconds(1))

        // 3b. Compositor pacer — forces display compositor to deliver frames at TARGET_FPS.
        // Dirty-pixel window must be on the VIRTUAL display's screen to trigger its compositor.
        let pacer = CompositorPacer(targetDisplayID: displayManager!.displayID)
        pacer.start()
        compositorPacer = pacer

        // 4. Servers
        do {
            let tcp = try TCPServer(port: TCP_PORT)
            tcp.frameWidth = UInt16(w)
            tcp.frameHeight = UInt16(h)
            tcp.onClientCountChanged = { [weak self] count in
                DispatchQueue.main.async {
                    let wasConnected = (self?.clientCount ?? 0) > 0
                    self?.clientCount = count

                    // Auto-dim Mac when Daylight connects, restore when it disconnects
                    if count > 0 && !wasConnected {
                        if let current = MacBrightness.get() {
                            self?.savedMacBrightness = current
                            MacBrightness.set(0)
                            print("[Mac] Auto-dimmed (was \(current))")
                        }
                    } else if count == 0 && wasConnected {
                        if let saved = self?.savedMacBrightness {
                            MacBrightness.set(saved)
                            self?.savedMacBrightness = nil
                            print("[Mac] Brightness restored to \(saved)")
                        }
                    }
                }
            }
            tcp.onLatencyStats = { [weak self] stats in
                DispatchQueue.main.async {
                    self?.rttMs = stats.rttAvgMs
                    self?.rttP95Ms = stats.rttP95Ms
                }
            }
            tcp.start()
            tcpServer = tcp

            let ws = try WebSocketServer(port: WS_PORT)
            ws.start()
            wsServer = ws

            let http = try HTTPServer(port: HTTP_PORT, width: w, height: h)
            http.start()
            httpServer = http

            // Reverse input path (Daylight -> Mac).
            let input = try InputServer(port: INPUT_PORT, targetDisplayID: displayManager!.displayID)
            input.start()
            inputServer = input

            let inputCmd = try InputCommandServer(port: INPUT_CMD_PORT)
            inputCmd.start()
            inputCommandServer = inputCmd
        } catch {
            status = .error("Server failed: \(error.localizedDescription)")
            displayManager = nil
            return
        }

        // 4b. ADB tunnel + auto-install APK + launch (AFTER server is listening)
        if ADBBridge.isAvailable() {
            ADBBridge.ensureServerRunning()
            await establishADBConnection()
        } else {
            adbConnected = false
            NSLog("[ADB] No adb binary — skipping device setup")
        }

        // 5. Capture
        let cap = ScreenCapture(
            tcpServer: tcpServer!, wsServer: wsServer!,
            targetDisplayID: displayManager!.displayID,
            width: Int(w), height: Int(h)
        )
        cap.sharpenAmount = sharpenAmount
        cap.contrastAmount = contrastAmount
        cap.onStats = { [weak self] fps, bw, frameKB, total, grey, compress, jitter, skipped in
            DispatchQueue.main.async {
                self?.fps = fps
                self?.bandwidth = bw
                self?.totalFrames = total
                self?.frameSizeKB = frameKB
                self?.greyMs = grey
                self?.compressMs = compress
                self?.jitterMs = jitter
                self?.skippedFrames = skipped
            }
        }
        capture = cap

        do {
            try await cap.start()
        } catch let error as ScreenCaptureError {
            status = .error(error.localizedDescription)
            compositorPacer?.stop(); compositorPacer = nil
            tcpServer?.stop(); wsServer?.stop(); httpServer?.stop(); inputServer?.stop(); inputCommandServer?.stop()
            tcpServer = nil; wsServer = nil; httpServer = nil; inputServer = nil; inputCommandServer = nil
            displayManager = nil
            return
        } catch {
            status = .error("Capture failed: \(error.localizedDescription)")
            compositorPacer?.stop(); compositorPacer = nil
            tcpServer?.stop(); wsServer?.stop(); httpServer?.stop(); inputServer?.stop(); inputCommandServer?.stop()
            tcpServer = nil; wsServer = nil; httpServer = nil; inputServer = nil; inputCommandServer = nil
            displayManager = nil
            return
        }

        // 6. Display controller (keyboard shortcuts)
        let dc = DisplayController(tcpServer: tcpServer!)
        dc.onBrightnessChanged = { [weak self] val in
            DispatchQueue.main.async { self?.brightness = val }
        }
        dc.onWarmthChanged = { [weak self] val in
            DispatchQueue.main.async { self?.warmth = val }
        }
        dc.onBacklightChanged = { [weak self] on in
            DispatchQueue.main.async { self?.backlightOn = on }
        }
        dc.start()
        displayController = dc

        // Sync initial values
        brightness = dc.currentBrightness
        warmth = dc.currentWarmth
        backlightOn = dc.backlightOn

        status = .running

        print("---")
        print("Native TCP:  tcp://localhost:\(TCP_PORT)")
        print("Input TCP:   tcp://localhost:\(INPUT_PORT)")
        print("Input CMD:   tcp://localhost:\(INPUT_CMD_PORT)")
        print("WS fallback: ws://localhost:\(WS_PORT)")
        print("HTML page:   http://localhost:\(HTTP_PORT)")
        print("Virtual display \(displayManager!.displayID): \(w)x\(h)")
    }

    /// Retry ADB device detection, tunnel setup, APK install, and app launch.
    /// Retries up to 3 times with 1-second delays to handle adb server startup lag.
    @MainActor
    private func establishADBConnection() async {
        let maxAttempts = 3

        for attempt in 1...maxAttempts {
            guard let device = ADBBridge.connectedDevice() else {
                if attempt < maxAttempts {
                    NSLog("[ADB] No device found (attempt %d/%d), retrying...", attempt, maxAttempts)
                    apkInstallStatus = "Looking for device... (\(attempt)/\(maxAttempts))"
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
                NSLog("[ADB] No device found after %d attempts", maxAttempts)
                apkInstallStatus = "No device found — connect via USB and tap Reconnect"
                adbConnected = false
                return
            }

            NSLog("[ADB] Device found: %@ (attempt %d)", device, attempt)

            // Auto-install bundled APK if the companion app isn't on the device yet
            if !ADBBridge.isAppInstalled() {
                apkInstallStatus = "Installing companion app..."
                NSLog("[ADB] Companion app not found, installing bundled APK...")
                if let error = ADBBridge.installBundledAPK() {
                    apkInstallStatus = "APK install failed: \(error)"
                    NSLog("[ADB] APK install error: %@", error)
                } else {
                    apkInstallStatus = "Installed"
                    NSLog("[ADB] Companion app installed")
                }
            }

            let streamTunnelOK = ADBBridge.setupReverseTunnel(port: TCP_PORT)
            let inputTunnelOK = ADBBridge.setupReverseTunnel(port: INPUT_PORT)
            let inputCmdTunnelOK = ADBBridge.setupReverseTunnel(port: INPUT_CMD_PORT)
            if streamTunnelOK && inputTunnelOK && inputCmdTunnelOK {
                NSLog("[ADB] Reverse tunnel tcp:%d established", TCP_PORT)
                NSLog("[ADB] Reverse tunnel tcp:%d established", INPUT_PORT)
                NSLog("[ADB] Reverse tunnel tcp:%d established", INPUT_CMD_PORT)
                ADBBridge.launchApp(forceRestart: true)
                adbConnected = true
                apkInstallStatus = ""
                return
            }

            if attempt < maxAttempts {
                NSLog("[ADB] Tunnel failed (attempt %d/%d), retrying...", attempt, maxAttempts)
                apkInstallStatus = "Tunnel failed, retrying... (\(attempt)/\(maxAttempts))"
                try? await Task.sleep(for: .seconds(1))
            }
        }

        NSLog("[ADB] WARNING: Reverse tunnel failed after %d attempts", maxAttempts)
        apkInstallStatus = "Tunnel failed — tap Reconnect to retry"
        adbConnected = false
    }

    public func stop() {
        guard status == .running || status == .waitingForDevice else { return }
        if status == .waitingForDevice { status = .idle; return }
        DispatchQueue.main.async { self.status = .stopping }

        // Restore Mac brightness before tearing down
        if let saved = savedMacBrightness {
            MacBrightness.set(saved)
            savedMacBrightness = nil
            print("[Mac] Brightness restored to \(saved)")
        }

        Task {
            // Stop in reverse order (control socket stays alive — it's engine-lifetime)
            displayController?.stop()
            displayController = nil

            compositorPacer?.stop()
            compositorPacer = nil

            await capture?.stop()
            capture = nil

            tcpServer?.stop()
            wsServer?.stop()
            httpServer?.stop()
            inputServer?.stop()
            inputCommandServer?.stop()
            tcpServer = nil
            wsServer = nil
            httpServer = nil
            inputServer = nil
            inputCommandServer = nil

            // Virtual display disappears on dealloc, mirroring reverts
            displayManager = nil

            if adbConnected && self.deviceDetected {
                ADBBridge.removeReverseTunnel(port: TCP_PORT)
                ADBBridge.removeReverseTunnel(port: INPUT_PORT)
                ADBBridge.removeReverseTunnel(port: INPUT_CMD_PORT)
            }

            // Restore font smoothing when mirror stops
            if self.fontSmoothingDisabled {
                self.setFontSmoothing(enabled: true)
            }

            await MainActor.run {
                status = .idle
                fps = 0
                bandwidth = 0
                clientCount = 0
                totalFrames = 0
                adbConnected = false
            }

            print("Mirror stopped")
        }
    }

    /// Lightweight reconnect: re-establish ADB tunnel and relaunch the Android app
    /// without tearing down the virtual display, capture, or servers.
    public func reconnect() {
        guard status == .running else { return }
        guard clientCount == 0 || !adbConnected else {
            print("[MirrorEngine] Reconnect skipped — client already connected")
            return
        }
        print("[MirrorEngine] Reconnecting ADB...")
        Task.detached {
            let streamTunnelOK = ADBBridge.setupReverseTunnel(port: TCP_PORT)
            let inputTunnelOK = ADBBridge.setupReverseTunnel(port: INPUT_PORT)
            let inputCmdTunnelOK = ADBBridge.setupReverseTunnel(port: INPUT_CMD_PORT)
            if streamTunnelOK && inputTunnelOK && inputCmdTunnelOK {
                NSLog("[ADB] Reverse tunnel re-established")
                ADBBridge.launchApp()
                await MainActor.run { self.adbConnected = true }
            } else {
                NSLog("[ADB] WARNING: Reverse tunnel failed on reconnect")
                await MainActor.run { self.adbConnected = false }
            }
        }
    }

    /// Quadratic curve with widened landing zone at the low end.
    ///   pos 0.00–0.03 → off (0)
    ///   pos 0.03–0.08 → minimum (1)  — ~5% of slider travel
    ///   pos 0.08–1.00 → quadratic ramp (2–255)
    public static func brightnessFromSliderPos(_ pos: Double) -> Int {
        if pos < 0.03 { return 0 }
        let raw = pos * pos * 255.0
        if raw < 1.5 { return 1 }
        return min(255, Int(raw))
    }

    public func setBrightness(_ value: Int) {
        displayController?.setBrightness(value)
        brightness = max(0, min(255, value))
        backlightOn = brightness > 0
    }

    public func setWarmth(_ value: Int) {
        displayController?.setWarmth(value)
        warmth = max(0, min(255, value))
    }

    public func toggleBacklight() {
        displayController?.toggleBacklight()
        if let dc = displayController {
            brightness = dc.currentBrightness
            backlightOn = dc.backlightOn
        }
    }

    /// Disable macOS font smoothing (subpixel AA). Dramatically improves text clarity
    /// on greyscale displays like the Daylight DC-1. Restored when mirror stops.
    public func setFontSmoothing(enabled: Bool) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        if enabled {
            task.arguments = ["delete", "-g", "AppleFontSmoothing"]
        } else {
            task.arguments = ["write", "-g", "AppleFontSmoothing", "-int", "0"]
        }
        try? task.run()
        task.waitUntilExit()
        fontSmoothingDisabled = !enabled
        print("[Engine] Font smoothing \(enabled ? "enabled" : "disabled")")
    }
}
