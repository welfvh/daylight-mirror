// DaylightMirrorApp.swift — Menu bar app for Daylight Mirror.
//
// Provides one-click start/stop, status display, and brightness/warmth sliders.
// No dock icon — lives entirely in the menu bar. Ctrl+F8 toggles mirroring globally.

import SwiftUI
import MirrorEngine

/// App delegate owns the MirrorEngine and sets up the global hotkey at launch.
class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let engine = MirrorEngine()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[AppDelegate] didFinishLaunching — registering Ctrl+F8")
        engine.setupGlobalShortcut()
    }
}

@main
struct DaylightMirrorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    init() {
        // Menu bar only — no dock icon
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MirrorMenuView(engine: delegate.engine)
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

struct MirrorMenuView: View {
    @ObservedObject var engine: MirrorEngine

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

    @ViewBuilder
    var runningView: some View {
        // Stats
        HStack {
            Label(String(format: "%.0f FPS", engine.fps), systemImage: "speedometer")
            Spacer()
            Text(String(format: "%.1f MB/s", engine.bandwidth))
                .foregroundStyle(.secondary)
        }
        .font(.caption)

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
                            // brightness → slider position via sqrt
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
