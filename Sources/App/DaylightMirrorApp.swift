// DaylightMirrorApp.swift — Menu bar app for Daylight Mirror.
//
// On first launch (or missing permissions), shows a setup wizard window that guides
// the user through granting Screen Recording + Accessibility permissions and connecting
// their Daylight DC-1. Once setup is complete, the app lives entirely in the menu bar.
// Ctrl+F8 toggles mirroring globally.

import SwiftUI
import MirrorEngine

// MARK: - App Delegate

/// Owns the MirrorEngine, manages the setup window, and registers global hotkeys.
class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let engine = MirrorEngine()
    var setupWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[AppDelegate] didFinishLaunching")
        engine.setupGlobalShortcut()

        // Show setup window if first run or permissions missing
        if !MirrorEngine.setupCompleted || !MirrorEngine.allPermissionsGranted {
            showSetupWindow()
        }
    }

    func showSetupWindow() {
        // Temporarily show in dock so the window is visible
        NSApplication.shared.setActivationPolicy(.regular)

        let setupView = SetupView(engine: engine, onComplete: { [weak self] in
            self?.dismissSetupWindow()
        })

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Daylight Mirror"
        window.contentView = NSHostingView(rootView: setupView)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        setupWindow = window
    }

    func dismissSetupWindow() {
        setupWindow?.close()
        setupWindow = nil
        // Back to menu bar only
        NSApplication.shared.setActivationPolicy(.accessory)
        MirrorEngine.setupCompleted = true
    }
}

// MARK: - App Entry Point

@main
struct DaylightMirrorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    init() {
        // Start as accessory (menu bar only) — setup window will switch to regular if needed
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MirrorMenuView(engine: delegate.engine, showSetup: { delegate.showSetupWindow() })
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "display")
                if delegate.engine.status == .running {
                    Circle()
                        .fill(.green)
                        .frame(width: 6, height: 6)
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Setup Wizard

enum SetupStep: Int, CaseIterable {
    case welcome
    case permissions
    case connect
    case ready
}

struct SetupView: View {
    @ObservedObject var engine: MirrorEngine
    let onComplete: () -> Void

    @State private var step: SetupStep = .welcome
    @State private var hasScreenRecording = MirrorEngine.hasScreenRecordingPermission()
    @State private var hasAccessibility = MirrorEngine.hasAccessibilityPermission()
    @State private var hasADB = MirrorEngine.hasADB()
    @State private var hasDevice = false
    @State private var pollTimer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            // Progress dots
            HStack(spacing: 8) {
                ForEach(SetupStep.allCases, id: \.rawValue) { s in
                    Circle()
                        .fill(s.rawValue <= step.rawValue ? Color.primary : Color.secondary.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.top, 20)
            .padding(.bottom, 16)

            // Step content
            Group {
                switch step {
                case .welcome:
                    welcomeStep
                case .permissions:
                    permissionsStep
                case .connect:
                    connectStep
                case .ready:
                    readyStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 480, height: 520)
        .onDisappear { pollTimer?.invalidate() }
    }

    // MARK: Step 1 — Welcome

    var welcomeStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "display")
                .font(.system(size: 56))
                .foregroundStyle(.primary)

            VStack(spacing: 8) {
                Text("Daylight Mirror")
                    .font(.largeTitle.weight(.medium))
                Text("Mirror your Mac to a Daylight DC-1")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                featureRow("bolt.fill", "30 FPS, under 10ms latency")
                featureRow("eye", "Lossless greyscale — no compression artifacts")
                featureRow("keyboard", "Shortcuts for brightness, warmth, and more")
            }
            .padding(.horizontal, 60)
            .padding(.top, 8)

            Spacer()

            Button(action: { withAnimation { step = .permissions } }) {
                Text("Get Started")
                    .frame(width: 200)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.bottom, 32)
        }
    }

    func featureRow(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
        }
    }

    // MARK: Step 2 — Permissions

    var permissionsStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Text("macOS Permissions")
                .font(.title2.weight(.medium))

            Text("Daylight Mirror needs two permissions to work.\nGrant each one, then come back here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 16) {
                permissionCard(
                    granted: hasScreenRecording,
                    icon: "rectangle.dashed.badge.record",
                    title: "Screen Recording",
                    description: "Captures your display to send to the Daylight",
                    action: {
                        MirrorEngine.requestScreenRecordingPermission()
                        startPermissionPolling()
                    }
                )

                permissionCard(
                    granted: hasAccessibility,
                    icon: "keyboard",
                    title: "Accessibility",
                    description: "Enables Ctrl+F key shortcuts for brightness and warmth",
                    action: {
                        MirrorEngine.requestAccessibilityPermission()
                        startPermissionPolling()
                    }
                )
            }
            .padding(.horizontal, 40)

            if hasScreenRecording && hasAccessibility {
                Text("All permissions granted")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.green)
            } else {
                Text("After granting a permission, you may need to\nquit and reopen the app for it to take effect.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            HStack {
                Button("Back") { withAnimation { step = .welcome } }
                    .buttonStyle(.bordered)
                Spacer()
                Button(action: { withAnimation { step = .connect } }) {
                    Text("Continue")
                        .frame(width: 120)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasScreenRecording)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 32)
        }
    }

    func permissionCard(granted: Bool, icon: String, title: String,
                        description: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: granted ? "checkmark.circle.fill" : icon)
                .font(.title2)
                .foregroundStyle(granted ? .green : .secondary)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(description).font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            if !granted {
                Button("Grant") { action() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(granted ? Color.green.opacity(0.08) : Color.secondary.opacity(0.06))
        )
    }

    func startPermissionPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            hasScreenRecording = MirrorEngine.hasScreenRecordingPermission()
            hasAccessibility = MirrorEngine.hasAccessibilityPermission()
            if hasScreenRecording && hasAccessibility {
                pollTimer?.invalidate()
            }
        }
    }

    // MARK: Step 3 — Connect

    var connectStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Text("Connect Your Daylight")
                .font(.title2.weight(.medium))

            VStack(alignment: .leading, spacing: 16) {
                if !hasADB {
                    setupRow(1, icon: "terminal",
                             title: "Install ADB",
                             detail: "Run in Terminal:",
                             code: "brew install android-platform-tools",
                             done: false)
                } else {
                    setupRow(1, icon: "terminal",
                             title: "ADB installed",
                             detail: nil, code: nil, done: true)
                }

                setupRow(2, icon: "gear",
                         title: "Enable USB Debugging on DC-1",
                         detail: "Settings > About tablet > tap Build number 7 times\nSettings > Developer options > enable USB debugging",
                         code: nil, done: false)

                setupRow(3, icon: "cable.connector",
                         title: "Connect USB-C cable",
                         detail: "Plug your Mac into the Daylight and tap Allow on the prompt",
                         code: nil, done: false)

                HStack(spacing: 10) {
                    if hasDevice {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Daylight DC-1 connected")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.green)
                    } else {
                        ProgressView().controlSize(.small)
                        Text("Waiting for device...")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 40)

            Spacer()

            if hasDevice {
                Button(action: {
                    Task { await engine.start() }
                    withAnimation { step = .ready }
                }) {
                    Text("Mirror Now")
                        .font(.title3.weight(.medium))
                        .frame(width: 200)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            HStack {
                Button("Back") { withAnimation { step = .permissions } }
                    .buttonStyle(.bordered)
                Spacer()
                if !hasDevice {
                    Button(action: { withAnimation { step = .ready } }) {
                        Text("Skip for Now")
                            .frame(width: 140)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 32)
        }
        .onAppear { startDevicePolling() }
    }

    func setupRow(_ number: Int, icon: String, title: String,
                  detail: String?, code: String?, done: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : icon)
                .font(.body)
                .foregroundStyle(done ? .green : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(done ? .secondary : .primary)
                if let detail = detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let code = code {
                    Text(code)
                        .font(.system(size: 11, design: .monospaced))
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.05)))
                        .textSelection(.enabled)
                }
            }
        }
    }

    func startDevicePolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            hasADB = MirrorEngine.hasADB()
            hasDevice = MirrorEngine.hasDevice()
        }
    }

    // MARK: Step 4 — Ready

    var readyStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checkmark.circle")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("You're all set")
                .font(.title2.weight(.medium))

            VStack(alignment: .leading, spacing: 12) {
                howItWorksRow("1", "Click Start Mirror in the menu bar (or press Ctrl+F8)")
                howItWorksRow("2", "Your Mac creates a virtual 4:3 display and starts streaming")
                howItWorksRow("3", "The Daylight app launches automatically via USB")
                howItWorksRow("4", "Your Mac screen dims — the Daylight lights up")
            }
            .padding(.horizontal, 50)

            VStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "display")
                        .font(.callout)
                    Text("Daylight Mirror lives in your menu bar")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    Text("Ctrl")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary))
                    Text("+")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text("F8")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary))
                    Text("toggles mirroring anytime")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Button(action: {
                pollTimer?.invalidate()
                onComplete()
            }) {
                Text("Done")
                    .frame(width: 200)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.bottom, 32)
        }
    }

    func howItWorksRow(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(text)
                .font(.callout)
        }
    }
}

// MARK: - Menu Bar View

struct MirrorMenuView: View {
    @ObservedObject var engine: MirrorEngine
    var showSetup: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                Text("Daylight Mirror")
                    .font(.headline)
                Spacer()
                statusBadge
            }

            // Update banner
            if let version = engine.updateVersion, let urlStr = engine.updateURL,
               let url = URL(string: urlStr) {
                Link(destination: url) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle")
                        Text("v\(version) available")
                    }
                    .font(.caption)
                    .foregroundStyle(.blue)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }

            Divider()

            // Permissions warning if missing
            if !MirrorEngine.allPermissionsGranted {
                Button(action: showSetup) {
                    Label("Permissions needed — open setup", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)

                Divider()
            }

            switch engine.status {
            case .running:
                runningView
            case .starting:
                startingView
            case .stopping:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Stopping...").font(.caption).foregroundStyle(.secondary)
                }
            case .error(let msg):
                errorView(msg)
            case .idle:
                idleView
            }

            // Keyboard shortcuts reference
            Divider()

            VStack(spacing: 4) {
                Text("Ctrl + Function Keys")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                if engine.status == .running {
                    HStack(spacing: 6) {
                        shortcutPill("F8", label: "Mirror")
                        Spacer()
                        shortcutGroup("F1", "F2", label: "Brightness")
                        Spacer()
                        shortcutPill("F10", label: "Backlight")
                        Spacer()
                        shortcutGroup("F11", "F12", label: "Warmth")
                    }
                } else {
                    HStack {
                        shortcutPill("F8", label: "Start Mirror")
                    }
                }
            }
            .padding(.vertical, 2)

            Divider()

            HStack {
                Button("Quit") {
                    engine.stop()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        NSApp.terminate(nil)
                    }
                }
                .font(.caption)
                Spacer()
                Button("Setup") { showSetup() }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                Spacer()
                Link("GitHub", destination: URL(string: "https://github.com/welfvh/daylight-mirror")!)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(width: 280)
    }

    // MARK: - Status Badge

    @ViewBuilder
    var statusBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    var statusColor: Color {
        switch engine.status {
        case .idle: return .gray
        case .starting, .stopping: return .orange
        case .running: return .green
        case .error: return .red
        }
    }

    var statusText: String {
        switch engine.status {
        case .idle: return "Idle"
        case .starting: return "Starting"
        case .running: return "Running"
        case .stopping: return "Stopping"
        case .error: return "Error"
        }
    }

    // MARK: - Running View

    @State private var showDetailedStats = false

    @ViewBuilder
    var runningView: some View {
        // Stats — tap to expand
        Button(action: { withAnimation(.easeInOut(duration: 0.15)) { showDetailedStats.toggle() } }) {
            HStack {
                Label(String(format: "%.0f FPS", engine.fps), systemImage: "speedometer")
                Spacer()
                Text(String(format: "%.1f MB/s", engine.bandwidth))
                    .foregroundStyle(.secondary)
                Image(systemName: showDetailedStats ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if showDetailedStats {
            VStack(spacing: 4) {
                statsRow("Resolution", "\(engine.resolution.rawValue)\(engine.resolution.isHiDPI ? " HiDPI" : "")")
                statsRow("Frame size", "\(engine.frameSizeKB) KB")
                statsRow("Total frames", "\(engine.totalFrames)")
                statsRow("Grey + sharpen", String(format: "%.1f ms", engine.greyMs))
                statsRow("LZ4 compress", String(format: "%.1f ms", engine.compressMs))
                statsRow("Frame budget", String(format: "%.0f%%", (engine.greyMs + engine.compressMs) / (1000.0 / 30.0) * 100))
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
        }

        // Client status
        HStack(spacing: 6) {
            Circle()
                .fill(engine.clientCount > 0 ? .green : .orange)
                .frame(width: 6, height: 6)
            Text(engine.clientCount > 0
                 ? "Daylight connected"
                 : "Waiting for client...")
                .font(.caption)
            Spacer()
            if engine.adbConnected {
                Label("USB", systemImage: "cable.connector")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }

        Divider()

        // Resolution (change triggers restart)
        Picker("Resolution", selection: Binding(
            get: { engine.resolution },
            set: { newRes in
                engine.resolution = newRes
                engine.stop()
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(0.5))
                    await engine.start()
                }
            }
        )) {
            ForEach(DisplayResolution.allCases) { res in
                Text("\(res.label) (\(res.rawValue))").tag(res)
            }
        }
        .pickerStyle(.menu)
        .controlSize(.small)
        .padding(.vertical, 2)

        Divider()

        // Brightness slider (quadratic curve with widened low-end zone)
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: "sun.min")
                    .font(.caption2)
                Slider(
                    value: Binding(
                        get: {
                            if engine.brightness == 0 { return 0 }
                            return sqrt(Double(engine.brightness) / 255.0)
                        },
                        set: { pos in
                            engine.setBrightness(MirrorEngine.brightnessFromSliderPos(pos))
                        }
                    ),
                    in: 0...1
                )
                Image(systemName: "sun.max")
                    .font(.caption2)
            }
        }

        // Warmth slider
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: "snowflake")
                    .font(.caption2)
                Slider(
                    value: Binding(
                        get: { Double(engine.warmth) },
                        set: { engine.setWarmth(Int($0)) }
                    ),
                    in: 0...255
                )
                Image(systemName: "flame")
                    .font(.caption2)
            }
        }

        // Backlight toggle
        Toggle(isOn: Binding(
            get: { engine.backlightOn },
            set: { _ in engine.toggleBacklight() }
        )) {
            Label("Backlight", systemImage: "lightbulb")
                .font(.caption)
        }
        .toggleStyle(.switch)
        .controlSize(.small)

        Divider()

        // Sharpening slider (0-1.5)
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: "circle.dashed")
                    .font(.caption2)
                Slider(
                    value: Binding(
                        get: { engine.sharpenAmount },
                        set: { engine.sharpenAmount = $0 }
                    ),
                    in: 0...1.5,
                    step: 0.1
                )
                Image(systemName: "diamond")
                    .font(.caption2)
            }
            Text("Sharpen: \(String(format: "%.1f", engine.sharpenAmount))")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }

        Divider()

        // Reconnect / Restart / Stop
        HStack(spacing: 6) {
            Button(action: { engine.reconnect() }) {
                Text("Reconnect")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button(action: {
                engine.stop()
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(0.5))
                    await engine.start()
                }
            }) {
                Text("Restart")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button(action: { engine.stop() }) {
                Text("Stop")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: - Starting View

    @ViewBuilder
    var startingView: some View {
        HStack {
            ProgressView()
                .controlSize(.small)
            Text("Creating virtual display...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Error View

    @ViewBuilder
    func errorView(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.red)

        Button(action: { Task { await engine.start() } }) {
            Text("Retry")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
    }

    // MARK: - Idle View

    @ViewBuilder
    var idleView: some View {
        VStack(spacing: 8) {
            Text("Mirror your Mac to a Daylight DC-1")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            // Resolution picker
            Picker("Resolution", selection: $engine.resolution) {
                ForEach(DisplayResolution.allCases) { res in
                    Text("\(res.label) (\(res.rawValue))").tag(res)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .padding(.vertical, 2)

            Divider()

            Button(action: { Task { await engine.start() } }) {
                Text("Start Mirror")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
    }

    // MARK: - Stats Row

    @ViewBuilder
    func statsRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.primary)
        }
    }

    // MARK: - Keyboard Shortcut Pills

    @ViewBuilder
    func shortcutGroup(_ key1: String, _ key2: String, label: String) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 3) {
                keyPill(key1)
                keyPill(key2)
            }
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    func shortcutPill(_ key: String, label: String) -> some View {
        VStack(spacing: 2) {
            keyPill(key)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    func keyPill(_ key: String) -> some View {
        Text(key)
            .font(.system(size: 9, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
            )
    }
}
