// MirrorEngine.swift — Core orchestrator for Daylight Mirror.
//
// Coordinates multiple DeviceSessions (one per connected Android device), shared
// servers (WS, HTTP), display controls, USB monitoring, and the control socket.
//
// Used by both the CLI (`daylight-mirror`) and the menu bar app (`DaylightMirror`).
// All heavy lifting is zero-GPU: vImage SIMD greyscale + LZ4 delta compression.

import Foundation
import AppKit

public class MirrorEngine: ObservableObject {
    // RELEASE: Bump this BEFORE creating a GitHub release. Also upload both
    // DaylightMirror-vX.Y.dmg (versioned) and DaylightMirror.dmg (stable name for Gumroad link)
    // to the release. Update Homebrew cask in welfvh/homebrew-tap with new version + sha256.
    public static let appVersion = "1.6.1"

    @Published public var status: MirrorStatus = .idle
    @Published public var fps: Double = 0
    @Published public var bandwidth: Double = 0
    @Published public var brightness: Int = 128
    @Published public var warmth: Int = 128
    @Published public var backlightOn: Bool = true
    @Published public var adbConnected: Bool = false
    @Published public var apkInstallStatus: String = ""
    @Published public var clientCount: Int = 0
    @Published public var totalFrames: Int = 0
    @Published public var frameSizeKB: Int = 0
    @Published public var greyMs: Double = 0
    @Published public var compressMs: Double = 0
    @Published public var jitterMs: Double = 0
    @Published public var rttMs: Double = 0
    @Published public var rttP95Ms: Double = 0
    @Published public var skippedFrames: Int = 0
    @Published public var sharpenAmount: Double = 1.0 {
        didSet {
            for session in sessions { session.updateSharpen(sharpenAmount) }
            UserDefaults.standard.set(sharpenAmount, forKey: "sharpenAmount")
        }
    }
    @Published public var contrastAmount: Double = 1.0 {
        didSet {
            for session in sessions { session.updateContrast(contrastAmount) }
            UserDefaults.standard.set(contrastAmount, forKey: "contrastAmount")
        }
    }
    @Published public var fontSmoothingDisabled: Bool = false
    @Published public var deviceDetected: Bool = false
    @Published public var updateVersion: String? = nil
    @Published public var updateURL: String? = nil
    /// Resolution preference for DC-1 devices.
    @Published public var resolution: DisplayResolution {
        didSet { UserDefaults.standard.set(resolution.rawValue, forKey: "resolution") }
    }
    /// Resolution preference for Boox Palma devices.
    @Published public var booxResolution: DisplayResolution {
        didSet { UserDefaults.standard.set(booxResolution.rawValue, forKey: "booxResolution") }
    }
    @Published public var displayMode: DisplayMode {
        didSet { UserDefaults.standard.set(displayMode.rawValue, forKey: "displayMode") }
    }

    /// Active device sessions — one per connected Android device.
    /// Published so the menu bar UI can show per-device info.
    @Published public private(set) var sessions: [DeviceSession] = []
    private var wsServer: WebSocketServer?
    private var httpServer: HTTPServer?
    private var displayController: DisplayController?
    private var controlSocket: ControlSocket?
    private var usbMonitor: USBDeviceMonitor?
    private var savedMacBrightness: Float?
    /// When true, auto-start/stop mirroring based on USB device state.
    @Published public var autoMirrorEnabled: Bool = true {
        didSet { UserDefaults.standard.set(autoMirrorEnabled, forKey: "autoMirrorEnabled") }
    }
    /// When true, auto-dim the Mac's built-in display when a Daylight client connects.
    @Published public var autoDimMac: Bool = true {
        didSet { UserDefaults.standard.set(autoDimMac, forKey: "autoDimMac") }
    }

    public init() {
        let saved = UserDefaults.standard.string(forKey: "resolution") ?? ""
        self.resolution = DisplayResolution(rawValue: saved) ?? .sharp
        let savedBoox = UserDefaults.standard.string(forKey: "booxResolution") ?? ""
        self.booxResolution = DisplayResolution(rawValue: savedBoox) ?? .booxCozy
        let savedMode = UserDefaults.standard.string(forKey: "displayMode") ?? ""
        self.displayMode = DisplayMode(rawValue: savedMode) ?? .mirror
        let savedSharpen = UserDefaults.standard.double(forKey: "sharpenAmount")
        self.sharpenAmount = savedSharpen > 0 ? savedSharpen : 1.0
        let savedContrast = UserDefaults.standard.double(forKey: "contrastAmount")
        self.contrastAmount = savedContrast > 0 ? savedContrast : 1.0
        if UserDefaults.standard.object(forKey: "autoMirrorEnabled") != nil {
            self.autoMirrorEnabled = UserDefaults.standard.bool(forKey: "autoMirrorEnabled")
        }
        if UserDefaults.standard.object(forKey: "autoDimMac") != nil {
            self.autoDimMac = UserDefaults.standard.bool(forKey: "autoDimMac")
        }
        NSLog("[MirrorEngine] init, dc1: %@, boox: %@, mode: %@, sharpen: %.1f",
              resolution.rawValue, booxResolution.rawValue, displayMode.rawValue, sharpenAmount)

        // Control socket — always listening so CLI can send START/STOP/etc.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let sock = ControlSocket(engine: self)
            sock.start()
            self.controlSocket = sock
        }

        // USB device monitoring — auto-detect connect/disconnect
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
                        NSLog("[USB] Device reconnected — re-establishing tunnels")
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

        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains(.control) && event.keyCode == 100 {
                NSLog("[Global] Ctrl+F8 pressed — toggling")
                self?.toggleMirror()
            }
        }

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

    private func toggleMirror() {
        DispatchQueue.main.async {
            if self.status == .running {
                self.stop()
            } else if self.status == .idle || self.status == .waitingForDevice {
                Task { @MainActor in await self.start() }
            }
        }
    }

    // MARK: - Permission & Device Checks

    public static func hasScreenRecordingPermission() -> Bool { CGPreflightScreenCaptureAccess() }
    public static func requestScreenRecordingPermission() { CGRequestScreenCaptureAccess() }
    public static func hasAccessibilityPermission() -> Bool { AXIsProcessTrusted() }
    public static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
    public static func hasADB() -> Bool { ADBBridge.isAvailable() }
    public static func hasDevice() -> Bool { ADBBridge.connectedDevice() != nil }
    public static var setupCompleted: Bool {
        get { UserDefaults.standard.bool(forKey: "setupCompleted") }
        set { UserDefaults.standard.set(newValue, forKey: "setupCompleted") }
    }
    public static var allPermissionsGranted: Bool {
        hasScreenRecordingPermission() && hasAccessibilityPermission()
    }

    // MARK: - Start / Stop

    @MainActor
    public func start() async {
        guard status == .idle || status != .starting else { return }

        if fontSmoothingDisabled { setFontSmoothing(enabled: false) }

        if !Self.hasScreenRecordingPermission() {
            Self.requestScreenRecordingPermission()
            status = .error("Grant Screen Recording permission in System Settings, then retry")
            return
        }

        status = .starting

        // Shared servers (WS for browser preview, HTTP for fallback page)
        do {
            let ws = try WebSocketServer(port: WS_PORT)
            ws.start()
            wsServer = ws

            let http = try HTTPServer(port: HTTP_PORT, width: resolution.width, height: resolution.height)
            http.start()
            httpServer = http
        } catch {
            status = .error("Server failed: \(error.localizedDescription)")
            return
        }

        // Detect connected devices and create a session for each
        if ADBBridge.isAvailable() {
            ADBBridge.ensureServerRunning()
        }

        let devices = ADBBridge.isAvailable() ? ADBBridge.connectedDevices() : []
        if devices.isEmpty {
            NSLog("[Engine] No devices found — creating default session (DC-1 resolution)")
            let pseudoDevice = ConnectedDevice(serial: "none", model: "unknown")
            let session = DeviceSession(
                port: TCP_PORT, resolution: resolution,
                displayMode: displayMode, device: pseudoDevice
            )
            await startSession(session, wsServer: wsServer)
        } else {
            // Sort: DC-1 first (gets primary port 8888), then other devices.
            // This ensures stable port assignment regardless of USB enumeration order.
            let sorted = devices.sorted { a, _ in a.deviceFamily == .daylightDC1 }
            var port = TCP_PORT
            for (index, device) in sorted.enumerated() {
                let res = resolutionForDevice(device)
                // Only the first device gets the user's display mode (mirror/extended).
                // Additional devices are always extended — macOS only supports mirroring
                // the built-in display to one virtual display at a time.
                let mode: DisplayMode = (index == 0) ? displayMode : .extended
                let session = DeviceSession(
                    port: port, resolution: res,
                    displayMode: mode, device: device
                )
                // Primary session (port 8888) gets the WS server for browser preview
                let ws: WebSocketServer? = (port == TCP_PORT) ? wsServer : nil
                await startSession(session, wsServer: ws)
                port += 1
                // Stagger virtual display creation — macOS needs time to register each one
                if sorted.count > 1 {
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }

        // Display controller — attach to DC-1 session's TCP server for brightness/warmth
        if let dc1Session = sessions.first(where: { $0.device.deviceFamily == .daylightDC1 }),
           let tcp = dc1Session.tcpServer {
            let serial = dc1Session.device.serial != "none" ? dc1Session.device.serial : nil
            let dc = DisplayController(tcpServer: tcp, deviceSerial: serial)
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
            brightness = dc.currentBrightness
            warmth = dc.currentWarmth
            backlightOn = dc.backlightOn
        }

        adbConnected = sessions.contains { $0.adbConnected }
        apkInstallStatus = ""
        status = .running

        let sessionSummary = sessions.map { "\($0.device.model)@\($0.port):\($0.resolution.rawValue)" }
        print("---")
        print("Sessions: \(sessionSummary.joined(separator: ", "))")
        print("WS: ws://localhost:\(WS_PORT) | HTTP: http://localhost:\(HTTP_PORT)")
    }

    /// Start a single DeviceSession and wire up its stats callbacks.
    @MainActor
    private func startSession(_ session: DeviceSession, wsServer: WebSocketServer?) async {
        // Wire stats back to engine's @Published properties (aggregated across sessions)
        session.onStatsChanged = { [weak self] in
            DispatchQueue.main.async { self?.aggregateStats() }
        }
        session.onClientCountChanged = { [weak self] _ in
            DispatchQueue.main.async { self?.aggregateClientCount() }
        }
        session.onLatencyStats = { [weak self] stats in
            DispatchQueue.main.async {
                self?.rttMs = stats.rttAvgMs
                self?.rttP95Ms = stats.rttP95Ms
            }
        }

        do {
            try await session.start(
                wsServer: wsServer,
                sharpenAmount: sharpenAmount,
                contrastAmount: contrastAmount
            )
        } catch {
            NSLog("[Engine] Session %@ failed: %@", session.device.serial, error.localizedDescription)
        }

        sessions.append(session)
    }

    /// Pick the right resolution for a detected device based on its family.
    private func resolutionForDevice(_ device: ConnectedDevice) -> DisplayResolution {
        switch device.deviceFamily {
        case .booxPalma: return booxResolution
        case .daylightDC1: return resolution
        }
    }

    /// Aggregate stats from all sessions for the UI.
    private func aggregateStats() {
        // Show primary session's stats (first session, typically DC-1)
        guard let primary = sessions.first else { return }
        fps = primary.fps
        bandwidth = sessions.reduce(0) { $0 + $1.bandwidth }
        totalFrames = sessions.reduce(0) { $0 + $1.totalFrames }
        frameSizeKB = primary.frameSizeKB
        greyMs = primary.greyMs
        compressMs = primary.compressMs
        jitterMs = primary.jitterMs
        skippedFrames = sessions.reduce(0) { $0 + $1.skippedFrames }
    }

    /// Aggregate client count from all sessions.
    private func aggregateClientCount() {
        let total = sessions.reduce(0) { $0 + $1.clientCount }
        let wasConnected = clientCount > 0
        clientCount = total

        // Auto-dim Mac when any client connects
        if autoDimMac {
            if total > 0 && !wasConnected {
                if let current = MacBrightness.get() {
                    savedMacBrightness = current
                    MacBrightness.set(0)
                    print("[Mac] Auto-dimmed (was \(current))")
                }
            } else if total == 0 && wasConnected {
                if let saved = savedMacBrightness {
                    MacBrightness.set(saved)
                    savedMacBrightness = nil
                    print("[Mac] Brightness restored to \(saved)")
                }
            }
        }
    }

    public func stop() {
        guard status == .running || status == .waitingForDevice else { return }
        if status == .waitingForDevice { status = .idle; return }
        DispatchQueue.main.async { self.status = .stopping }

        if let saved = savedMacBrightness {
            MacBrightness.set(saved)
            savedMacBrightness = nil
            print("[Mac] Brightness restored to \(saved)")
        }

        Task {
            displayController?.stop()
            displayController = nil

            for session in sessions {
                await session.stop()
            }
            sessions.removeAll()

            wsServer?.stop()
            httpServer?.stop()
            wsServer = nil
            httpServer = nil

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

    /// Lightweight reconnect: re-establish ADB tunnels and relaunch apps
    /// without tearing down virtual displays, captures, or servers.
    public func reconnect() {
        guard status == .running else { return }
        print("[MirrorEngine] Reconnecting ADB...")
        Task.detached {
            for session in self.sessions {
                guard !session.adbConnected else { continue }
                let tunnelOK = ADBBridge.setupReverseTunnel(
                    serial: session.device.serial,
                    devicePort: TCP_PORT,
                    hostPort: session.port
                )
                if tunnelOK {
                    ADBBridge.launchApp(serial: session.device.serial)
                    NSLog("[ADB] Reconnected %@", session.device.serial)
                }
            }
            await MainActor.run {
                self.adbConnected = self.sessions.contains { $0.adbConnected }
            }
        }
    }

    // MARK: - Display Controls

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
