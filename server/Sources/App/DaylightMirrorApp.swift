// DaylightMirrorApp.swift — Menu bar app for Daylight Mirror.
//
// Provides one-click start/stop, status display, and brightness/warmth sliders.
// No dock icon — lives entirely in the menu bar.

import SwiftUI
import MirrorEngine

@main
struct DaylightMirrorApp: App {
    @StateObject private var engine = MirrorEngine()

    init() {
        // Menu bar only — no dock icon
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MirrorMenuView(engine: engine)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "display")
                if engine.status == .running {
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

            Divider()

            Button("Quit") {
                engine.stop()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    NSApp.terminate(nil)
                }
            }
            .font(.caption)
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

        // Brightness slider
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: "sun.min")
                    .font(.caption2)
                Slider(
                    value: Binding(
                        get: { Double(engine.brightness) },
                        set: { engine.setBrightness(Int($0)) }
                    ),
                    in: 0...255
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

        // Stop button
        Button(action: { engine.stop() }) {
            Text("Stop Mirror")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
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

            Button(action: { Task { await engine.start() } }) {
                Text("Start Mirror")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
    }
}
