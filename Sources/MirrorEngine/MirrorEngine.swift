// MirrorEngine.swift — Core orchestrator for Daylight Mirror.
//
// Coordinates multiple DeviceSessions (one per connected Android device), shared
// servers (WS, HTTP), display controls, USB monitoring, and the control socket.
//
// Used by both the CLI (`daylight-mirror`) and the menu bar app (`DaylightMirror`).
// All heavy lifting is zero-GPU: vImage SIMD greyscale + LZ4 delta compression.

import Foundation
import AppKit
import IOKit.pwr_mgt

public class MirrorEngine: ObservableObject {
    // RELEASE: Bump this BEFORE creating a GitHub release. Also upload both
    // DaylightMirror-vX.Y.dmg (versioned) and DaylightMirror.dmg (stable name for Gumroad link)
    // to the release. Update Homebrew cask in welfvh/homebrew-tap with new version + sha256.
    public static let appVersion = "1.7.0"

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
    /// When true, slider changes are being applied by a profile — don't switch to Custom.
    private var applyingProfile = false
    @Published public var sharpenAmount: Double = 1.0 {
        didSet {
            for session in sessions { session.updateSharpen(sharpenAmount) }
            UserDefaults.standard.set(sharpenAmount, forKey: "sharpenAmount")
            if !applyingProfile && displayProfile != .custom { displayProfile = .custom }
        }
    }
    @Published public var contrastAmount: Double = 1.0 {
        didSet {
            for session in sessions { session.updateContrast(contrastAmount) }
            UserDefaults.standard.set(contrastAmount, forKey: "contrastAmount")
            if !applyingProfile && displayProfile != .custom { displayProfile = .custom }
        }
    }
    /// Gamma correction for reflective paper displays (~1.0-1.5 vs 2.2 for transmissive LCDs).
    /// Values > 1.0 brighten midtones, improving definition on the DC-1's reflective panel.
    @Published public var gammaAmount: Double = 1.2 {
        didSet {
            for session in sessions { session.updateGamma(gammaAmount) }
            UserDefaults.standard.set(gammaAmount, forKey: "gammaAmount")
            if !applyingProfile && displayProfile != .custom { displayProfile = .custom }
        }
    }
    /// Display profile bundles sharpen+contrast+gamma. Selecting a preset applies its values;
    /// manually adjusting any slider switches to "Custom".
    @Published public var displayProfile: DisplayProfile = .crispPaper {
        didSet {
            UserDefaults.standard.set(displayProfile.rawValue, forKey: "displayProfile")
            if displayProfile != .custom {
                applyingProfile = true
                sharpenAmount = displayProfile.sharpen
                contrastAmount = displayProfile.contrast
                gammaAmount = displayProfile.gamma
                applyingProfile = false
            }
        }
    }
    @Published public var fontSmoothingDisabled: Bool = false
    @Published public var deviceDetected: Bool = false
    @Published public var updateVersion: String? = nil
    @Published public var updateURL: String? = nil
    /// Resolution preference for DC-1 devices.
    @Published public var resolution: DisplayResolution {
        didSet {
            UserDefaults.standard.set(resolution.rawValue, forKey: "resolution")
            NSLog("[MirrorEngine] resolution changed: %@ → %@", oldValue.rawValue, resolution.rawValue)
        }
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
    /// When true, prevent system sleep while mirroring (enables clamshell/lid-closed use).
    /// Creates an IOPMAssertion that keeps the Mac awake even with the lid closed.
    @Published public var clamshellModeEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(clamshellModeEnabled, forKey: "clamshellModeEnabled")
            if clamshellModeEnabled && status == .running {
                createSleepAssertion()
            } else if !clamshellModeEnabled {
                releaseSleepAssertion()
            }
        }
    }
    /// IOPMAssertion IDs for preventing system + display sleep. 0 = no active assertion.
    private var sleepAssertionID: IOPMAssertionID = 0
    private var displayAssertionID: IOPMAssertionID = 0
    /// Whether sleep assertions are currently held.
    private var hasSleepAssertion: Bool = false

    public init() {
        // Load saved resolution — validate it's a known preset, fall back to Sharp.
        let saved = UserDefaults.standard.string(forKey: "resolution") ?? ""
        let loadedRes = DisplayResolution(rawValue: saved) ?? .sharp
        self.resolution = loadedRes
        let savedMode = UserDefaults.standard.string(forKey: "displayMode") ?? ""
        self.displayMode = DisplayMode(rawValue: savedMode) ?? .mirror
        // Migration: v1.7 introduced new defaults (sharpen 1.5, contrast 1.2, gamma 1.2).
        // Old installs have sharpen=1.0, contrast=1.0, gamma=0.0 saved — override those.
        let migrated = UserDefaults.standard.bool(forKey: "v1.7_defaults_migrated")
        if !migrated {
            UserDefaults.standard.removeObject(forKey: "sharpenAmount")
            UserDefaults.standard.removeObject(forKey: "contrastAmount")
            UserDefaults.standard.removeObject(forKey: "gammaAmount")
            UserDefaults.standard.removeObject(forKey: "displayProfile")
            UserDefaults.standard.set(true, forKey: "v1.7_defaults_migrated")
        }
        let savedSharpen = UserDefaults.standard.double(forKey: "sharpenAmount")
        self.sharpenAmount = savedSharpen > 0 ? savedSharpen : 1.5
        let savedContrast = UserDefaults.standard.double(forKey: "contrastAmount")
        self.contrastAmount = savedContrast > 0 ? savedContrast : 1.2
        let savedGamma = UserDefaults.standard.double(forKey: "gammaAmount")
        self.gammaAmount = savedGamma > 0 ? savedGamma : 1.2
        let savedProfile = UserDefaults.standard.string(forKey: "displayProfile") ?? ""
        self.displayProfile = DisplayProfile(rawValue: savedProfile) ?? .crispPaper
        if UserDefaults.standard.object(forKey: "autoMirrorEnabled") != nil {
            self.autoMirrorEnabled = UserDefaults.standard.bool(forKey: "autoMirrorEnabled")
        }
        if UserDefaults.standard.object(forKey: "autoDimMac") != nil {
            self.autoDimMac = UserDefaults.standard.bool(forKey: "autoDimMac")
        }
        if UserDefaults.standard.object(forKey: "clamshellModeEnabled") != nil {
            self.clamshellModeEnabled = UserDefaults.standard.bool(forKey: "clamshellModeEnabled")
        }
        NSLog("[MirrorEngine] init, resolution: %@, mode: %@, sharpen: %.1f",
              resolution.rawValue, displayMode.rawValue, sharpenAmount)

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
            for (_, device) in sorted.enumerated() {
                let res = resolutionForDevice(device)
                // Primary device uses user's display mode preference.
                // Additional devices always get their own extended display.
                let mode: DisplayMode = (port == TCP_PORT) ? displayMode : .extended
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

        if clamshellModeEnabled { createSleepAssertion() }

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
                contrastAmount: contrastAmount,
                gammaAmount: gammaAmount
            )
        } catch {
            NSLog("[Engine] Session %@ failed: %@", session.device.serial, error.localizedDescription)
        }

        sessions.append(session)
    }

    /// Pick the right resolution for a detected device based on its family.
    /// Resolution for a given device. Currently all devices use the same resolution.
    /// Future: auto-detect panel size and generate appropriate presets.
    private func resolutionForDevice(_ device: ConnectedDevice) -> DisplayResolution {
        return resolution
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
                    NSLog("[Mac] Auto-dimmed (was %.2f)", current)
                } else {
                    NSLog("[Mac] Auto-dim failed: could not read current brightness")
                }
            } else if total == 0 && wasConnected {
                if let saved = savedMacBrightness {
                    MacBrightness.set(saved)
                    savedMacBrightness = nil
                    NSLog("[Mac] Brightness restored to %.2f", saved)
                }
            }
        }
    }

    public func stop() {
        guard status == .running || status == .waitingForDevice else { return }
        if status == .waitingForDevice { status = .idle; return }
        DispatchQueue.main.async { self.status = .stopping }

        releaseSleepAssertion()

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

    // MARK: - Sleep Prevention (Clamshell Mode)

    /// Create power assertions that prevent both system sleep and display sleep.
    /// Both are needed for clamshell mode: system sleep keeps the Mac running,
    /// display sleep keeps the virtual display pipeline active.
    private func createSleepAssertion() {
        guard !hasSleepAssertion else { return }
        let reason = "Daylight Mirror is actively mirroring to an external display" as CFString

        let sysResult = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &sleepAssertionID
        )
        let dispResult = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &displayAssertionID
        )

        if sysResult == kIOReturnSuccess && dispResult == kIOReturnSuccess {
            hasSleepAssertion = true
            NSLog("[Clamshell] Sleep assertions created (system: %d, display: %d)",
                  sleepAssertionID, displayAssertionID)
        } else {
            NSLog("[Clamshell] Failed to create sleep assertions: sys=%d, disp=%d",
                  sysResult, dispResult)
        }
    }

    /// Release sleep assertions, allowing normal sleep behavior.
    private func releaseSleepAssertion() {
        guard hasSleepAssertion else { return }
        IOPMAssertionRelease(sleepAssertionID)
        IOPMAssertionRelease(displayAssertionID)
        hasSleepAssertion = false
        sleepAssertionID = 0
        displayAssertionID = 0
        NSLog("[Clamshell] Sleep assertions released")
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
