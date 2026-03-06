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

/// A USB-connected Android device detected by ADB.
public struct ConnectedDevice: Identifiable {
    public var id: String { serial }
    public let serial: String
    public let model: String

    /// Infer device family from the model string reported by ADB.
    public var deviceFamily: DeviceFamily {
        let m = model.lowercased()
        if m.contains("palma") || m.contains("boox") {
            return .booxPalma
        }
        return .daylightDC1
    }
}

struct ADBBridge {
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
    /// as the user's terminal. When serial is provided, prepends `-s <serial>`.
    private static func makeADBProcess(_ arguments: [String], serial: String? = nil) -> Process? {
        guard let adbPath = resolvedADBPath else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        var args: [String] = []
        if let serial = serial {
            args += ["-s", serial]
        }
        args += arguments
        process.arguments = args
        process.environment = shellEnvironment
        return process
    }

    static func isAvailable() -> Bool {
        return resolvedADBPath != nil
    }

    /// Ensure the ADB server daemon is running. Called once before first ADB operation.
    /// Without this, `adb devices` can silently fail on first use.
    @discardableResult
    static func ensureServerRunning() -> Bool {
        let stderr = Pipe()
        guard let process = makeADBProcess(["start-server"]) else { return false }
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

    /// Returns the serial of the first connected device (legacy convenience).
    static func connectedDevice() -> String? {
        return connectedDevices().first?.serial
    }

    /// Detect all connected USB devices. Parses `adb devices -l` for serial + model.
    static func connectedDevices() -> [ConnectedDevice] {
        let stdout = Pipe()
        let stderr = Pipe()
        guard let process = makeADBProcess(["devices", "-l"]) else {
            NSLog("[ADB] connectedDevices: no adb binary")
            return []
        }
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            NSLog("[ADB] connectedDevices: failed to launch — %@", "\(error)")
            return []
        }
        process.waitUntilExit()
        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            let errOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            NSLog("[ADB] connectedDevices: exit %d — %@", process.terminationStatus, errOutput.trimmingCharacters(in: .whitespacesAndNewlines))
            return []
        }

        var devices: [ConnectedDevice] = []
        for line in output.split(separator: "\n").dropFirst() {
            // Format: "SERIAL  device usb:... product:... model:MODEL device:..."
            let parts = line.split(separator: " ", maxSplits: 2)
            guard parts.count >= 2 else { continue }
            let serial = String(parts[0])
            let status = String(parts[1])
            guard status == "device" else {
                NSLog("[ADB] connectedDevices: %@ status '%@' (not ready)", serial, status)
                continue
            }
            // Extract model from key:value pairs
            var model = "unknown"
            if let modelRange = line.range(of: "model:") {
                let afterModel = line[modelRange.upperBound...]
                model = String(afterModel.prefix(while: { $0 != " " }))
            }
            devices.append(ConnectedDevice(serial: serial, model: model))
            NSLog("[ADB] connectedDevices: found %@ (model: %@)", serial, model)
        }
        return devices
    }

    /// Set up ADB reverse tunnel: device's `devicePort` → Mac's `hostPort`.
    /// Both Android apps connect to localhost:8888, but the tunnel routes each to its own Mac port.
    @discardableResult
    static func setupReverseTunnel(serial: String? = nil, devicePort: UInt16 = TCP_PORT, hostPort: UInt16 = TCP_PORT) -> Bool {
        let stdout = Pipe()
        let stderr = Pipe()
        guard let process = makeADBProcess(["reverse", "tcp:\(devicePort)", "tcp:\(hostPort)"], serial: serial) else { return false }
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
        NSLog("[ADB] setupReverseTunnel: %@:%d → host:%d — success", serial ?? "default", devicePort, hostPort)

        let verified = verifyReverseTunnel(serial: serial, devicePort: devicePort)
        if !verified {
            NSLog("[ADB] setupReverseTunnel: WARNING — command succeeded but tunnel not in --list!")
        }
        return verified
    }

    private static func verifyReverseTunnel(serial: String? = nil, devicePort: UInt16 = TCP_PORT) -> Bool {
        let stdout = Pipe()
        guard let process = makeADBProcess(["reverse", "--list"], serial: serial) else { return false }
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let found = output.contains("tcp:\(devicePort)")
        NSLog("[ADB] verifyReverseTunnel: %@ (output='%@')", found ? "VERIFIED" : "NOT FOUND", output.trimmingCharacters(in: .whitespacesAndNewlines))
        return found
    }

    @discardableResult
    static func removeReverseTunnel(serial: String? = nil, devicePort: UInt16 = TCP_PORT) -> Bool {
        guard let process = makeADBProcess(["reverse", "--remove", "tcp:\(devicePort)"], serial: serial) else { return false }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    static func querySystemSetting(_ setting: String, serial: String? = nil) -> Int? {
        let pipe = Pipe()
        guard let process = makeADBProcess(["shell", "settings", "get", "system", setting], serial: serial) else { return nil }
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

    static func setSystemSetting(_ setting: String, value: Int, serial: String? = nil) {
        guard let process = makeADBProcess(["shell", "settings", "put", "system", setting, "\(value)"], serial: serial) else { return }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    /// Check if the companion Android app is installed on the specified device.
    static func isAppInstalled(serial: String? = nil) -> Bool {
        let pipe = Pipe()
        guard let process = makeADBProcess(["shell", "pm", "list", "packages", "com.daylight.mirror"], serial: serial) else { return false }
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return output.contains("package:com.daylight.mirror")
    }

    /// Install the bundled APK onto the specified device.
    /// Returns nil on success, or an error message on failure.
    static func installBundledAPK(serial: String? = nil) -> String? {
        guard let resourcePath = Bundle.main.resourcePath else {
            return "No resource path in bundle"
        }
        let apkPath = resourcePath + "/app-debug.apk"
        guard FileManager.default.fileExists(atPath: apkPath) else {
            return "No bundled APK found"
        }
        let pipe = Pipe()
        guard let process = makeADBProcess(["install", "-r", apkPath], serial: serial) else {
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
        NSLog("[ADB] Installed bundled APK on %@", serial ?? "default")
        return nil
    }

    /// Launch the companion app on the specified device.
    /// When `forceRestart` is true, uses `-S` to stop any existing instance first.
    static func launchApp(serial: String? = nil, forceRestart: Bool = false) {
        var args = ["shell", "am", "start"]
        if forceRestart { args.append("-S") }
        args += ["-n", "com.daylight.mirror/.MirrorActivity"]
        let stderr = Pipe()
        guard let process = makeADBProcess(args, serial: serial) else { return }
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
            NSLog("[ADB] Launched Daylight Mirror on %@%@", serial ?? "default", forceRestart ? " (force-restart)" : "")
        }
    }
}
