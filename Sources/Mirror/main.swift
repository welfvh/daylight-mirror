// CLI interface for Daylight Mirror.
//
// Subcommands:
//   daylight-mirror start              — Start mirroring (keeps process alive)
//   daylight-mirror stop               — Stop the running mirror instance
//   daylight-mirror status             — Print current state (machine-readable key=value pairs)
//   daylight-mirror reconnect          — Re-establish ADB tunnel and relaunch Android app
//   daylight-mirror brightness [0-255] — Get or set Daylight brightness
//   daylight-mirror warmth [0-255]     — Get or set Daylight warmth (amber rate)
//   daylight-mirror backlight [on|off|toggle] — Get or toggle backlight
//   daylight-mirror resolution [preset] — Get or set resolution (incl. portrait variants)
//   daylight-mirror restart            — Full stop + start cycle
//
// The engine (whether started by this CLI or the GUI menu bar app) exposes a
// Unix domain socket at /tmp/daylight-mirror.sock for IPC. Control commands
// connect to this socket, send a text command, and receive a response.
//
// Ctrl+C (SIGINT) or `daylight-mirror stop` shuts down gracefully.
// SIGUSR1 triggers an ADB reconnect without restarting.
//
// A PID file at /tmp/daylight-mirror.pid tracks the running CLI instance.
// A stats file at /tmp/daylight-mirror.status is updated every 5 seconds.

import Foundation
@preconcurrency import MirrorEngine

// MARK: - Constants

let PID_FILE = "/tmp/daylight-mirror.pid"
let STATUS_FILE = "/tmp/daylight-mirror.status"

// Unbuffered stdout so prints appear immediately in piped/redirected contexts
setbuf(stdout, nil)

// MARK: - Helpers

/// Write the current PID to the pid file so other commands can find us.
func writePIDFile() {
    let pid = ProcessInfo.processInfo.processIdentifier
    try? "\(pid)".write(toFile: PID_FILE, atomically: true, encoding: .utf8)
}

/// Remove the PID file on exit.
func removePIDFile() {
    try? FileManager.default.removeItem(atPath: PID_FILE)
}

/// Remove the status file on exit.
func removeStatusFile() {
    try? FileManager.default.removeItem(atPath: STATUS_FILE)
}

/// Read the PID of a running daylight-mirror instance, or nil if not running.
func readRunningPID() -> pid_t? {
    guard let contents = try? String(contentsOfFile: PID_FILE, encoding: .utf8),
          let pid = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        return nil
    }
    // Check if process is actually alive (signal 0 = existence check)
    if kill(pid, 0) == 0 {
        return pid
    }
    // Stale PID file — clean it up
    removePIDFile()
    removeStatusFile()
    return nil
}

/// Write a machine-readable status file that `status` can read.
func writeStatusFile(status: String, resolution: String, fps: Double,
                     bandwidth: Double, clients: Int, totalFrames: Int, adb: Bool) {
    let lines = [
        "status=\(status)",
        "resolution=\(resolution)",
        "fps=\(String(format: "%.1f", fps))",
        "bandwidth_mbps=\(String(format: "%.2f", bandwidth))",
        "clients=\(clients)",
        "total_frames=\(totalFrames)",
        "adb=\(adb)",
        "pid=\(ProcessInfo.processInfo.processIdentifier)",
        "updated=\(ISO8601DateFormatter().string(from: Date()))"
    ]
    try? lines.joined(separator: "\n").write(toFile: STATUS_FILE, atomically: true, encoding: .utf8)
}

/// Check if the control socket exists (meaning some engine instance is running).
func controlSocketExists() -> Bool {
    FileManager.default.fileExists(atPath: ControlSocket.socketPath)
}

// MARK: - Control Socket Client

/// Connect to the running engine's control socket, send a command, return the response.
/// Returns nil if no engine is running or the socket doesn't exist.
func sendControlCommand(_ command: String) -> String? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathLen = MemoryLayout.size(ofValue: addr.sun_path)
    _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        ControlSocket.socketPath.withCString { src in
            memcpy(ptr, src, min(strlen(src) + 1, pathLen))
        }
    }

    let connectResult = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connectResult == 0 else { return nil }

    // Send command with newline terminator
    let msg = command + "\n"
    _ = msg.withCString { ptr in send(fd, ptr, strlen(ptr), 0) }

    // Read response
    var buffer = [CChar](repeating: 0, count: 1024)
    let bytesRead = recv(fd, &buffer, buffer.count - 1, 0)
    guard bytesRead > 0 else { return nil }
    return String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Ensure an engine is running (CLI or GUI), send a control command, print result, exit.
func runControlCommand(_ command: String) {
    // Check socket first — works for both CLI daemon and GUI app
    guard controlSocketExists() else {
        print("ERROR: Daylight Mirror is not running.")
        print("Start the mirror first (menu bar app or `daylight-mirror start`).")
        exit(1)
    }
    guard let response = sendControlCommand(command) else {
        print("ERROR: Could not connect to control socket.")
        print("The running instance may not support CLI control. Try restarting.")
        exit(1)
    }
    print(response)
    exit(response.hasPrefix("OK") ? 0 : 1)
}

// MARK: - Commands

/// `daylight-mirror start` — start mirroring. If the GUI app is running, tells it
/// to start via socket. Otherwise, creates its own engine as a CLI daemon.
func commandStart() {
    // If the GUI app (or another engine) has a socket open, send START
    if controlSocketExists() {
        if let response = sendControlCommand("START") {
            print(response)
            exit(response.hasPrefix("OK") ? 0 : 1)
        }
    }

    // Bail if CLI daemon already running
    if let existingPID = readRunningPID() {
        print("ERROR: Daylight Mirror CLI is already running (PID \(existingPID))")
        print("Run `daylight-mirror stop` first, or `daylight-mirror status` for details.")
        exit(1)
    }

    print("Daylight Mirror v\(MirrorEngine.appVersion) -- CLI mode")
    print("---")

    writePIDFile()

    let engine = MirrorEngine()

    // Track state for the status file
    var currentFPS: Double = 0
    var currentBW: Double = 0
    var currentClients: Int = 0
    var currentTotalFrames: Int = 0
    var currentADB: Bool = false
    var currentStatus: String = "starting"

    // Periodic status file writer (every 5 seconds)
    let statusTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
    statusTimer.schedule(deadline: .now() + 1, repeating: 5.0)
    statusTimer.setEventHandler {
        writeStatusFile(
            status: currentStatus,
            resolution: engine.resolution.rawValue,
            fps: currentFPS,
            bandwidth: currentBW,
            clients: currentClients,
            totalFrames: currentTotalFrames,
            adb: currentADB
        )
    }
    statusTimer.resume()

    // Graceful shutdown on SIGINT (Ctrl+C) and SIGTERM (`stop` command).
    // Uses DispatchSource instead of signal() because C signal handlers can't capture context.
    func installShutdownSource(for sig: Int32) -> DispatchSourceSignal {
        // Ignore the default handler so DispatchSource gets the signal
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            let sigName = sig == SIGINT ? "SIGINT" : "SIGTERM"
            print("\n[\(sigName)] Shutting down...")
            engine.stop()
            // Give the engine a moment to tear down
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                removePIDFile()
                removeStatusFile()
                print("Stopped.")
                exit(0)
            }
        }
        source.resume()
        return source
    }
    let sigintSource = installShutdownSource(for: SIGINT)
    let sigtermSource = installShutdownSource(for: SIGTERM)
    _ = (sigintSource, sigtermSource) // retain

    // SIGUSR1 triggers ADB reconnect without restart
    signal(SIGUSR1, SIG_IGN)
    let sigusr1Source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
    sigusr1Source.setEventHandler {
        print("\n[SIGUSR1] Reconnecting ADB...")
        engine.reconnect()
    }
    sigusr1Source.resume()

    // Start the engine (which also starts the control socket)
    Task { @MainActor in
        await engine.start()

        // Poll engine state into status file variables. The pollTimer must be
        // retained at this scope — store in a variable the closure captures.
        var keepPollTimer: DispatchSourceTimer?
        let pollTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        pollTimer.schedule(deadline: .now() + 2, repeating: 2.0)
        pollTimer.setEventHandler {
            DispatchQueue.main.async {
                currentFPS = engine.fps
                currentBW = engine.bandwidth
                currentClients = engine.clientCount
                currentTotalFrames = engine.totalFrames
                currentADB = engine.adbConnected

                switch engine.status {
                case .idle: currentStatus = "idle"
                case .waitingForDevice: currentStatus = "waiting_for_device"
                case .starting: currentStatus = "starting"
                case .running: currentStatus = "running"
                case .stopping: currentStatus = "stopping"
                case .error(let msg): currentStatus = "error: \(msg)"
                }
            }
        }
        pollTimer.resume()
        keepPollTimer = pollTimer
        _ = keepPollTimer // suppress unused warning, prevent dealloc

        print("---")
        print("Mirror running. Ctrl+C to stop.")
        print("Or from another terminal: daylight-mirror stop")
    }

    // Keep the process alive — the virtual display and servers need the runloop
    RunLoop.main.run()
}

/// `daylight-mirror stop` — stop mirroring. Tries socket first (works with GUI app),
/// falls back to SIGTERM for CLI daemon.
func commandStop() {
    // Try socket first (works with GUI app or any engine with socket)
    if controlSocketExists() {
        if let response = sendControlCommand("STOP") {
            print(response)
            exit(response.hasPrefix("OK") ? 0 : 1)
        }
    }

    // Fall back to SIGTERM for CLI daemon
    guard let pid = readRunningPID() else {
        print("Daylight Mirror is not running.")
        exit(0)
    }
    print("Stopping Daylight Mirror (PID \(pid))...")
    kill(pid, SIGTERM)

    // Wait briefly for the process to exit
    for _ in 0..<20 {
        usleep(250_000) // 250ms
        if kill(pid, 0) != 0 {
            print("Stopped.")
            exit(0)
        }
    }
    print("Process did not exit within 5 seconds. You may need to `kill -9 \(pid)`.")
    exit(1)
}

/// `daylight-mirror status` — print the current state.
func commandStatus() {
    // Try socket first (works with GUI app)
    if controlSocketExists() {
        if let response = sendControlCommand("STATUS") {
            // Socket is alive — engine exists
            let engineStatus = response.replacingOccurrences(of: "OK ", with: "")
            print("running=\(engineStatus != "idle")")
            print("status=\(engineStatus)")
            // Supplement with status file if available
            if let contents = try? String(contentsOfFile: STATUS_FILE, encoding: .utf8) {
                print(contents)
            }
            exit(0)
        }
    }

    // Fall back to PID file (CLI daemon)
    guard let pid = readRunningPID() else {
        print("status=idle")
        print("running=false")
        exit(0)
    }

    // Read the status file for detailed info
    if let contents = try? String(contentsOfFile: STATUS_FILE, encoding: .utf8) {
        print("running=true")
        print(contents)
    } else {
        print("running=true")
        print("status=starting")
        print("pid=\(pid)")
    }
    exit(0)
}

/// `daylight-mirror reconnect` — reconnect ADB. Tries socket first, falls back to SIGUSR1.
func commandReconnect() {
    // Try socket first
    if controlSocketExists() {
        if let response = sendControlCommand("RECONNECT") {
            print(response)
            exit(response.hasPrefix("OK") ? 0 : 1)
        }
    }

    // Fall back to SIGUSR1 for CLI daemon
    guard let pid = readRunningPID() else {
        print("ERROR: Daylight Mirror is not running.")
        print("Start it first with: daylight-mirror start")
        exit(1)
    }
    print("Sending reconnect signal to PID \(pid)...")
    kill(pid, SIGUSR1)
    print("Reconnect triggered.")
    exit(0)
}

/// `daylight-mirror brightness [value]` — get or set Daylight brightness (0-255).
func commandBrightness() {
    let arg = args.count > 2 ? args[2] : nil
    if let arg = arg {
        guard let value = Int(arg), (0...255).contains(value) else {
            print("ERROR: brightness value must be 0-255")
            exit(1)
        }
        runControlCommand("BRIGHTNESS \(value)")
    } else {
        runControlCommand("BRIGHTNESS")
    }
}

/// `daylight-mirror warmth [value]` — get or set Daylight warmth/amber rate (0-255).
func commandWarmth() {
    let arg = args.count > 2 ? args[2] : nil
    if let arg = arg {
        guard let value = Int(arg), (0...255).contains(value) else {
            print("ERROR: warmth value must be 0-255")
            exit(1)
        }
        runControlCommand("WARMTH \(value)")
    } else {
        runControlCommand("WARMTH")
    }
}

/// `daylight-mirror backlight [on|off|toggle]` — get or toggle backlight state.
func commandBacklight() {
    let arg = args.count > 2 ? args[2].lowercased() : nil
    if let arg = arg {
        guard ["on", "off", "toggle"].contains(arg) else {
            print("ERROR: backlight argument must be on, off, or toggle")
            exit(1)
        }
        runControlCommand("BACKLIGHT \(arg)")
    } else {
        runControlCommand("BACKLIGHT")
    }
}

/// `daylight-mirror resolution [preset]` — get or set resolution (comfortable|balanced|sharp).
/// Changing resolution while running triggers an automatic restart.
func commandResolution() {
    let arg = args.count > 2 ? args[2] : nil
    if let arg = arg {
        runControlCommand("RESOLUTION \(arg)")
    } else {
        runControlCommand("RESOLUTION")
    }
}

/// `daylight-mirror restart` — full stop + start cycle.
func commandRestart() {
    runControlCommand("RESTART")
}

/// `daylight-mirror sharpen [0.0-3.0]` — get or set sharpening amount.
func commandSharpen() {
    let arg = args.count > 2 ? args[2] : nil
    if let arg = arg {
        runControlCommand("SHARPEN \(arg)")
    } else {
        runControlCommand("SHARPEN")
    }
}

/// `daylight-mirror contrast [1.0-2.0]` — get or set contrast enhancement.
func commandContrast() {
    let arg = args.count > 2 ? args[2] : nil
    if let arg = arg {
        runControlCommand("CONTRAST \(arg)")
    } else {
        runControlCommand("CONTRAST")
    }
}

/// `daylight-mirror fontsmoothing [on|off]` — get or set macOS font smoothing.
func commandFontSmoothing() {
    let arg = args.count > 2 ? args[2].lowercased() : nil
    if let arg = arg {
        runControlCommand("FONTSMOOTHING \(arg)")
    } else {
        runControlCommand("FONTSMOOTHING")
    }
}

/// Print usage information.
func printUsage() {
    print("Daylight Mirror v\(MirrorEngine.appVersion) -- CLI")
    print("")
    print("Usage: daylight-mirror <command>")
    print("")
    print("Commands:")
    print("  start                    Start mirroring (creates virtual display, capture, servers, ADB)")
    print("  stop                     Stop the running mirror instance")
    print("  status                   Print current state (machine-readable key=value pairs)")
    print("  reconnect                Re-establish ADB reverse tunnel and relaunch Android app")
    print("  brightness [0-255]       Get or set Daylight brightness")
    print("  warmth [0-255]           Get or set Daylight warmth (amber rate)")
    print("  backlight [on|off|toggle] Get or toggle backlight")
    print("  resolution [preset]      Get or set resolution (cozy, comfortable, balanced, sharp,")
    print("                             portrait-cozy, portrait-balanced, portrait-sharp)")
    print("  sharpen [0.0-3.0]        Get or set sharpening (0=none, 1=mild, 2=strong)")
    print("  contrast [1.0-2.0]       Get or set contrast (1.0=off, 1.5=moderate, 2.0=high)")
    print("  fontsmoothing [on|off]   Get or set macOS font smoothing (off = crisper text)")
    print("  restart                  Full stop + start cycle")
    print("")
    print("The `start` command keeps the process alive. Stop it with Ctrl+C or `daylight-mirror stop`.")
    print("Control commands work with both the CLI daemon and the menu bar app.")
}

// MARK: - Argument Dispatch

let args = ProcessInfo.processInfo.arguments
let command = args.count > 1 ? args[1] : nil

switch command {
case "start":
    commandStart()
case "stop":
    commandStop()
case "status":
    commandStatus()
case "reconnect":
    commandReconnect()
case "brightness":
    commandBrightness()
case "warmth":
    commandWarmth()
case "backlight":
    commandBacklight()
case "resolution":
    commandResolution()
case "restart":
    commandRestart()
case "sharpen":
    commandSharpen()
case "contrast":
    commandContrast()
case "fontsmoothing":
    commandFontSmoothing()
case "-h", "--help", "help":
    printUsage()
    exit(0)
case nil:
    // No argument — default to start (backward-compatible with the original behavior)
    printUsage()
    print("")
    print("No command specified. Starting mirror...")
    print("")
    commandStart()
default:
    print("Unknown command: \(command!)")
    print("")
    printUsage()
    exit(1)
}
