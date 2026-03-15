// ControlSocket.swift — Unix socket IPC for CLI commands to the running engine.
//
// Accepts newline-terminated text commands on /tmp/daylight-mirror.sock, dispatches
// to MirrorEngine on the main queue, returns a response, and closes. Runs inside
// whichever process owns the engine (GUI app or CLI daemon).

import Foundation
import IOKit

public class ControlSocket {
    public static let socketPath = "/tmp/daylight-mirror.sock"

    private let engine: MirrorEngine
    private var fd: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    public init(engine: MirrorEngine) {
        self.engine = engine
    }

    public func start() {
        // Clean up stale socket from previous crash
        unlink(Self.socketPath)

        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { print("[Socket] Failed to create socket"); return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathLen = MemoryLayout.size(ofValue: addr.sun_path)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            Self.socketPath.withCString { src in
                memcpy(ptr, src, min(strlen(src) + 1, pathLen))
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            print("[Socket] Failed to bind: \(String(cString: strerror(errno)))")
            close(fd); fd = -1; return
        }

        guard listen(fd, 5) == 0 else {
            print("[Socket] Failed to listen: \(String(cString: strerror(errno)))")
            close(fd); fd = -1; return
        }

        // Async accept via GCD — same pattern as DispatchSource signal handlers
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        source.setEventHandler { [weak self] in self?.acceptConnection() }
        source.setCancelHandler { [weak self] in
            if let fd = self?.fd, fd >= 0 { close(fd) }
            unlink(Self.socketPath)
        }
        source.resume()
        acceptSource = source

        print("[Socket] Control socket listening at \(Self.socketPath)")
    }

    public func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        fd = -1
    }

    private func acceptConnection() {
        let clientFD = accept(fd, nil, nil)
        guard clientFD >= 0 else { return }

        // Read one newline-terminated command (up to 256 bytes)
        var buffer = [CChar](repeating: 0, count: 256)
        let bytesRead = recv(clientFD, &buffer, buffer.count - 1, 0)
        guard bytesRead > 0 else { close(clientFD); return }

        let rawCommand = String(cString: buffer)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Dispatch to main queue where the engine lives (@MainActor)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { close(clientFD); return }
            let response = self.handleCommand(rawCommand)
            _ = (response + "\n").withCString { ptr in
                send(clientFD, ptr, strlen(ptr), 0)
            }
            close(clientFD)
        }
    }

    /// Query IOKit for clamshell-related power management state.
    private static func iokitClamshellState() -> [(String, String)] {
        var result: [(String, String)] = []
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
            IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return result }
        defer { IOObjectRelease(service) }
        if let val = IORegistryEntryCreateCFProperty(service,
            "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() {
            result.append(("clamshell_state", "\(val)"))
        }
        if let val = IORegistryEntryCreateCFProperty(service,
            "AppleClamshellCausesSleep" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() {
            result.append(("clamshell_causes_sleep", "\(val)"))
        }
        if let val = IORegistryEntryCreateCFProperty(service,
            "SleepDisabled" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() {
            result.append(("sleep_disabled", "\(val)"))
        }
        if let val = IORegistryEntryCreateCFProperty(service,
            "ExternalConnected" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() {
            result.append(("external_connected", "\(val)"))
        }
        return result
    }

    /// Parse and execute a control command. Returns the response string.
    private func handleCommand(_ raw: String) -> String {
        let parts = raw.split(separator: " ", maxSplits: 1).map(String.init)
        let verb = parts.first?.uppercased() ?? ""
        let arg = parts.count > 1 ? parts[1] : nil

        switch verb {
        case "BRIGHTNESS":
            if let arg = arg, let value = Int(arg) {
                let clamped = max(0, min(255, value))
                engine.setBrightness(clamped)
                return "OK \(clamped)"
            } else {
                return "OK \(engine.brightness)"
            }

        case "WARMTH":
            if let arg = arg, let value = Int(arg) {
                let clamped = max(0, min(255, value))
                engine.setWarmth(clamped)
                return "OK \(clamped)"
            } else {
                return "OK \(engine.warmth)"
            }

        case "BACKLIGHT":
            let action = arg?.lowercased() ?? ""
            switch action {
            case "on":
                if !engine.backlightOn { engine.toggleBacklight() }
                return "OK on"
            case "off":
                if engine.backlightOn { engine.toggleBacklight() }
                return "OK off"
            case "toggle":
                engine.toggleBacklight()
                return "OK \(engine.backlightOn ? "on" : "off")"
            default:
                return "OK \(engine.backlightOn ? "on" : "off")"
            }

        case "RESOLUTION":
            if let arg = arg {
                // Accept preset names ("sharp", "portrait-cozy"), raw values ("1600x1200"),
                // and hyphenated/spaced variants of multi-word labels.
                let normalizedArg = arg.lowercased().replacingOccurrences(of: "-", with: " ")
                let preset = DisplayResolution.allCases.first {
                    $0.rawValue == arg || $0.label.lowercased() == normalizedArg
                }
                guard let newRes = preset else {
                    let valid = DisplayResolution.allCases.map { $0.label.lowercased().replacingOccurrences(of: " ", with: "-") }.joined(separator: ", ")
                    return "ERR unknown resolution (valid: \(valid))"
                }
                if newRes == engine.resolution {
                    return "OK \(newRes.label.lowercased()) (no change)"
                }
                engine.resolution = newRes
                // Auto-restart if running, matching GUI behavior
                if engine.status == .running {
                    engine.stop()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        Task { @MainActor in await self.engine.start() }
                    }
                    return "OK \(newRes.label.lowercased()) (restarting)"
                }
                return "OK \(newRes.label.lowercased())"
            } else {
                return "OK \(engine.resolution.label.lowercased())"
            }

        case "RESTART":
            if engine.status == .running {
                engine.stop()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    Task { @MainActor in await self.engine.start() }
                }
                return "OK restarting"
            } else {
                return "ERR not running"
            }

        case "START":
            if engine.status == .running {
                return "OK already running"
            }
            if engine.status == .starting {
                return "OK already starting"
            }
            Task { @MainActor in await self.engine.start() }
            return "OK starting"

        case "STOP":
            if engine.status == .idle {
                return "OK already idle"
            }
            engine.stop()
            return "OK stopping"

        case "STATUS":
            let s: String
            switch engine.status {
            case .idle: s = "idle"
            case .waitingForDevice: s = "waiting_for_device"
            case .starting: s = "starting"
            case .running: s = "running"
            case .stopping: s = "stopping"
            case .error(let msg): s = "error: \(msg)"
            }
            return "OK \(s)"

        case "RECONNECT":
            if engine.status == .running {
                engine.reconnect()
                return "OK reconnecting"
            } else {
                return "ERR not running"
            }

        case "SHARPEN":
            return "DISABLED — raw BGRA experiment, no Mac-side processing"

        case "CONTRAST":
            return "DISABLED — raw BGRA experiment, no Mac-side processing"

        case "DISPLAYMODE":
            if let arg = arg?.lowercased() {
                guard let mode = DisplayMode(rawValue: arg) else {
                    return "ERR unknown mode (valid: mirror, extended)"
                }
                if mode == engine.displayMode {
                    return "OK \(mode.rawValue) (no change)"
                }
                engine.displayMode = mode
                // Auto-restart if running, since display mode changes how the virtual display is configured
                if engine.status == .running {
                    engine.stop()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        Task { @MainActor in await self.engine.start() }
                    }
                    return "OK \(mode.rawValue) (restarting)"
                }
                return "OK \(mode.rawValue)"
            } else {
                return "OK \(engine.displayMode.rawValue)"
            }

        case "FONTSMOOTHING":
            if let arg = parts.dropFirst().first?.lowercased() {
                switch arg {
                case "on":
                    engine.setFontSmoothing(enabled: true)
                    engine.fontSmoothingDisabled = false
                    return "OK on"
                case "off":
                    engine.setFontSmoothing(enabled: false)
                    engine.fontSmoothingDisabled = true
                    return "OK off"
                default:
                    return "ERR use on or off"
                }
            } else {
                return "OK \(engine.fontSmoothingDisabled ? "off" : "on")"
            }

        case "LATENCY":
            guard engine.status == .running else {
                return "ERR not running"
            }
            let lines = [
                "fps=\(String(format: "%.1f", engine.fps))",
                "grey_ms=\(String(format: "%.1f", engine.greyMs))",
                "compress_ms=\(String(format: "%.1f", engine.compressMs))",
                "jitter_ms=\(String(format: "%.1f", engine.jitterMs))",
                "rtt_avg_ms=\(String(format: "%.1f", engine.rttMs))",
                "rtt_p95_ms=\(String(format: "%.1f", engine.rttP95Ms))",
                "clients=\(engine.clientCount)",
                "total_frames=\(engine.totalFrames)",
                "skipped_frames=\(engine.skippedFrames)"
            ]
            return "OK\n" + lines.joined(separator: "\n")

        case "CLAMSHELL":
            if let arg = parts.dropFirst().first?.lowercased() {
                switch arg {
                case "on", "enable":
                    engine.clamshellModeEnabled = true
                    return "OK on"
                case "off", "disable":
                    engine.clamshellModeEnabled = false
                    return "OK off"
                default:
                    return "ERR use on or off"
                }
            } else {
                return "OK \(engine.clamshellModeEnabled ? "on" : "off")"
            }

        case "HEALTH":
            let verbose = arg?.lowercased() == "verbose"
            let s: String
            switch engine.status {
            case .idle: s = "idle"
            case .waitingForDevice: s = "waiting_for_device"
            case .starting: s = "starting"
            case .running: s = "running"
            case .stopping: s = "stopping"
            case .error(let msg): s = "error: \(msg)"
            }
            var lines = [
                "status=\(s)",
                "version=\(MirrorEngine.appVersion)",
                "resolution=\(engine.resolution.label)",
                "display_mode=\(engine.displayMode.rawValue)",
                "mode=raw_bgra_experiment",
                "fps=\(String(format: "%.1f", engine.fps))",
                "clients=\(engine.clientCount)",
                "total_frames=\(engine.totalFrames)",
                "skipped_frames=\(engine.skippedFrames)",
                "frame_size_kb=\(engine.frameSizeKB)",
                "bandwidth_mbps=\(String(format: "%.2f", engine.bandwidth))",
                "grey_ms=\(String(format: "%.1f", engine.greyMs))",
                "compress_ms=\(String(format: "%.1f", engine.compressMs))",
                "jitter_ms=\(String(format: "%.1f", engine.jitterMs))",
                "rtt_avg_ms=\(String(format: "%.1f", engine.rttMs))",
                "rtt_p95_ms=\(String(format: "%.1f", engine.rttP95Ms))",
                "brightness=\(engine.brightness)",
                "warmth=\(engine.warmth)",
                "backlight=\(engine.backlightOn ? "on" : "off")",
                "clamshell=\(engine.clamshellModeEnabled ? "on" : "off")",
                "auto_mirror=\(engine.autoMirrorEnabled ? "on" : "off")",
                "auto_dim=\(engine.autoDimMac ? "on" : "off")",
                "font_smoothing=\(engine.fontSmoothingDisabled ? "off" : "on")",
                "adb=\(engine.adbConnected ? "connected" : "disconnected")",
                "sessions=\(engine.sessions.count)",
                "device_detected=\(engine.deviceDetected ? "yes" : "no")"
            ]
            if verbose {
                lines.append("---system---")
                // Process memory
                var info = mach_task_basic_info()
                var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
                let kr = withUnsafeMutablePointer(to: &info) { infoPtr in
                    infoPtr.withMemoryRebound(to: Int32.self, capacity: Int(count)) { rawPtr in
                        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rawPtr, &count)
                    }
                }
                if kr == KERN_SUCCESS {
                    let rss = Double(info.resident_size) / 1024 / 1024
                    let virt = Double(info.virtual_size) / 1024 / 1024
                    lines.append("memory_rss_mb=\(String(format: "%.1f", rss))")
                    lines.append("memory_virtual_mb=\(String(format: "%.0f", virt))")
                }
                // Uptime
                let uptime = ProcessInfo.processInfo.systemUptime
                let hours = Int(uptime) / 3600
                let mins = (Int(uptime) % 3600) / 60
                lines.append("process_uptime=\(hours)h\(mins)m")
                // Per-session details
                for (i, session) in engine.sessions.enumerated() {
                    let vd = session.displayManager
                    lines.append("session[\(i)].device=\(session.device.model)")
                    lines.append("session[\(i)].serial=\(session.device.serial)")
                    lines.append("session[\(i)].port=\(session.port)")
                    lines.append("session[\(i)].resolution=\(session.resolution.label)")
                    lines.append("session[\(i)].display_id=\(vd?.displayID ?? 0)")
                    lines.append("session[\(i)].fps=\(String(format: "%.1f", session.fps))")
                    lines.append("session[\(i)].clients=\(session.clientCount)")
                    lines.append("session[\(i)].adb=\(session.adbConnected ? "yes" : "no")")
                    lines.append("session[\(i)].capture_active=\(session.capture != nil ? "yes" : "no")")
                    lines.append("session[\(i)].input_server=\(session.inputServer?.running == true ? "running" : "stopped")")
                    if let cap = session.capture {
                        lines.append("session[\(i)].capture_frames=\(cap.frameCount)")
                        lines.append("session[\(i)].capture_skipped=\(cap.skippedFrames)")
                        lines.append("session[\(i)].capture_stream=\(cap.displayStream != nil ? "alive" : "dead")")
                    }
                }
                // Clamshell internals
                lines.append("caffeinate_pid=\(engine.caffeinateProcess?.processIdentifier ?? 0)")
                lines.append("caffeinate_running=\(engine.caffeinateProcess?.isRunning == true ? "yes" : "no")")
                // IOKit clamshell state
                let ioOutput = Self.iokitClamshellState()
                for (k, v) in ioOutput { lines.append("iokit.\(k)=\(v)") }
            }
            return "OK\n" + lines.joined(separator: "\n")

        default:
            return "ERR unknown command"
        }
    }
}
