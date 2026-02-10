// ControlSocket.swift — Unix domain socket IPC for CLI commands to the running engine.

import Foundation

// MARK: - Control Socket (IPC for CLI commands to the running engine)

/// Unix domain socket server at /tmp/daylight-mirror.sock for CLI control.
/// Accepts newline-terminated text commands, dispatches to MirrorEngine on the
/// main queue, returns a response, and closes. Runs inside whichever process
/// owns the engine (GUI app or CLI daemon).
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
                // Accept both preset names ("sharp") and raw values ("1600x1200")
                let preset = DisplayResolution.allCases.first {
                    $0.rawValue == arg || $0.label.lowercased() == arg.lowercased()
                }
                guard let newRes = preset else {
                    let valid = DisplayResolution.allCases.map { $0.label.lowercased() }.joined(separator: ", ")
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
            if let arg = parts.dropFirst().first {
                guard let val = Double(arg), val >= 0, val <= 3.0 else {
                    return "ERR value must be 0.0-3.0 (0=none, 1=mild, 2=strong)"
                }
                engine.sharpenAmount = val
                return "OK \(String(format: "%.1f", val))"
            } else {
                return "OK \(String(format: "%.1f", engine.sharpenAmount))"
            }

        case "CONTRAST":
            if let arg = parts.dropFirst().first {
                guard let val = Double(arg), val >= 1.0, val <= 2.0 else {
                    return "ERR value must be 1.0-2.0 (1.0=off, 1.5=moderate, 2.0=high)"
                }
                engine.contrastAmount = val
                return "OK \(String(format: "%.1f", val))"
            } else {
                return "OK \(String(format: "%.1f", engine.contrastAmount))"
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

        default:
            return "ERR unknown command"
        }
    }
}
