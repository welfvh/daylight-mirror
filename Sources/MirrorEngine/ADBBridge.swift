// ADBBridge.swift — ADB communication layer for Daylight Mirror.
//
// Manages the adb binary (bundled or PATH), reverse tunnels, device queries,
// companion APK installation, and app launching on the Daylight DC-1.
//
// KEY DESIGN: All adb commands run via `/bin/sh -c` to inherit the user's full
// shell environment. This is critical because GUI apps (.app bundles launched via
// Finder/Spotlight) get a stripped environment — adb may start a SEPARATE server
// instance that doesn't know about the USB device. Running through sh ensures we
// talk to the SAME adb server as the user's terminal.

import Foundation

struct ADBBridge {
    private static var selectedDeviceSerial: String?

    /// Resolved path to the adb binary. Prefers system adb (user-managed, up-to-date),
    /// falls back to bundled copy (for users without Homebrew/Android SDK).
    private static let resolvedADBPath: String? = {
        // 1. System adb on PATH — check common locations directly since GUI apps
        //    don't have Homebrew paths in their PATH.
        let knownPaths = [
            "/opt/homebrew/bin/adb",      // Apple Silicon Homebrew
            "/usr/local/bin/adb",          // Intel Homebrew
        ]
        for path in knownPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                NSLog("[ADB] Using system adb: %@", path)
                return path
            }
        }
        // 2. Try `which adb` via shell (catches custom installs)
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-l", "-c", "which adb"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        if process.terminationStatus == 0,
           let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            NSLog("[ADB] Using system adb (via which): %@", path)
            return path
        }
        // 3. Fallback: bundled adb inside the .app bundle (Resources/adb).
        if let bundled = Bundle.main.resourcePath.map({ $0 + "/adb" }),
           FileManager.default.isExecutableFile(atPath: bundled) {
            NSLog("[ADB] Using bundled adb (no system adb found): %@", bundled)
            return bundled
        }
        NSLog("[ADB] No adb binary found (checked known paths + which + bundle)")
        return nil
    }()

    /// Shell environment loaded once from login shell. This ensures adb commands
    /// see the same env as the user's terminal (ANDROID_HOME, PATH, HOME, etc.).
    private static let shellEnvironment: [String: String] = {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-l", "-c", "env"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        var env: [String: String] = [:]
        for line in output.split(separator: "\n") {
            if let eqIdx = line.firstIndex(of: "=") {
                let key = String(line[line.startIndex..<eqIdx])
                let value = String(line[line.index(after: eqIdx)...])
                env[key] = value
            }
        }
        // Ensure HOME is always set
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        NSLog("[ADB] Shell environment loaded (%d vars, HOME=%@, ANDROID_HOME=%@)",
              env.count, env["HOME"] ?? "nil", env["ANDROID_HOME"] ?? "nil")
        return env
    }()

    /// Create a Process configured to run adb with the given arguments.
    /// Uses the full shell environment to ensure we talk to the same adb server
    /// as the user's terminal.
    private static func makeADBProcess(_ arguments: [String], useSelectedSerial: Bool = true) -> Process? {
        guard let adbPath = resolvedADBPath else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        var finalArgs: [String] = []
        if useSelectedSerial, let serial = selectedDeviceSerial, !serial.isEmpty {
            finalArgs += ["-s", serial]
        }
        finalArgs += arguments
        process.arguments = finalArgs
        process.environment = shellEnvironment
        return process
    }

    static func setSelectedDeviceSerial(_ serial: String?) {
        let trimmed = serial?.trimmingCharacters(in: .whitespacesAndNewlines)
        selectedDeviceSerial = (trimmed?.isEmpty == false) ? trimmed : nil
        NSLog("[ADB] Selected device serial: %@", selectedDeviceSerial ?? "<none>")
    }

    static func isAvailable() -> Bool {
        return resolvedADBPath != nil
    }

    /// Ensure the ADB server daemon is running. Called once before first ADB operation.
    /// Without this, `adb devices` can silently fail on first use.
    @discardableResult
    static func ensureServerRunning() -> Bool {
        let stderr = Pipe()
        guard let process = makeADBProcess(["start-server"], useSelectedSerial: false) else { return false }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            NSLog("[ADB] start-server: failed to launch — %@", "\(error)")
            return false
        }
        process.waitUntilExit()
        if process.terminationStatus == 0 {
            NSLog("[ADB] Server running")
            return true
        }
        let errOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        NSLog("[ADB] WARNING: start-server failed (exit %d) — %@", process.terminationStatus, errOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        return false
    }

    static func connectedDevice(preferredSerial: String? = nil) -> String? {
        let stdout = Pipe()
        let stderr = Pipe()
        guard let process = makeADBProcess(["devices"], useSelectedSerial: false) else {
            NSLog("[ADB] connectedDevice: no adb binary")
            return nil
        }
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            NSLog("[ADB] connectedDevice: failed to launch — %@", "\(error)")
            return nil
        }
        process.waitUntilExit()
        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            NSLog("[ADB] connectedDevice: exit %d — %@", process.terminationStatus, errOutput.trimmingCharacters(in: .whitespacesAndNewlines))
            return nil
        }
        var firstDevice: String?
        for line in output.split(separator: "\n").dropFirst() {
            let parts = line.split(separator: "\t")
            if parts.count >= 2 && parts[1] == "device" {
                let serial = String(parts[0])
                if firstDevice == nil { firstDevice = serial }
                if let preferredSerial, serial == preferredSerial {
                    return serial
                }
            }
            if parts.count >= 2 {
                NSLog("[ADB] connectedDevice: device %@ status '%@' (not ready)", String(parts[0]), String(parts[1]))
            }
        }
        if preferredSerial == nil {
            return firstDevice
        }
        NSLog("[ADB] connectedDevice: no device found in output: %@", output.trimmingCharacters(in: .whitespacesAndNewlines))
        return nil
    }

    static func connectedDeviceSerials() -> [String] {
        let stdout = Pipe()
        let stderr = Pipe()
        guard let process = makeADBProcess(["devices"], useSelectedSerial: false) else { return [] }
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            NSLog("[ADB] connectedDeviceSerials: failed to launch — %@", "\(error)")
            return []
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            NSLog("[ADB] connectedDeviceSerials: exit %d — %@", process.terminationStatus, errOutput.trimmingCharacters(in: .whitespacesAndNewlines))
            return []
        }
        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        var serials: [String] = []
        for line in output.split(separator: "\n").dropFirst() {
            let parts = line.split(separator: "\t")
            if parts.count >= 2 && parts[1] == "device" {
                serials.append(String(parts[0]))
            }
        }
        return serials
    }

    static func isWirelessSerial(_ serial: String) -> Bool {
        // ADB TCP device serials are "ip:port".
        return serial.contains(":")
    }

    @discardableResult
    static func connectWireless(endpoint: String) -> Bool {
        let stdout = Pipe()
        let stderr = Pipe()
        guard let process = makeADBProcess(["connect", endpoint], useSelectedSerial: false) else { return false }
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            NSLog("[ADB] connectWireless: failed to launch — %@", "\(error)")
            return false
        }
        process.waitUntilExit()
        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let merged = (out + "\n" + err).lowercased()
        let ok = process.terminationStatus == 0 &&
            (merged.contains("connected to") || merged.contains("already connected to"))
        if ok {
            NSLog("[ADB] Wireless connect OK: %@", endpoint)
        } else {
            NSLog("[ADB] Wireless connect failed (%d): %@", process.terminationStatus, (out + err).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return ok
    }

    @discardableResult
    static func disconnectWireless(endpoint: String) -> Bool {
        let stdout = Pipe()
        let stderr = Pipe()
        guard let process = makeADBProcess(["disconnect", endpoint], useSelectedSerial: false) else { return false }
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            NSLog("[ADB] disconnectWireless: failed to launch — %@", "\(error)")
            return false
        }
        process.waitUntilExit()
        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let ok = process.terminationStatus == 0
        if ok {
            NSLog("[ADB] Wireless disconnect %@ — %@", endpoint, out.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            NSLog("[ADB] Wireless disconnect failed (%d): %@", process.terminationStatus, (out + err).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return ok
    }

    @discardableResult
    static func enableTCPIP(port: UInt16 = 5555, serial: String) -> Bool {
        let stdout = Pipe()
        let stderr = Pipe()
        guard let process = makeADBProcess(["-s", serial, "tcpip", "\(port)"], useSelectedSerial: false) else { return false }
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            NSLog("[ADB] enableTCPIP: failed to launch — %@", "\(error)")
            return false
        }
        process.waitUntilExit()
        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let ok = process.terminationStatus == 0
        if ok {
            NSLog("[ADB] TCP/IP enabled on %@:%d — %@", serial, port, out.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            NSLog("[ADB] enableTCPIP failed (%d): %@", process.terminationStatus, (out + err).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return ok
    }

    static func discoverWLANIPAddress(serial: String) -> String? {
        // Prefer getprop (cheap + stable on Android).
        let propCandidates = [
            "dhcp.wlan0.ipaddress",
            "dhcp.wlan1.ipaddress",
            "wifi.interface.ip"
        ]
        for key in propCandidates {
            if let val = runShell(serial: serial, command: ["getprop", key])?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               isIPv4(val) {
                return val
            }
        }

        // Fallback: parse `ip` output from wlan0.
        if let ipOutput = runShell(serial: serial, command: ["ip", "-f", "inet", "addr", "show", "wlan0"]) {
            for token in ipOutput.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "/" }) {
                let s = String(token)
                if isIPv4(s) { return s }
            }
        }
        return nil
    }

    private static func runShell(serial: String, command: [String]) -> String? {
        let stdout = Pipe()
        let stderr = Pipe()
        var args = ["-s", serial, "shell"]
        args.append(contentsOf: command)
        guard let process = makeADBProcess(args, useSelectedSerial: false) else { return nil }
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            NSLog("[ADB] runShell failed to launch — %@", "\(error)")
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            NSLog("[ADB] runShell exit %d — %@", process.terminationStatus, errOutput.trimmingCharacters(in: .whitespacesAndNewlines))
            return nil
        }
        return String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }

    private static func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".")
        guard parts.count == 4 else { return false }
        for part in parts {
            guard let value = Int(part), value >= 0 && value <= 255 else { return false }
        }
        return true
    }

    @discardableResult
    static func setupReverseTunnel(port: UInt16) -> Bool {
        let stdout = Pipe()
        let stderr = Pipe()
        guard let process = makeADBProcess(["reverse", "tcp:\(port)", "tcp:\(port)"]) else { return false }
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            NSLog("[ADB] setupReverseTunnel: failed to launch — %@", "\(error)")
            return false
        }
        process.waitUntilExit()
        let stdOutput = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            let errOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            NSLog("[ADB] setupReverseTunnel: exit %d — stdout='%@' stderr='%@'",
                  process.terminationStatus,
                  stdOutput.trimmingCharacters(in: .whitespacesAndNewlines),
                  errOutput.trimmingCharacters(in: .whitespacesAndNewlines))
            return false
        }
        NSLog("[ADB] setupReverseTunnel: success — stdout='%@'", stdOutput.trimmingCharacters(in: .whitespacesAndNewlines))

        let verified = verifyReverseTunnel(port: port)
        if !verified {
            NSLog("[ADB] setupReverseTunnel: WARNING — command succeeded but tunnel not in --list!")
        }
        return verified
    }

    private static func verifyReverseTunnel(port: UInt16) -> Bool {
        let stdout = Pipe()
        guard let process = makeADBProcess(["reverse", "--list"]) else { return false }
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let found = output.contains("tcp:\(port)")
        NSLog("[ADB] verifyReverseTunnel: %@ (output='%@')", found ? "VERIFIED" : "NOT FOUND", output.trimmingCharacters(in: .whitespacesAndNewlines))
        return found
    }

    @discardableResult
    static func removeReverseTunnel(port: UInt16) -> Bool {
        guard let process = makeADBProcess(["reverse", "--remove", "tcp:\(port)"]) else { return false }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    static func querySystemSetting(_ setting: String) -> Int? {
        let pipe = Pipe()
        guard let process = makeADBProcess(["shell", "settings", "get", "system", setting]) else { return nil }
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        if let str = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) {
            return Int(str)
        }
        return nil
    }

    static func setSystemSetting(_ setting: String, value: Int) {
        guard let process = makeADBProcess(["shell", "settings", "put", "system", setting, "\(value)"]) else { return }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    /// Check if the companion Android app is installed on the connected device.
    static func isAppInstalled() -> Bool {
        let pipe = Pipe()
        guard let process = makeADBProcess(["shell", "pm", "list", "packages", "com.daylight.mirror"]) else { return false }
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return output.contains("package:com.daylight.mirror")
    }

    /// Install the bundled APK onto the connected device.
    /// Returns nil on success, or an error message on failure.
    static func installBundledAPK() -> String? {
        guard let resourcePath = Bundle.main.resourcePath else {
            return "No resource path in bundle"
        }
        let apkPath = resourcePath + "/app-debug.apk"
        guard FileManager.default.fileExists(atPath: apkPath) else {
            return "No bundled APK found"
        }
        let pipe = Pipe()
        guard let process = makeADBProcess(["install", "-r", apkPath]) else {
            return "ADB not available"
        }
        process.standardOutput = pipe
        process.standardError = pipe
        try? process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            return "Install failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        NSLog("[ADB] Installed bundled APK successfully")
        return nil
    }

    /// Launch the companion app. When `forceRestart` is true, uses `-S` to stop any
    /// existing instance first, ensuring a fresh TCP connection through the tunnel.
    static func launchApp(forceRestart: Bool = false) {
        var args = ["shell", "am", "start"]
        if forceRestart { args.append("-S") }
        args += ["-n", "com.daylight.mirror/.MirrorActivity"]
        let stderr = Pipe()
        guard let process = makeADBProcess(args) else { return }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            NSLog("[ADB] launchApp: failed to launch — %@", "\(error)")
            return
        }
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let errOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            NSLog("[ADB] launchApp: exit %d — %@", process.terminationStatus, errOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            NSLog("[ADB] Launched Daylight Mirror on device%@", forceRestart ? " (force-restart)" : "")
        }
    }
}
